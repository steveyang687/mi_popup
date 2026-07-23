import Foundation

public enum DeliveryProvider: String, Codable, Sendable, Equatable {
    case meituan
    case taobaoInstant = "taobao_instant"

    public var displayName: String {
        switch self {
        case .meituan: "美团"
        case .taobaoInstant: "淘宝闪购"
        }
    }
}

public enum DeliveryStage: String, Codable, Sendable, Equatable {
    case orderPlaced = "order_placed"
    case merchantConfirmed = "merchant_confirmed"
    case preparing
    case courierAssigned = "courier_assigned"
    case courierPickingUp = "courier_picking_up"
    case delivering
    case arriving
    case delivered
    case cancelled
    case unknown

    public var displayName: String {
        switch self {
        case .orderPlaced: "订单已提交"
        case .merchantConfirmed: "商家已接单"
        case .preparing: "商家备餐中"
        case .courierAssigned: "骑手已接单"
        case .courierPickingUp: "骑手取货中"
        case .delivering: "配送中"
        case .arriving: "即将送达"
        case .delivered: "已送达"
        case .cancelled: "已取消"
        case .unknown: "订单进行中"
        }
    }
}

public enum DeliverySourceFormat: String, Codable, Sendable, Equatable {
    case standardNotification = "standard_notification"
    case hyperOSFocus = "hyperos_focus"

    public var displayName: String {
        switch self {
        case .standardNotification: "Android 通知"
        case .hyperOSFocus: "HyperOS 焦点"
        }
    }
}

public struct DeliveryUpdate: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let parserVersion: Int
    public let eventId: String
    public let sourceEventKind: String
    public let capturedAt: Int64
    public let provider: DeliveryProvider
    public let stage: DeliveryStage
    public let statusText: String
    public let etaText: String?
    public let statusDetail: String?
    public let progressPercent: Int?
    public let sourceFormat: DeliverySourceFormat?
    public let confidence: Double
    public let orderKey: String
    public let sourcePackage: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case parserVersion
        case eventId
        case sourceEventKind
        case capturedAt
        case provider
        case stage = "state"
        case statusText
        case etaText
        case statusDetail
        case progressPercent
        case sourceFormat
        case confidence
        case orderKey
        case sourcePackage
    }

    public init(
        schemaVersion: Int = 1,
        parserVersion: Int = 1,
        eventId: String,
        sourceEventKind: String,
        capturedAt: Int64,
        provider: DeliveryProvider,
        stage: DeliveryStage,
        statusText: String,
        etaText: String?,
        statusDetail: String? = nil,
        progressPercent: Int? = nil,
        sourceFormat: DeliverySourceFormat? = nil,
        confidence: Double,
        orderKey: String,
        sourcePackage: String
    ) {
        self.schemaVersion = schemaVersion
        self.parserVersion = parserVersion
        self.eventId = eventId
        self.sourceEventKind = sourceEventKind
        self.capturedAt = capturedAt
        self.provider = provider
        self.stage = stage
        self.statusText = statusText
        self.etaText = etaText
        self.statusDetail = statusDetail
        self.progressPercent = progressPercent
        self.sourceFormat = sourceFormat
        self.confidence = confidence
        self.orderKey = orderKey
        self.sourcePackage = sourcePackage
    }
}

public enum DeliveryNotificationParser {
    public static func parse(_ notification: CapturedNotification) -> DeliveryUpdate? {
        guard notification.eventKind != "removed",
              notification.groupSummary != true,
              let provider = provider(for: notification.sourcePackage) else {
            return nil
        }

        let fields = [
            notification.title,
            notification.text,
            notification.bigText,
            notification.subText,
        ].compactMap { $0 } + (notification.textLines ?? [])
        let normalizedFields = fields.map(normalize).filter { !$0.isEmpty }
        let content = normalizedFields.joined(separator: " ")

        guard content.range(of: "GroupSummary", options: .caseInsensitive) == nil,
              !excludedTerms.contains(where: content.contains) else {
            return nil
        }
        if provider == .taobaoInstant,
           notification.sourcePackage == "com.taobao.taobao",
           parcelTerms.contains(where: content.contains) {
            return nil
        }

        guard let stage = stage(for: content) else { return nil }
        if stage != .unknown,
           !deliveryContextTerms.contains(where: content.contains) {
            return nil
        }
        return DeliveryUpdate(
            eventId: notification.eventId,
            sourceEventKind: notification.eventKind,
            capturedAt: notification.capturedAt,
            provider: provider,
            stage: stage,
            statusText: stage.displayName,
            etaText: extractETA(from: content),
            sourceFormat: .standardNotification,
            confidence: stage == .unknown ? 0.95 : 0.85,
            orderKey: notification.notificationKeyHash,
            sourcePackage: notification.sourcePackage
        )
    }

    private static func provider(for packageName: String) -> DeliveryProvider? {
        switch packageName {
        case "com.sankuai.meituan", "com.sankuai.meituan.takeoutnew":
            .meituan
        case "me.ele", "com.taobao.taobao":
            .taobaoInstant
        default:
            nil
        }
    }

    private static func stage(for content: String) -> DeliveryStage? {
        for (stage, terms) in stageRules where terms.contains(where: content.contains) {
            return stage
        }
        return nil
    }

    private static func extractETA(from content: String) -> String? {
        for pattern in etaPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: content,
                    range: NSRange(content.startIndex..., in: content)
                  ),
                  let range = Range(match.range(at: 1), in: content) else {
                continue
            }
            return normalize(String(content[range]))
                .replacingOccurrences(of: "：", with: ":")
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let excludedTerms = [
        "月付",
        "额度",
        "账单",
        "还款",
        "红包",
        "优惠券",
        "马上下单",
        "准时宝",
        "放心吃",
    ]

    private static let parcelTerms = [
        "宝贝",
        "快递",
        "物流进度",
        "已发货",
        "在途",
    ]

    // Only unknown is confirmed by the current fixture. Specific stages also require
    // explicit food-delivery context until real notifications cover those transitions.
    private static let stageRules: [(DeliveryStage, [String])] = [
        (.cancelled, ["订单已取消", "订单取消", "已取消"]),
        (.delivered, ["已送达", "配送完成", "订单已完成"]),
        (.arriving, ["即将送达", "即将到达", "马上送达", "快到了"]),
        (.delivering, ["骑手已取餐", "骑手已取货", "正在配送", "配送中", "送餐中", "正在送往"]),
        (.courierPickingUp, ["取货中", "取餐中", "骑手已到店", "骑手到店", "前往商家", "赶往商家"]),
        (.courierAssigned, ["骑手已接单", "骑手接单", "已分配骑手"]),
        (.preparing, ["正在备餐", "商家备餐", "正在制作", "商家制作"]),
        (.merchantConfirmed, ["商家已接单", "商家确认订单"]),
        (.orderPlaced, ["下单成功", "订单已提交"]),
        (.unknown, ["外卖订单正在进行中", "外卖订单进行中"]),
    ]

    private static let deliveryContextTerms = [
        "外卖",
        "骑手",
        "送餐",
        "备餐",
        "取餐",
        "商家",
    ]

    private static let etaPatterns = [
        #"(?:预计|约|大约)\s*(\d{1,2}[:：]\d{2})\s*(?:送达|到达)?"#,
        #"(\d{1,2}[:：]\d{2})\s*(?:送达|到达)"#,
        #"(?:预计|还有|约)\s*(\d{1,3}\s*分钟)\s*(?:送达|到达)?"#,
    ]
}
