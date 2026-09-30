import Foundation
import Testing
@testable import MiPopupCore

struct NotificationLogImporterTests {
    @Test
    func reservesPhysicalNotchAndVisibleSideAreas() {
        let reserved = NotchGeometry.reservedWidth(
            leftAreaMaxX: 650,
            rightAreaMinX: 850
        )

        #expect(reserved == 216)
        #expect(NotchGeometry.panelWidth(baseWidth: 430, reservedWidth: reserved) == 516)
        #expect(
            NotchGeometry.panelWidth(
                baseWidth: 292,
                reservedWidth: reserved,
                visibleWidthPerSide: 46
            ) == 308
        )
        #expect(NotchGeometry.reservedWidth(leftAreaMaxX: nil, rightAreaMinX: nil) == 0)
        #expect(NotchGeometry.panelWidth(baseWidth: 430, reservedWidth: 0) == 430)
        #expect(NotchGeometry.collapsedHeight(safeAreaTop: 32, hasPhysicalNotch: true) == 32)
        #expect(NotchGeometry.collapsedHeight(safeAreaTop: 0, hasPhysicalNotch: false) == 38)
    }

    @Test
    func anchorsAnimatedIslandToTopAndCentersItHorizontally() {
        let frame = NotchGeometry.topAnchoredContentFrame(
            containerSize: CGSize(width: 470, height: 334),
            contentSize: CGSize(width: 292, height: 38),
            backingScale: 2
        )

        #expect(frame.origin.x == 89)
        #expect(frame.origin.y == 296)
        #expect(frame.size.width == 292)
        #expect(frame.size.height == 38)
        #expect(frame.origin.y + frame.size.height == 334)
        #expect(frame.origin.x + frame.size.width / 2 == 235)

        for intermediateSize in [
            CGSize(width: 338.25, height: 104.75),
            CGSize(width: 401.5, height: 231.25),
            CGSize(width: 470, height: 334),
        ] {
            let intermediateFrame = NotchGeometry.topAnchoredContentFrame(
                containerSize: CGSize(width: 470, height: 334),
                contentSize: intermediateSize,
                backingScale: 2
            )
            let topEdge = intermediateFrame.origin.y + intermediateFrame.size.height
            let centerX = intermediateFrame.origin.x + intermediateFrame.size.width / 2

            #expect(topEdge == 334)
            #expect(abs(centerX - 235) <= 0.25)
        }
    }

    @Test
    func leftDockedAnimationKeepsTopAndLeftEdgesFixed() {
        for size in [CGSize(width: 72, height: 32), CGSize(width: 260, height: 150), CGSize(width: 470, height: 334)] {
            let frame = NotchGeometry.topAnchoredContentFrame(
                containerSize: CGSize(width: 470, height: 334),
                contentSize: size,
                backingScale: 2,
                alignLeft: true
            )
            #expect(frame.minX == 0)
            #expect(frame.maxY == 334)
            #expect(frame.size == size)
        }
    }

    @Test
    func positionsIslandAgainstNotchLeftEdgeAndClampsCustomPlacement() {
        let leftArea = CGRect(x: 12, y: 0, width: 630, height: 900)
        for width: CGFloat in [100, 260, 470] {
            let origin = NotchGeometry.horizontalOrigin(
                width: width, desiredCenter: leftArea.maxX - width / 2, area: leftArea
            )
            #expect(origin + width == 642)
        }
        #expect(NotchGeometry.horizontalOrigin(width: 100, desiredCenter: 400, area: leftArea) == 350)
        #expect(NotchGeometry.horizontalOrigin(width: 470, desiredCenter: 0, area: leftArea) == 12)
        #expect(NotchGeometry.horizontalOrigin(width: 470, desiredCenter: 900, area: leftArea) == 172)
        let rightScreen = CGRect(x: -1500, y: 0, width: 1400, height: 900)
        #expect(NotchGeometry.horizontalOrigin(width: 100, desiredCenter: -800, area: rightScreen) == -850)
    }

    @Test
    func leftDockOverlapsPhysicalNotchWithoutLeavingASeam() {
        let screen = CGRect(x: -1500, y: 0, width: 1500, height: 900)
        let area = NotchGeometry.leftDockingArea(screenFrame: screen, notchLeftEdge: -850)
        #expect(area.maxX == -834)
        for width: CGFloat in [100, 260, 470] {
            let x = NotchGeometry.horizontalOrigin(width: width, desiredCenter: area.maxX - width / 2, area: area)
            #expect(x + width == -850 + NotchGeometry.notchJoinOverlap)
        }
        let withoutNotch = NotchGeometry.leftDockingArea(screenFrame: screen, notchLeftEdge: nil)
        #expect(withoutNotch.maxX == screen.midX)
    }

    @Test
    func importsValidLinesAndSkipsMalformedLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("sample.jsonl")
        let valid = #"{"schemaVersion":1,"eventId":"e1","eventKind":"posted","capturedAt":2,"postedAt":1,"sourcePackage":"com.taobao.taobao","appName":"淘宝","notificationKeyHash":"hash","title":"骑手正在配送","text":"预计 18:35 送达"}"#
        try (valid + "\nnot-json\n").write(to: file, atomically: true, encoding: .utf8)

        let summary = try NotificationLogImporter().importFile(at: file)
        #expect(summary.events.count == 1)
        #expect(summary.skippedLineCount == 1)
        #expect(summary.latestEvent?.title == "骑手正在配送")
    }

    @Test
    func rejectsFilesWithoutValidEvents() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-\(UUID().uuidString).jsonl")
        try "bad\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: NotificationLogImportError.noValidEvents(skippedLines: 1)) {
            try NotificationLogImporter().importFile(at: file)
        }
    }
}
