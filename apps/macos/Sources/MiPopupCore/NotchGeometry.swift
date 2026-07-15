import Foundation

public enum NotchGeometry {
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

    public static func topAnchoredContentFrame(
        containerSize: CGSize,
        contentSize: CGSize,
        backingScale: CGFloat
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
        let xPixels = ((containerWidthPixels - contentWidthPixels) / 2).rounded()
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
