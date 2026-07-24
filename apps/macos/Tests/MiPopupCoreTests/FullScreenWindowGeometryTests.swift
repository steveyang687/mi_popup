import Foundation
import Testing
@testable import MiPopupCore

struct FullScreenWindowGeometryTests {
    private let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    @Test
    func acceptsAFullScreenWindowWithSmallWindowServerInsets() {
        #expect(
            FullScreenWindowGeometry.coversDisplay(
                windowBounds: CGRect(x: 4, y: 4, width: 1_432, height: 892),
                displayBounds: display
            )
        )
    }

    @Test
    func rejectsAMaximizedWindowThatLeavesTheMenuBarAndToolbarVisible() {
        #expect(
            !FullScreenWindowGeometry.coversDisplay(
                windowBounds: CGRect(x: 0, y: 70, width: 1_440, height: 830),
                displayBounds: display
            )
        )
    }

    @Test
    func rejectsAWindowThatMissesASignificantSideArea() {
        #expect(
            !FullScreenWindowGeometry.coversDisplay(
                windowBounds: CGRect(x: 28, y: 0, width: 1_412, height: 900),
                displayBounds: display
            )
        )
    }
}
