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
}
