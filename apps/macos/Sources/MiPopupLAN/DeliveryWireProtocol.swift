import Foundation
import MiPopupCore

public struct DeliveryUpdateEnvelope: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let type: String
    public let deviceId: String
    public let sequence: Int64
    public let sentAt: Int64
    public let payload: DeliveryUpdate

    public init(
        protocolVersion: Int = 1,
        type: String = "delivery_update",
        deviceId: String,
        sequence: Int64,
        sentAt: Int64,
        payload: DeliveryUpdate
    ) {
        self.protocolVersion = protocolVersion
        self.type = type
        self.deviceId = deviceId
        self.sequence = sequence
        self.sentAt = sentAt
        self.payload = payload
    }
}

public enum DeliveryAcknowledgementStatus: String, Codable, Sendable, Equatable {
    case accepted
    case duplicate
}

public struct DeliveryAcknowledgement: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let type: String
    public let eventId: String
    public let status: DeliveryAcknowledgementStatus
    public let acceptedAt: Int64

    public init(
        protocolVersion: Int = 1,
        type: String = "ack",
        eventId: String,
        status: DeliveryAcknowledgementStatus,
        acceptedAt: Int64
    ) {
        self.protocolVersion = protocolVersion
        self.type = type
        self.eventId = eventId
        self.status = status
        self.acceptedAt = acceptedAt
    }
}

public enum DeliveryWireValidationError: LocalizedError, Equatable {
    case invalidJSONShape
    case unexpectedFields([String])
    case unsupportedProtocolVersion(Int)
    case invalidMessageType(String)
    case invalidDeviceId
    case invalidSequence
    case invalidSentAt
    case unsupportedPayloadSchema(Int)
    case invalidParserVersion
    case invalidEventId
    case invalidSourceEventKind(String)
    case invalidCapturedAt
    case invalidStatusText
    case invalidEtaText
    case invalidConfidence
    case invalidOrderKey
    case invalidSourcePackage

    public var errorDescription: String? {
        switch self {
        case .invalidJSONShape:
            "局域网消息不是有效的 JSON 对象。"
        case .unexpectedFields(let fields):
            "局域网消息包含未声明字段：\(fields.joined(separator: "、"))。"
        case .unsupportedProtocolVersion(let version):
            "不支持局域网协议版本 \(version)。"
        case .invalidMessageType(let type):
            "不支持局域网消息类型 \(type)。"
        case .invalidDeviceId:
            "设备 ID 无效。"
        case .invalidSequence:
            "消息序号无效。"
        case .invalidSentAt:
            "消息发送时间无效。"
        case .unsupportedPayloadSchema(let version):
            "不支持配送消息版本 \(version)。"
        case .invalidParserVersion:
            "解析器版本无效。"
        case .invalidEventId:
            "事件 ID 无效。"
        case .invalidSourceEventKind(let kind):
            "通知事件类型无效：\(kind)。"
        case .invalidCapturedAt:
            "通知采集时间无效。"
        case .invalidStatusText:
            "配送状态文案无效。"
        case .invalidEtaText:
            "预计送达时间无效。"
        case .invalidConfidence:
            "配送状态置信度无效。"
        case .invalidOrderKey:
            "订单去重标识无效。"
        case .invalidSourcePackage:
            "配送来源应用无效。"
        }
    }
}

public enum DeliveryWireCodec {
    public static func decodeEnvelope(_ data: Data) throws -> DeliveryUpdateEnvelope {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any] else {
            throw DeliveryWireValidationError.invalidJSONShape
        }
        try rejectUnexpectedFields(
            in: root,
            allowed: [
                "protocolVersion",
                "type",
                "deviceId",
                "sequence",
                "sentAt",
                "payload",
            ]
        )
        try rejectUnexpectedFields(
            in: payload,
            allowed: [
                "schemaVersion",
                "parserVersion",
                "eventId",
                "sourceEventKind",
                "capturedAt",
                "provider",
                "state",
                "statusText",
                "etaText",
                "confidence",
                "orderKey",
                "sourcePackage",
            ]
        )

        let envelope = try JSONDecoder().decode(DeliveryUpdateEnvelope.self, from: data)
        try DeliveryWireValidator.validate(envelope)
        return envelope
    }

    private static func rejectUnexpectedFields(
        in object: [String: Any],
        allowed: Set<String>
    ) throws {
        let unexpected = Set(object.keys).subtracting(allowed).sorted()
        guard unexpected.isEmpty else {
            throw DeliveryWireValidationError.unexpectedFields(unexpected)
        }
    }
}

public enum DeliveryWireValidator {
    public static func validate(_ envelope: DeliveryUpdateEnvelope) throws {
        guard envelope.protocolVersion == 1 else {
            throw DeliveryWireValidationError.unsupportedProtocolVersion(envelope.protocolVersion)
        }
        guard envelope.type == "delivery_update" else {
            throw DeliveryWireValidationError.invalidMessageType(envelope.type)
        }
        guard UUID(uuidString: envelope.deviceId) != nil else {
            throw DeliveryWireValidationError.invalidDeviceId
        }
        guard envelope.sequence > 0 else {
            throw DeliveryWireValidationError.invalidSequence
        }
        guard envelope.sentAt >= 0 else {
            throw DeliveryWireValidationError.invalidSentAt
        }
        try validate(envelope.payload)
    }

    public static func validate(_ update: DeliveryUpdate) throws {
        guard update.schemaVersion == 1 else {
            throw DeliveryWireValidationError.unsupportedPayloadSchema(update.schemaVersion)
        }
        guard update.parserVersion > 0 else {
            throw DeliveryWireValidationError.invalidParserVersion
        }
        guard UUID(uuidString: update.eventId) != nil else {
            throw DeliveryWireValidationError.invalidEventId
        }
        guard ["posted", "active", "updated"].contains(update.sourceEventKind) else {
            throw DeliveryWireValidationError.invalidSourceEventKind(update.sourceEventKind)
        }
        guard update.capturedAt >= 0 else {
            throw DeliveryWireValidationError.invalidCapturedAt
        }
        guard update.statusText == update.stage.displayName else {
            throw DeliveryWireValidationError.invalidStatusText
        }
        if let eta = update.etaText {
            let trimmed = eta.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= 64,
                  trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw DeliveryWireValidationError.invalidEtaText
            }
        }
        guard update.confidence.isFinite, (0 ... 1).contains(update.confidence) else {
            throw DeliveryWireValidationError.invalidConfidence
        }
        guard isBoundedNonempty(update.orderKey, maximumLength: 256) else {
            throw DeliveryWireValidationError.invalidOrderKey
        }
        guard packages(for: update.provider).contains(update.sourcePackage) else {
            throw DeliveryWireValidationError.invalidSourcePackage
        }
    }

    private static func isBoundedNonempty(_ value: String, maximumLength: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= maximumLength
            && trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func packages(for provider: DeliveryProvider) -> Set<String> {
        switch provider {
        case .meituan:
            ["com.sankuai.meituan", "com.sankuai.meituan.takeoutnew"]
        case .taobaoInstant:
            ["com.taobao.taobao", "me.ele"]
        }
    }
}

public enum LengthPrefixedFrameError: LocalizedError, Equatable {
    case emptyPayload
    case frameTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyPayload:
            "局域网消息不能为空。"
        case .frameTooLarge(let size):
            "局域网消息超过大小限制：\(size) 字节。"
        }
    }
}

public enum LengthPrefixedFrameEncoder {
    public static let maximumPayloadSize = 16 * 1024

    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else {
            throw LengthPrefixedFrameError.emptyPayload
        }
        guard payload.count <= maximumPayloadSize else {
            throw LengthPrefixedFrameError.frameTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }
}

public struct LengthPrefixedFrameDecoder: Sendable {
    private var buffer = Data()
    private var expectedPayloadLength: Int?

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while true {
            if expectedPayloadLength == nil {
                guard buffer.count >= MemoryLayout<UInt32>.size else { break }
                let length = buffer.prefix(4).reduce(UInt32.zero) {
                    ($0 << 8) | UInt32($1)
                }
                buffer.removeFirst(4)

                guard length > 0 else {
                    reset()
                    throw LengthPrefixedFrameError.emptyPayload
                }
                guard length <= UInt32(LengthPrefixedFrameEncoder.maximumPayloadSize) else {
                    reset()
                    throw LengthPrefixedFrameError.frameTooLarge(Int(length))
                }
                expectedPayloadLength = Int(length)
            }

            guard let expectedPayloadLength,
                  buffer.count >= expectedPayloadLength else {
                break
            }
            frames.append(Data(buffer.prefix(expectedPayloadLength)))
            buffer.removeFirst(expectedPayloadLength)
            self.expectedPayloadLength = nil
        }

        return frames
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        expectedPayloadLength = nil
    }
}
