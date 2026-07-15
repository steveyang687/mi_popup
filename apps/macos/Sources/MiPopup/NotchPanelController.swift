import AppKit
import MiPopupCore
import QuartzCore
import SwiftUI

@MainActor
final class NotchPanelController: NSWindowController {
    var onImportRequest: (() -> Void)?

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
    nonisolated(unsafe) private var frameDisplayLink: CADisplayLink?
    private var frameAnimation: PanelFrameAnimation?
    private var isPointerInside = false
    private var isManuallyCollapsedWhileHovered = false

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.init(window: panel)
        configure(panel)
        installContent(in: panel)
        startQuotaRefreshLoop()
    }

    deinit {
        quotaRefreshLoop?.cancel()
        modelIntelligenceRefreshLoop?.cancel()
        immediateRefreshTask?.cancel()
        hoverCollapseTask?.cancel()
        manualCollapseReleaseTask?.cancel()
        frameDisplayLink?.invalidate()
    }

    func show() {
        reposition()
        window?.orderFrontRegardless()
    }

    func reposition() {
        guard let window, let screen = preferredScreen() else { return }
        let size = panelSize(for: screen)
        stopFrameAnimation()
        window.setFrame(panelFrame(size: size, screen: screen), display: true)
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
            onDropFile: { [weak self] url in self?.importLog(at: url) }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.layerContentsRedrawPolicy = .duringViewResize
        hostingView.layer?.needsDisplayOnBoundsChange = true
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
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
            window.setFrame(frame, display: true)
        }
    }

    private func startFrameAnimation(window: NSWindow, targetFrame: NSRect, screen: NSScreen) {
        stopFrameAnimation()
        guard window.frame != targetFrame else { return }

        frameAnimation = PanelFrameAnimation(
            startFrame: window.frame,
            targetFrame: targetFrame,
            startedAt: CACurrentMediaTime(),
            duration: 0.32,
            scale: screen.backingScaleFactor,
            screenTop: screen.frame.maxY,
            screenMidX: screen.frame.midX
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
        let width = interpolate(animation.startFrame.width, animation.targetFrame.width, eased)
        let height = interpolate(animation.startFrame.height, animation.targetFrame.height, eased)
        let frame = pixelAlignedFrame(
            width: width,
            height: height,
            screenMidX: animation.screenMidX,
            screenTop: animation.screenTop,
            scale: animation.scale
        )

        window.setFrame(frame, display: true)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.needsDisplay = true
        window.contentView?.displayIfNeeded()

        if progress >= 1 {
            window.setFrame(animation.targetFrame, display: true)
            stopFrameAnimation()
        }
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

        let baseSize = model.expanded ? expandedSize : Self.collapsedSize
        return NSSize(
            width: NotchGeometry.panelWidth(
                baseWidth: baseSize.width,
                reservedWidth: reservedWidth,
                visibleWidthPerSide: model.expanded ? 150 : 46
            ),
            height: baseSize.height
        )
    }

    private var expandedSize: NSSize {
        let height: CGFloat
        switch model.selectedTab {
        case .quota:
            height = model.eventCount > 0 ? 320 : 302
        case .models:
            height = 334
        }
        return NSSize(width: 470, height: height)
    }

    private static let collapsedSize = NSSize(width: 292, height: 38)
}

private struct PanelFrameAnimation {
    let startFrame: NSRect
    let targetFrame: NSRect
    let startedAt: CFTimeInterval
    let duration: CFTimeInterval
    let scale: CGFloat
    let screenTop: CGFloat
    let screenMidX: CGFloat
}

private struct QuotaFetchOutcome: Sendable {
    let provider: SubscriptionProviderID
    let snapshot: SubscriptionQuotaSnapshot?
    let errorMessage: String?
}
