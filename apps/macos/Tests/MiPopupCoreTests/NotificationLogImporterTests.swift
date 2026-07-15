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
