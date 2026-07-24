import CryptoKit
import Foundation

public enum RelayConfigurationError: LocalizedError, Equatable {
    case invalidJSON
    case unexpectedFields([String])
    case insecureBaseURL
    case invalidChannelId
    case invalidToken
    case invalidEncryptionKey
    case insecureFilePermissions

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "中继配置不是有效的 JSON 对象。"
        case .unexpectedFields(let fields):
            "中继配置包含未声明字段：\(fields.joined(separator: "、"))。"
        case .insecureBaseURL:
            "中继地址必须是没有账号、查询参数或子路径的 HTTPS 地址。"
        case .invalidChannelId:
            "中继 channelId 格式无效。"
        case .invalidToken:
            "中继 token 格式无效。"
        case .invalidEncryptionKey:
            "中继内容密钥必须是 32 字节标准 Base64。"
        case .insecureFilePermissions:
            "中继配置可被同组或其他用户读取；请执行 chmod 600。"
        }
    }
}

public struct RelayConfiguration: Sendable {
    let baseURL: URL
    let channelId: String
    let token: String
    let encryptionKey: Data

    public static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent("MiPopup", isDirectory: true)
            .appendingPathComponent("relay-config.json", isDirectory: false)
    }

    public static func load(from url: URL? = nil) throws -> RelayConfiguration? {
        let target = url ?? defaultFileURL
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o077 == 0 else {
            throw RelayConfigurationError.insecureFilePermissions
        }
        return try decode(Data(contentsOf: target))
    }

    static func decode(_ data: Data) throws -> RelayConfiguration {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayConfigurationError.invalidJSON
        }
        let allowed = Set(["baseURL", "channelId", "token", "encryptionKey"])
        let unexpected = Set(object.keys).subtracting(allowed).sorted()
        guard unexpected.isEmpty, object.keys.count == allowed.count else {
            throw RelayConfigurationError.unexpectedFields(unexpected)
        }
        guard let rawBaseURL = object["baseURL"] as? String,
              let baseURL = URL(string: rawBaseURL),
              let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw RelayConfigurationError.insecureBaseURL
        }
        guard let channelId = object["channelId"] as? String,
              channelId.range(of: #"^[A-Za-z0-9_-]{8,64}$"#, options: .regularExpression) != nil else {
            throw RelayConfigurationError.invalidChannelId
        }
        guard let token = object["token"] as? String,
              (32 ... 256).contains(token.count),
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw RelayConfigurationError.invalidToken
        }
        guard let encodedKey = object["encryptionKey"] as? String,
              let encryptionKey = Data(base64Encoded: encodedKey),
              encryptionKey.count == 32,
              encryptionKey.base64EncodedString() == encodedKey else {
            throw RelayConfigurationError.invalidEncryptionKey
        }
        return RelayConfiguration(
            baseURL: baseURL,
            channelId: channelId,
            token: token,
            encryptionKey: encryptionKey
        )
    }

    var streamURL: URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/stream"),
            resolvingAgainstBaseURL: false
        )!
        components.scheme = "wss"
        return components.url!
    }

    var acknowledgementURL: URL {
        baseURL.appendingPathComponent("v1/acks")
    }
}

struct RelayWireEvent: Codable, Sendable, Equatable {
    let version: Int
    let channelId: String
    let eventId: String
    let sequence: Int64
    let sentAt: Int64
    let nonce: String
    let ciphertext: String
}

struct RelayDecodedEvent: Sendable, Equatable {
    let relay: RelayWireEvent
    let envelope: DeliveryUpdateEnvelope
}

enum RelayWireError: LocalizedError, Equatable {
    case invalidJSON
    case unexpectedFields([String])
    case invalidMetadata
    case invalidNonce
    case invalidCiphertext
    case metadataMismatch

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "中继消息不是有效的 JSON 对象。"
        case .unexpectedFields(let fields):
            "中继消息包含未声明字段：\(fields.joined(separator: "、"))。"
        case .invalidMetadata:
            "中继消息元数据无效。"
        case .invalidNonce:
            "中继消息 nonce 无效。"
        case .invalidCiphertext:
            "中继消息无法通过认证解密。"
        case .metadataMismatch:
            "中继密文与外层元数据不一致。"
        }
    }
}

enum RelayWireCodec {
    static func decrypt(_ data: Data, configuration: RelayConfiguration) throws -> RelayDecodedEvent {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayWireError.invalidJSON
        }
        let allowed = Set([
            "version", "channelId", "eventId", "sequence", "sentAt", "nonce", "ciphertext",
        ])
        let unexpected = Set(object.keys).subtracting(allowed).sorted()
        guard unexpected.isEmpty, object.keys.count == allowed.count else {
            throw RelayWireError.unexpectedFields(unexpected)
        }
        let event = try JSONDecoder().decode(RelayWireEvent.self, from: data)
        guard event.version == 1,
              event.channelId == configuration.channelId,
              UUID(uuidString: event.eventId) != nil,
              event.sequence > 0,
              event.sentAt >= 0 else {
            throw RelayWireError.invalidMetadata
        }
        guard let nonceData = canonicalBase64(event.nonce), nonceData.count == 12 else {
            throw RelayWireError.invalidNonce
        }
        guard let combinedCiphertext = canonicalBase64(event.ciphertext),
              combinedCiphertext.count > 16,
              combinedCiphertext.count <= 24 * 1024 else {
            throw RelayWireError.invalidCiphertext
        }

        let ciphertext = combinedCiphertext.dropLast(16)
        let tag = combinedCiphertext.suffix(16)
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: configuration.encryptionKey),
                authenticating: authenticatedData(for: event)
            )
            let envelope = try DeliveryWireCodec.decodeEnvelope(plaintext)
            guard envelope.sequence == event.sequence,
                  envelope.payload.eventId == event.eventId else {
                throw RelayWireError.metadataMismatch
            }
            return RelayDecodedEvent(relay: event, envelope: envelope)
        } catch let error as RelayWireError {
            throw error
        } catch {
            throw RelayWireError.invalidCiphertext
        }
    }

    static func authenticatedData(for event: RelayWireEvent) -> Data {
        Data("mipopup-relay-v1\n\(event.channelId)\n\(event.eventId)\n\(event.sequence)\n\(event.sentAt)".utf8)
    }

    private static func canonicalBase64(_ value: String) -> Data? {
        guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else {
            return nil
        }
        return data
    }
}
