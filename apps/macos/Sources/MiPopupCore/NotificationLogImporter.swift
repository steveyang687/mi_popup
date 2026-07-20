import Foundation

public struct CapturedNotification: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let eventId: String
    public let eventKind: String
    public let capturedAt: Int64
    public let postedAt: Int64
    public let sourcePackage: String
    public let appName: String
    public let notificationKeyHash: String
    public let notificationId: Int?
    public let title: String?
    public let text: String?
    public let bigText: String?
    public let subText: String?
    public let textLines: [String]?
    public let category: String?
    public let channelId: String?
    public let groupSummary: Bool?
    public let ongoing: Bool?
    public let clearable: Bool?
    public let delivery: DeliveryUpdate?

    public init(
        schemaVersion: Int,
        eventId: String,
        eventKind: String,
        capturedAt: Int64,
        postedAt: Int64,
        sourcePackage: String,
        appName: String,
        notificationKeyHash: String,
        notificationId: Int? = nil,
        title: String? = nil,
        text: String? = nil,
        bigText: String? = nil,
        subText: String? = nil,
        textLines: [String]? = nil,
        category: String? = nil,
        channelId: String? = nil,
        groupSummary: Bool? = nil,
        ongoing: Bool? = nil,
        clearable: Bool? = nil,
        delivery: DeliveryUpdate? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.eventKind = eventKind
        self.capturedAt = capturedAt
        self.postedAt = postedAt
        self.sourcePackage = sourcePackage
        self.appName = appName
        self.notificationKeyHash = notificationKeyHash
        self.notificationId = notificationId
        self.title = title
        self.text = text
        self.bigText = bigText
        self.subText = subText
        self.textLines = textLines
        self.category = category
        self.channelId = channelId
        self.groupSummary = groupSummary
        self.ongoing = ongoing
        self.clearable = clearable
        self.delivery = delivery
    }
}

public struct NotificationImportSummary: Sendable, Equatable {
    public let fileName: String
    public let events: [CapturedNotification]
    public let skippedLineCount: Int

    public var sourceNames: [String] {
        Array(Set(events.map { $0.appName.isEmpty ? $0.sourcePackage : $0.appName })).sorted()
    }

    public var latestEvent: CapturedNotification? {
        events.max { $0.capturedAt < $1.capturedAt }
    }

    public var deliveryUpdates: [DeliveryUpdate] {
        events.compactMap { event in
            event.delivery ?? DeliveryNotificationParser.parse(event)
        }
    }

    public var latestDeliveryUpdate: DeliveryUpdate? {
        deliveryUpdates.max { $0.capturedAt < $1.capturedAt }
    }

    public init(fileName: String, events: [CapturedNotification], skippedLineCount: Int) {
        self.fileName = fileName
        self.events = events
        self.skippedLineCount = skippedLineCount
    }
}

public enum NotificationLogImportError: LocalizedError, Equatable {
    case unreadableFile
    case noValidEvents(skippedLines: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "无法读取日志文件。"
        case .noValidEvents(let skippedLines):
            "没有找到可识别的通知事件（跳过 \(skippedLines) 行）。"
        }
    }
}

public struct NotificationLogImporter: Sendable {
    public init() {}

    public func importFile(at url: URL) throws -> NotificationImportSummary {
        guard let reader = try? String(contentsOf: url, encoding: .utf8) else {
            throw NotificationLogImportError.unreadableFile
        }

        let decoder = JSONDecoder()
        var events: [CapturedNotification] = []
        var skipped = 0

        reader.enumerateLines { line, _ in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(CapturedNotification.self, from: data),
                  event.schemaVersion == 1 else {
                skipped += 1
                return
            }
            events.append(event)
        }

        guard !events.isEmpty else {
            throw NotificationLogImportError.noValidEvents(skippedLines: skipped)
        }

        return NotificationImportSummary(
            fileName: url.lastPathComponent,
            events: events.sorted { $0.capturedAt < $1.capturedAt },
            skippedLineCount: skipped
        )
    }
}
