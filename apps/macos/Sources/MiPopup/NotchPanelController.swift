import AppKit
import MiPopupCore
import QuartzCore
import SwiftUI

@MainActor
final class NotchPanelController: NSWindowController {
    var onImportRequest: (() -> Void)?
    var onDismissDelivery: ((String) -> Void)?

    private let model = IslandViewModel()
    private let quotaProviders: [any SubscriptionQuotaProviding] = [
        CodexSubscriptionQuotaProvider(),
        AntigravitySubscriptionQuotaProvider(),
    ]
    private let modelIntelligenceProvider: any ModelIntelligenceProviding = CodexRadarProvider()
    private var quotaRefreshLoop: Task<Void, Never>?
    private var modelIntelligenceRefreshLoop: Task<Void, Never>?
    private var immediateRefreshTask: Task<Void, Never>?
    private var hoverCollapseTask: Task<Void, Never>?
    private var manualCollapseReleaseTask: Task<Void, Never>?
    private var fullscreenVisibilityTask: Task<Void, Never>?
    nonisolated(unsafe) private var frameDisplayLink: CADisplayLink?
    private var frameAnimation: PanelFrameAnimation?
    private var islandContainerView: IslandHostingContainerView?
    private var islandHostingView: NSView?
    private var isPointerInside = false
    private var isManuallyCollapsedWhileHovered = false
    private var isHiddenForFullscreen = false

    convenience init() {
        let panel = TopAnchoredPanel(
            contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.init(window: panel)
        configure(panel)
        installContent(in: panel)
        observeWorkspaceChanges()
        restoreCachedQuotaSnapshots()
        startQuotaRefreshLoop()
    }

    deinit {
        quotaRefreshLoop?.cancel()
        modelIntelligenceRefreshLoop?.cancel()
        immediateRefreshTask?.cancel()
        hoverCollapseTask?.cancel()
        manualCollapseReleaseTask?.cancel()
        fullscreenVisibilityTask?.cancel()
        frameDisplayLink?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func show() {
        guard let screen = preferredScreen(), !frontmostApplicationIsFullscreen(on: screen) else {
            isHiddenForFullscreen = true
            window?.orderOut(nil)
            return
        }
        isHiddenForFullscreen = false
        reposition()
        window?.orderFrontRegardless()
    }

    func reposition() {
        guard let window, let screen = preferredScreen() else { return }
        let size = panelSize(for: screen)
        stopFrameAnimation()
        applyPanelFrame(
            panelFrame(size: size, screen: screen),
            to: window,
            screenTop: screen.frame.maxY
        )
        setIslandContentSize(size, backingScale: screen.backingScaleFactor)
    }

    func importLog(at url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let summary = try NotificationLogImporter().importFile(at: url)
            model.apply(summary: summary)
        } catch {
            model.apply(error: error)
        }
        resize(animated: true)
        show()
    }

    func receive(delivery update: DeliveryUpdate, restoreOnly: Bool = false) {
        guard model.apply(
            delivery: update,
            source: restoreOnly ? "Android · 上次局域网同步" : "Android · 局域网实时同步"
        ) else { return }

        guard !restoreOnly else { return }
        resize(animated: true)
        show()
    }

    private func observeWorkspaceChanges() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(frontmostApplicationDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        scheduleFullscreenVisibilityCheck()
    }

    @objc private func frontmostApplicationDidChange(_ notification: Notification) {
        scheduleFullscreenVisibilityCheck()
    }

    private func scheduleFullscreenVisibilityCheck() {
        fullscreenVisibilityTask?.cancel()
        fullscreenVisibilityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.updateFullscreenVisibility()
        }
    }

    private func updateFullscreenVisibility() {
        guard let screen = preferredScreen() else { return }
        if frontmostApplicationIsFullscreen(on: screen) {
            isHiddenForFullscreen = true
            window?.orderOut(nil)
            return
        }
        guard isHiddenForFullscreen else { return }
        isHiddenForFullscreen = false
        reposition()
        window?.orderFrontRegardless()
    }

    private func frontmostApplicationIsFullscreen(on screen: NSScreen) -> Bool {
        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        let tolerance: CGFloat = 2
        return windowList.contains { windowInfo in
            guard (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return false
            }
            return abs(bounds.minX - displayBounds.minX) <= tolerance
                && abs(bounds.minY - displayBounds.minY) <= tolerance
                && abs(bounds.width - displayBounds.width) <= tolerance
                && abs(bounds.height - displayBounds.height) <= tolerance
        }
    }

    func refreshQuotas() {
        guard !model.isRefreshingSelectedTab else { return }
        immediateRefreshTask = Task { [weak self] in
            guard let self else { return }
            if self.model.selectedTab == .quota {
                await self.loadQuotas()
            } else {
                await self.loadModelIntelligence()
            }
        }
    }

    private func configure(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        // Omitting fullScreenAuxiliary keeps the island out of native full-screen Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
    }

    private func installContent(in panel: NSPanel) {
        let root = IslandView(
            model: model,
            onToggle: { [weak self] in self?.toggleExpanded() },
            onHoverChange: { [weak self] isInside in self?.handleHover(isInside) },
            onTabChange: { [weak self] _ in self?.resize(animated: true) },
            onRefresh: { [weak self] in self?.refreshQuotas() },
            onImport: { [weak self] in self?.onImportRequest?() },
            onDismissDelivery: { [weak self] in self?.dismissCurrentDelivery() },
            onQuit: { NSApp.terminate(nil) },
            onDropFile: { [weak self] url in self?.importLog(at: url) }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.layerContentsRedrawPolicy = .duringViewResize
        hostingView.layer?.needsDisplayOnBoundsChange = true
        let container = IslandHostingContainerView(frame: panel.contentView?.bounds ?? .zero)
        hostingView.autoresizingMask = []
        container.attach(hostingView)
        panel.contentView = container
        islandContainerView = container
        islandHostingView = hostingView
        container.setIslandFrame(container.bounds, cornerRadius: 19)
    }

    private func toggleExpanded() {
        hoverCollapseTask?.cancel()
        hoverCollapseTask = nil
        manualCollapseReleaseTask?.cancel()
        manualCollapseReleaseTask = nil
        isManuallyCollapsedWhileHovered = model.expanded ? isPointerInside : false
        model.expanded.toggle()
        resize(animated: true)
    }

    private func dismissCurrentDelivery() {
        guard let eventId = model.dismissLatestDelivery() else { return }
        onDismissDelivery?(eventId)
        resize(animated: true)
    }

    private func handleHover(_ isInside: Bool) {
        isPointerInside = isInside
        hoverCollapseTask?.cancel()
        hoverCollapseTask = nil

        if isInside {
            guard !isManuallyCollapsedWhileHovered, !model.expanded else { return }
            model.expanded = true
            resize(animated: true)
            return
        }

        if isManuallyCollapsedWhileHovered {
            scheduleManualCollapseRelease()
            return
        }

        guard model.expanded else { return }
        scheduleAutomaticCollapse()
    }

    private func scheduleAutomaticCollapse() {
        hoverCollapseTask?.cancel()
        hoverCollapseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self, !self.isPointerInside, self.model.expanded else { return }
            self.model.expanded = false
            self.resize(animated: true)
            self.hoverCollapseTask = nil
        }
    }

    private func scheduleManualCollapseRelease() {
        manualCollapseReleaseTask?.cancel()
        manualCollapseReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard let self, !self.model.expanded else { return }
            let pointerIsOutside = self.window?.frame.contains(NSEvent.mouseLocation) != true
            if pointerIsOutside {
                self.isManuallyCollapsedWhileHovered = false
            }
            self.manualCollapseReleaseTask = nil
        }
    }

    private func startQuotaRefreshLoop() {
        quotaRefreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.loadQuotas()
                do {
                    try await Task.sleep(for: .seconds(180))
                } catch {
                    return
                }
            }
        }
        modelIntelligenceRefreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.loadModelIntelligence()
                do {
                    try await Task.sleep(for: .seconds(1_800))
                } catch {
                    return
                }
            }
        }
    }

    private func loadQuotas() async {
        guard !model.isRefreshingQuotas else { return }
        model.beginQuotaRefresh()

        await withTaskGroup(of: QuotaFetchOutcome.self) { group in
            for provider in quotaProviders {
                group.addTask {
                    do {
                        return QuotaFetchOutcome(
                            provider: provider.providerID,
                            snapshot: try await provider.fetch(),
                            errorMessage: nil
                        )
                    } catch {
                        return QuotaFetchOutcome(
                            provider: provider.providerID,
                            snapshot: nil,
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }

            for await outcome in group {
                if let snapshot = outcome.snapshot {
                    QuotaSnapshotCache.save(snapshot)
                    model.apply(snapshot: snapshot)
                    #if DEBUG
                    print("AI quota updated: \(snapshot.provider.displayName), \(snapshot.windows.count) windows")
                    #endif
                } else {
                    model.applyQuotaError(
                        provider: outcome.provider,
                        message: outcome.errorMessage ?? "额度读取失败。"
                    )
                    #if DEBUG
                    print("AI quota failed: \(outcome.provider.displayName): \(outcome.errorMessage ?? "unknown error")")
                    #endif
                }
            }
        }
        model.finishQuotaRefresh()
    }

    private func restoreCachedQuotaSnapshots() {
        for provider in SubscriptionProviderID.allCases {
            guard let snapshot = QuotaSnapshotCache.load(provider: provider) else { continue }
            model.apply(snapshot: snapshot)
        }
    }

    private func loadModelIntelligence() async {
        guard !model.isRefreshingModelIntelligence else { return }
        model.beginModelIntelligenceRefresh()
        do {
            let snapshot = try await modelIntelligenceProvider.fetch()
            model.apply(modelIntelligence: snapshot)
            #if DEBUG
            print("Codex Radar updated: \(snapshot.models.count) model configurations")
            #endif
        } catch {
            model.applyModelIntelligenceError(error.localizedDescription)
            #if DEBUG
            print("Codex Radar failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func resize(animated: Bool) {
        guard let window, let screen = preferredScreen() else { return }
        let size = panelSize(for: screen)
        let frame = panelFrame(size: size, screen: screen)
        if animated {
            startFrameAnimation(window: window, targetFrame: frame, screen: screen)
        } else {
            stopFrameAnimation()
            applyPanelFrame(frame, to: window, screenTop: screen.frame.maxY)
            setIslandContentSize(size, backingScale: screen.backingScaleFactor)
        }
    }

    private func startFrameAnimation(window: NSWindow, targetFrame: NSRect, screen: NSScreen) {
        stopFrameAnimation()
        let startSize = islandContainerView?.islandFrame.size ?? window.frame.size
        let targetSize = targetFrame.size
        guard startSize != targetSize else {
            applyPanelFrame(targetFrame, to: window, screenTop: screen.frame.maxY)
            setIslandContentSize(targetSize, backingScale: screen.backingScaleFactor)
            return
        }

        let canvasSize = NSSize(
            width: max(startSize.width, targetSize.width),
            height: max(startSize.height, targetSize.height)
        )
        let canvasFrame = panelFrame(size: canvasSize, screen: screen)

        // Keep the window fixed at the largest animation bounds. Only the island
        // content changes size, so its top edge cannot be displaced by live window resizing.
        applyPanelFrame(canvasFrame, to: window, screenTop: screen.frame.maxY)
        setIslandContentSize(startSize, backingScale: screen.backingScaleFactor)
        window.contentView?.displayIfNeeded()

        frameAnimation = PanelFrameAnimation(
            startSize: startSize,
            targetSize: targetSize,
            targetFrame: targetFrame,
            startedAt: CACurrentMediaTime(),
            duration: 0.32,
            scale: screen.backingScaleFactor,
            screenTop: screen.frame.maxY
        )
        let displayLink = window.displayLink(
            target: self,
            selector: #selector(stepFrameAnimation(_:))
        )
        frameDisplayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func stepFrameAnimation(_ displayLink: CADisplayLink) {
        guard let window, let animation = frameAnimation else {
            stopFrameAnimation()
            return
        }

        let rawProgress = (displayLink.timestamp - animation.startedAt) / animation.duration
        let progress = min(1, max(0, rawProgress))
        let eased = 0.5 - cos(.pi * progress) / 2
        let size = NSSize(
            width: interpolate(animation.startSize.width, animation.targetSize.width, eased),
            height: interpolate(animation.startSize.height, animation.targetSize.height, eased)
        )

        setIslandContentSize(size, backingScale: animation.scale)

        if progress >= 1 {
            applyPanelFrame(
                animation.targetFrame,
                to: window,
                screenTop: animation.screenTop
            )
            setIslandContentSize(animation.targetSize, backingScale: animation.scale)
            window.contentView?.displayIfNeeded()
            stopFrameAnimation()
        }
    }

    private func applyPanelFrame(_ frame: NSRect, to window: NSWindow, screenTop: CGFloat) {
        let pinnedFrame = NSRect(
            x: frame.minX,
            y: screenTop - frame.height,
            width: frame.width,
            height: frame.height
        )
        window.setFrame(pinnedFrame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func setIslandContentSize(_ size: NSSize, backingScale: CGFloat) {
        guard let container = islandContainerView else { return }
        container.layoutSubtreeIfNeeded()
        let frame = NotchGeometry.topAnchoredContentFrame(
            containerSize: container.bounds.size,
            contentSize: size,
            backingScale: backingScale
        )
        container.setIslandFrame(
            frame,
            cornerRadius: model.expanded ? 24 : 19
        )
        islandHostingView?.needsLayout = true
        islandHostingView?.layoutSubtreeIfNeeded()
        islandHostingView?.needsDisplay = true
        islandHostingView?.displayIfNeeded()
    }

    private func stopFrameAnimation() {
        frameDisplayLink?.invalidate()
        frameDisplayLink = nil
        frameAnimation = nil
    }

    private func panelFrame(size: NSSize, screen: NSScreen) -> NSRect {
        pixelAlignedFrame(
            width: size.width,
            height: size.height,
            screenMidX: screen.frame.midX,
            screenTop: screen.frame.maxY,
            scale: screen.backingScaleFactor
        )
    }

    private func pixelAlignedFrame(
        width: CGFloat,
        height: CGFloat,
        screenMidX: CGFloat,
        screenTop: CGFloat,
        scale: CGFloat
    ) -> NSRect {
        let widthPixels = (width * scale).rounded()
        let heightPixels = (height * scale).rounded()
        let centerPixels = (screenMidX * scale).rounded()
        let topPixels = (screenTop * scale).rounded()
        let xPixels = (centerPixels - widthPixels / 2).rounded()
        return NSRect(
            x: xPixels / scale,
            y: (topPixels - heightPixels) / scale,
            width: widthPixels / scale,
            height: heightPixels / scale
        )
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func panelSize(for screen: NSScreen) -> NSSize {
        let reservedWidth = NotchGeometry.reservedWidth(
            leftAreaMaxX: screen.auxiliaryTopLeftArea?.maxX,
            rightAreaMinX: screen.auxiliaryTopRightArea?.minX
        )
        model.notchReservedWidth = reservedWidth

        let collapsedHeight = NotchGeometry.collapsedHeight(
            safeAreaTop: screen.safeAreaInsets.top,
            hasPhysicalNotch: reservedWidth > 0,
            fallbackHeight: Self.collapsedSize.height
        )
        if model.collapsedHeight != collapsedHeight {
            model.collapsedHeight = collapsedHeight
        }

        let collapsedWidth = model.latestDelivery == nil ? Self.collapsedSize.width : 360
        let collapsedSize = NSSize(width: collapsedWidth, height: collapsedHeight)
        let baseSize = model.expanded ? expandedSize : collapsedSize
        let visibleWidthPerSide: CGFloat = model.expanded
            ? 150
            : (model.latestDelivery == nil ? 46 : 126)
        return NSSize(
            width: NotchGeometry.panelWidth(
                baseWidth: baseSize.width,
                reservedWidth: reservedWidth,
                visibleWidthPerSide: visibleWidthPerSide
            ),
            height: baseSize.height
        )
    }

    private var expandedSize: NSSize {
        let height: CGFloat
        switch model.selectedTab {
        case .quota:
            height = 302
                + (model.latestDelivery == nil ? 0 : (model.latestDelivery?.progressPercent == nil ? 58 : 72))
                + (model.eventCount == 0 ? 0 : 18)
        case .models:
            height = 334
        }
        return NSSize(width: 470, height: height)
    }

    private static let collapsedSize = NSSize(width: 292, height: 38)
}

private struct PanelFrameAnimation {
    let startSize: NSSize
    let targetSize: NSSize
    let targetFrame: NSRect
    let startedAt: CFTimeInterval
    let duration: CFTimeInterval
    let scale: CGFloat
    let screenTop: CGFloat
}

private final class IslandHostingContainerView: NSView {
    private let backdrop = NSView()
    private weak var hostedView: NSView?
    private(set) var islandFrame = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        backdrop.layer?.masksToBounds = true
        addSubview(backdrop)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func attach(_ view: NSView) {
        hostedView = view
        addSubview(view, positioned: .above, relativeTo: backdrop)
    }

    func setIslandFrame(_ frame: NSRect, cornerRadius: CGFloat) {
        islandFrame = frame
        backdrop.frame = frame
        backdrop.layer?.cornerRadius = cornerRadius
        hostedView?.frame = frame
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard islandFrame.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

private final class TopAnchoredPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private struct QuotaFetchOutcome: Sendable {
    let provider: SubscriptionProviderID
    let snapshot: SubscriptionQuotaSnapshot?
    let errorMessage: String?
}

private enum QuotaSnapshotCache {
    private static let keyPrefix = "MiPopup.quotaSnapshot.v1."
    private static let maxAge: TimeInterval = 6 * 60 * 60

    static func load(provider: SubscriptionProviderID) -> SubscriptionQuotaSnapshot? {
        let key = keyPrefix + provider.rawValue
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(SubscriptionQuotaSnapshot.self, from: data),
              snapshot.provider == provider,
              Date().timeIntervalSince(snapshot.fetchedAt) <= maxAge
        else { return nil }
        return snapshot
    }

    static func save(_ snapshot: SubscriptionQuotaSnapshot) {
        // Cache only display-safe quota summaries. Login cookies, OAuth tokens, CSRF tokens,
        // account identifiers, and raw provider responses must never be stored in UserDefaults.
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: keyPrefix + snapshot.provider.rawValue)
    }
}
