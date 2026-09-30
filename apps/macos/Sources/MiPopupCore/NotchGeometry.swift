import Foundation

public enum NotchGeometry {
    // Visual approximation: the screen safe-area API does not supply a hardware corner radius.
    public static let collapsedCornerRadius: CGFloat = 8
    public static let notchJoinOverlap: CGFloat = 16

    public static func leftDockingArea(screenFrame: CGRect, notchLeftEdge: CGFloat?) -> CGRect {
        let left = screenFrame.minX + 12
        // Extend underneath the physical notch to cover its curved lower-left cutout.
        let right = notchLeftEdge.map { $0 + notchJoinOverlap } ?? screenFrame.midX
        return CGRect(x: left, y: screenFrame.minY, width: max(1, right - left), height: screenFrame.height)
    }

    public static func horizontalOrigin(width: CGFloat, desiredCenter: CGFloat, area: CGRect) -> CGFloat {
        min(max(desiredCenter - width / 2, area.minX), max(area.minX, area.maxX - width))
    }

    public static func reservedWidth(
        leftAreaMaxX: CGFloat?,
        rightAreaMinX: CGFloat?,
        safetyPadding: CGFloat = 16
    ) -> CGFloat {
        guard let leftAreaMaxX,
              let rightAreaMinX,
              rightAreaMinX > leftAreaMaxX else {
            return 0
        }
        return rightAreaMinX - leftAreaMaxX + safetyPadding
    }

    public static func panelWidth(
        baseWidth: CGFloat,
        reservedWidth: CGFloat,
        visibleWidthPerSide: CGFloat = 150
    ) -> CGFloat {
        guard reservedWidth > 0 else { return baseWidth }
        return max(baseWidth, reservedWidth + visibleWidthPerSide * 2)
    }

    public static func collapsedHeight(
        safeAreaTop: CGFloat,
        hasPhysicalNotch: Bool,
        fallbackHeight: CGFloat = 38
    ) -> CGFloat {
        guard hasPhysicalNotch, safeAreaTop > 0 else { return fallbackHeight }
        return safeAreaTop
    }

    public static func topAnchoredContentFrame(
        containerSize: CGSize,
        contentSize: CGSize,
        backingScale: CGFloat,
        alignLeft: Bool = false
    ) -> CGRect {
        let scale = max(backingScale, 1)
        let containerWidthPixels = max(0, (containerSize.width * scale).rounded())
        let containerHeightPixels = max(0, (containerSize.height * scale).rounded())
        let contentWidthPixels = min(
            containerWidthPixels,
            max(0, (contentSize.width * scale).rounded())
        )
        let contentHeightPixels = min(
            containerHeightPixels,
            max(0, (contentSize.height * scale).rounded())
        )
        let xPixels = alignLeft ? 0 : ((containerWidthPixels - contentWidthPixels) / 2).rounded()
        let yPixels = containerHeightPixels - contentHeightPixels
        let x = xPixels / scale
        let y = yPixels / scale
        let width = contentWidthPixels / scale
        let height = contentHeightPixels / scale

        return CGRect(
            origin: CGPoint(x: x, y: y),
            size: CGSize(width: width, height: height)
        )
    }
}
