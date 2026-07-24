import CoreGraphics

public enum FullScreenWindowGeometry {
    /// WindowServer may report a few points of inset or overscan for a full-screen window.
    /// Require near-total coverage so normal maximized windows remain visible to MiPopup.
    public static func coversDisplay(
        windowBounds: CGRect,
        displayBounds: CGRect,
        minimumCoverage: CGFloat = 0.985
    ) -> Bool {
        guard displayBounds.width > 0,
              displayBounds.height > 0,
              minimumCoverage > 0,
              minimumCoverage <= 1
        else {
            return false
        }

        let overlap = windowBounds.intersection(displayBounds)
        guard overlap.width > 0, overlap.height > 0 else { return false }

        return overlap.width / displayBounds.width >= minimumCoverage
            && overlap.height / displayBounds.height >= minimumCoverage
    }
}
