import CryptoKit
import Foundation
import MiPopupCore
@testable import MiPopupLAN
import Testing

struct MiPopupLANTests {
    @Test
    func decryptsAndroidCompatibleRelayEnvelope() throws {
        let keyData = Data((1 ... 32).map(UInt8.init))
        let configuration = try relayConfiguration(keyData: keyData)
        let update = deliveryUpdate(capturedAt: 2)
        let envelope = DeliveryUpdateEnvelope(
            deviceId: "a0b1c2d3-e4f5-4678-9123-abcdefabcdef",
            sequence: 7,
            sentAt: 40,
            payload: update
        )
        let plaintext = try JSONEncoder().encode(envelope)
        let template = RelayWireEvent(
            version: 1,
            channelId: "personal_channel_01",
            eventId: update.eventId,
            sequence: 7,
            sentAt: 42,
            nonce: Data(repeating: 3, count: 12).base64EncodedString(),
            ciphertext: ""
        )
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            nonce: try AES.GCM.Nonce(data: Data(repeating: 3, count: 12)),
            authenticating: RelayWireCodec.authenticatedData(for: template)
        )
        var combined = sealed.ciphertext
        combined.append(sealed.tag)
        let event = RelayWireEvent(
            version: template.version,
            channelId: template.channelId,
            eventId: template.eventId,
            sequence: template.sequence,
            sentAt: template.sentAt,
            nonce: template.nonce,
            ciphertext: combined.base64EncodedString()
        )

        let decoded = try RelayWireCodec.decrypt(
            JSONEncoder().encode(event),
            configuration: configuration
        )

        #expect(decoded.envelope.payload == update)
        #expect(decoded.relay.eventId == update.eventId)
    }

    @Test
    func rejectsRelayMetadataTampering() throws {
        let keyData = Data((1 ... 32).map(UInt8.init))
        let configuration = try relayConfiguration(keyData: keyData)
        let event = RelayWireEvent(
            version: 1,
            channelId: "personal_channel_01",
            eventId: "11111111-1111-4111-8111-111111111111",
            sequence: 7,
            sentAt: 42,
            nonce: Data(repeating: 3, count: 12).base64EncodedString(),
            ciphertext: Data(repeating: 4, count: 32).base64EncodedString()
        )

        #expect(throws: RelayWireError.invalidCiphertext) {
            try RelayWireCodec.decrypt(
                JSONEncoder().encode(event),
                configuration: configuration
            )
        }
    }

    @Test
    func rejectsInsecureRelayConfiguration() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let json = """
        {
          "baseURL": "http://relay.example.com",
          "channelId": "personal_channel_01",
          "token": "token-that-is-longer-than-thirty-two-characters",
          "encryptionKey": "\(key)"
        }
        """

        #expect(throws: RelayConfigurationError.insecureBaseURL) {
            try RelayConfiguration.decode(Data(json.utf8))
        }
    }

    @Test
    func rejectsWorldReadableRelayConfigurationFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiPopupRelayConfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("relay-config.json")
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let json = """
        {
          "baseURL": "https://relay.example.com",
          "channelId": "personal_channel_01",
          "token": "token-that-is-longer-than-thirty-two-characters",
          "encryptionKey": "\(key)"
        }
        """
        try Data(json.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        #expect(throws: RelayConfigurationError.insecureFilePermissions) {
            try RelayConfiguration.load(from: file)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try RelayConfiguration.load(from: file) != nil)
    }

    @Test @MainActor
    func externalRelayIngestUsesTheSharedRecentDeliveryStore() async throws {
        let suiteName = "MiPopupRelayIngestTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentDeliveryStore(defaults: defaults, key: "relay-ingest")
        var deliveredCount = 0
        let server = LocalDeliveryServer(
            advertiseBonjour: false,
            store: store,
            onDelivery: { _ in deliveredCount += 1 }
        )
        let update = deliveryUpdate(capturedAt: 2)

        let first = await server.ingest(update)
        let duplicate = await server.ingest(update)

        #expect(first == .accepted)
        #expect(duplicate == .duplicate)
        #expect(deliveredCount == 1)
        #expect(store.latestDelivery == update)
    }

    @Test
    func decodesFragmentedAndAdjacentLengthPrefixedFrames() throws {
        let firstPayload = Data(#"{"message":"first"}"#.utf8)
        let secondPayload = Data(#"{"message":"second"}"#.utf8)
        let firstFrame = try LengthPrefixedFrameEncoder.encode(firstPayload)
        let secondFrame = try LengthPrefixedFrameEncoder.encode(secondPayload)
        var decoder = LengthPrefixedFrameDecoder()

        #expect(try decoder.append(firstFrame.prefix(2)).isEmpty)

        var remaining = Data(firstFrame.dropFirst(2))
        remaining.append(secondFrame)
        let decoded = try decoder.append(remaining)

        #expect(decoded == [firstPayload, secondPayload])
    }

    @Test
    func rejectsEmptyAndOversizedFrames() throws {
        var emptyDecoder = LengthPrefixedFrameDecoder()
        #expect(throws: LengthPrefixedFrameError.emptyPayload) {
            try emptyDecoder.append(Data([0, 0, 0, 0]))
        }

        var oversizedDecoder = LengthPrefixedFrameDecoder()
        let oversizedLength = UInt32(LengthPrefixedFrameEncoder.maximumPayloadSize + 1)
        let prefix = Data([
            UInt8((oversizedLength >> 24) & 0xff),
            UInt8((oversizedLength >> 16) & 0xff),
            UInt8((oversizedLength >> 8) & 0xff),
            UInt8(oversizedLength & 0xff),
        ])
        #expect(
            throws: LengthPrefixedFrameError.frameTooLarge(
                LengthPrefixedFrameEncoder.maximumPayloadSize + 1
            )
        ) {
            try oversizedDecoder.append(prefix)
        }
    }

    @Test
    func validatesDeliveryEnvelopeAndRejectsInvalidMetadata() throws {
        let update = deliveryUpdate(capturedAt: 2)
        let envelope = DeliveryUpdateEnvelope(
            deviceId: UUID().uuidString,
            sequence: 1,
            sentAt: 3,
            payload: update
        )

        try DeliveryWireValidator.validate(envelope)

        let invalidSequence = DeliveryUpdateEnvelope(
            deviceId: envelope.deviceId,
            sequence: 0,
            sentAt: envelope.sentAt,
            payload: update
        )
        #expect(throws: DeliveryWireValidationError.invalidSequence) {
            try DeliveryWireValidator.validate(invalidSequence)
        }

        let invalidStatus = DeliveryUpdate(
            eventId: UUID().uuidString,
            sourceEventKind: "posted",
            capturedAt: 2,
            provider: .meituan,
            stage: .delivering,
            statusText: "任意远程文案",
            etaText: nil,
            confidence: 0.9,
            orderKey: "order-key",
            sourcePackage: "com.sankuai.meituan"
        )
        #expect(throws: DeliveryWireValidationError.invalidStatusText) {
            try DeliveryWireValidator.validate(invalidStatus)
        }
    }

    @Test
    func decodesAndroidDeliveryEnvelopeShape() throws {
        let json = """
        {
          "protocolVersion": 1,
          "type": "delivery_update",
          "deviceId": "a0b1c2d3-e4f5-4678-9123-abcdefabcdef",
          "sequence": 7,
          "sentAt": 1784390000000,
          "payload": {
            "schemaVersion": 1,
            "parserVersion": 1,
            "eventId": "01234567-89ab-4cde-8fab-0123456789ab",
            "sourceEventKind": "updated",
            "capturedAt": 1784390000000,
            "provider": "meituan",
            "state": "delivering",
            "statusText": "配送中",
            "etaText": "18:35",
            "confidence": 0.9,
            "orderKey": "notification-hash",
            "sourcePackage": "com.sankuai.meituan"
          }
        }
        """

        let envelope = try DeliveryWireCodec.decodeEnvelope(Data(json.utf8))

        #expect(envelope.sequence == 7)
        #expect(envelope.payload.stage == .delivering)
        #expect(envelope.payload.etaText == "18:35")
        #expect(envelope.payload.sourceFormat == nil)
    }

    @Test
    func decodesHyperOSFocusDeliveryDetails() throws {
        let json = """
        {
          "protocolVersion": 1,
          "type": "delivery_update",
          "deviceId": "a0b1c2d3-e4f5-4678-9123-abcdefabcdef",
          "sequence": 8,
          "sentAt": 1784390000000,
          "payload": {
            "schemaVersion": 1,
            "parserVersion": 2,
            "eventId": "01234567-89ab-4cde-8fab-0123456789ab",
            "sourceEventKind": "updated",
            "capturedAt": 1784390000000,
            "provider": "meituan",
            "state": "delivering",
            "statusText": "配送中",
            "etaText": "17分钟",
            "statusDetail": "骑手正在为您送货",
            "progressPercent": 45,
            "sourceFormat": "hyperos_focus",
            "confidence": 0.98,
            "orderKey": "notification-hash",
            "sourcePackage": "com.sankuai.meituan"
          }
        }
        """

        let update = try DeliveryWireCodec.decodeEnvelope(Data(json.utf8)).payload

        #expect(update.statusDetail == "骑手正在为您送货")
        #expect(update.progressPercent == 45)
        #expect(update.sourceFormat == .hyperOSFocus)
    }

    @Test
    func rejectsOutOfRangeDeliveryProgress() {
        let update = DeliveryUpdate(
            eventId: UUID().uuidString,
            sourceEventKind: "posted",
            capturedAt: 2,
            provider: .meituan,
            stage: .delivering,
            statusText: DeliveryStage.delivering.displayName,
            etaText: "17分钟",
            progressPercent: 101,
            sourceFormat: .hyperOSFocus,
            confidence: 0.98,
            orderKey: "order-key",
            sourcePackage: "com.sankuai.meituan"
        )

        #expect(throws: DeliveryWireValidationError.invalidProgressPercent) {
            try DeliveryWireValidator.validate(update)
        }
    }

    @Test
    func rejectsUnknownEnvelopeAndPayloadFields() {
        let unknownEnvelopeField = """
        {
          "protocolVersion": 1,
          "type": "delivery_update",
          "deviceId": "a0b1c2d3-e4f5-4678-9123-abcdefabcdef",
          "sequence": 7,
          "sentAt": 1784390000000,
          "unexpected": true,
          "payload": \(deliveryUpdateJSON)
        }
        """
        #expect(
            throws: DeliveryWireValidationError.unexpectedFields(["unexpected"])
        ) {
            try DeliveryWireCodec.decodeEnvelope(Data(unknownEnvelopeField.utf8))
        }

        let unknownPayloadField = """
        {
          "protocolVersion": 1,
          "type": "delivery_update",
          "deviceId": "a0b1c2d3-e4f5-4678-9123-abcdefabcdef",
          "sequence": 7,
          "sentAt": 1784390000000,
          "payload": {
            "schemaVersion": 1,
            "parserVersion": 1,
            "eventId": "01234567-89ab-4cde-8fab-0123456789ab",
            "sourceEventKind": "updated",
            "capturedAt": 1784390000000,
            "provider": "meituan",
            "state": "delivering",
            "statusText": "配送中",
            "confidence": 0.9,
            "orderKey": "notification-hash",
            "sourcePackage": "com.sankuai.meituan",
            "rawText": "must not cross the wire"
          }
        }
        """
        #expect(
            throws: DeliveryWireValidationError.unexpectedFields(["rawText"])
        ) {
            try DeliveryWireCodec.decodeEnvelope(Data(unknownPayloadField.utf8))
        }
    }

    @Test
    func acknowledgementUsesTheSharedWireShape() throws {
        let eventId = UUID().uuidString
        let acknowledgement = DeliveryAcknowledgement(
            eventId: eventId,
            status: .duplicate,
            acceptedAt: 42
        )
        let payload = try JSONEncoder().encode(acknowledgement)
        let object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        #expect(object["protocolVersion"] as? Int == 1)
        #expect(object["type"] as? String == "ack")
        #expect(object["eventId"] as? String == eventId)
        #expect(object["status"] as? String == "duplicate")
        #expect(object["acceptedAt"] as? Int == 42)
    }

    @Test
    func persistsRecentEventIdsAndNewestDelivery() throws {
        let suiteName = "MiPopupLANTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "state"
        let store = RecentDeliveryStore(defaults: defaults, key: key, capacity: 2)
        let oldest = deliveryUpdate(capturedAt: 1)
        let newest = deliveryUpdate(capturedAt: 3)
        let laterArrivalWithOlderTimestamp = deliveryUpdate(capturedAt: 2)

        #expect(store.record(oldest))
        #expect(store.record(newest))
        #expect(!store.record(newest))
        #expect(store.record(laterArrivalWithOlderTimestamp))
        #expect(!store.contains(eventId: oldest.eventId))
        #expect(store.contains(eventId: newest.eventId))
        #expect(store.latestDelivery == newest)

        let restored = RecentDeliveryStore(defaults: defaults, key: key, capacity: 2)
        #expect(restored.contains(eventId: newest.eventId))
        #expect(restored.contains(eventId: laterArrivalWithOlderTimestamp.eventId))
        #expect(restored.latestDelivery == newest)
    }

    @Test
    func persistsDismissalUntilANewerDeliveryArrives() throws {
        let suiteName = "MiPopupLANTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "state"
        let store = RecentDeliveryStore(defaults: defaults, key: key)
        let current = deliveryUpdate(capturedAt: 1)

        #expect(store.record(current))
        store.dismiss(eventId: current.eventId)
        #expect(store.latestDelivery == nil)

        let restored = RecentDeliveryStore(defaults: defaults, key: key)
        #expect(restored.latestDelivery == nil)

        let newer = deliveryUpdate(capturedAt: 2)
        #expect(restored.record(newer))
        #expect(restored.latestDelivery == newer)
    }

    private func deliveryUpdate(capturedAt: Int64) -> DeliveryUpdate {
        DeliveryUpdate(
            eventId: UUID().uuidString,
            sourceEventKind: "posted",
            capturedAt: capturedAt,
            provider: .meituan,
            stage: .delivering,
            statusText: DeliveryStage.delivering.displayName,
            etaText: "18:35",
            confidence: 0.9,
            orderKey: "order-key",
            sourcePackage: "com.sankuai.meituan"
        )
    }

    private func relayConfiguration(keyData: Data) throws -> RelayConfiguration {
        let json = """
        {
          "baseURL": "https://relay.example.com",
          "channelId": "personal_channel_01",
          "token": "token-that-is-longer-than-thirty-two-characters",
          "encryptionKey": "\(keyData.base64EncodedString())"
        }
        """
        return try RelayConfiguration.decode(Data(json.utf8))
    }

    private var deliveryUpdateJSON: String {
        """
        {
          "schemaVersion": 1,
          "parserVersion": 1,
          "eventId": "01234567-89ab-4cde-8fab-0123456789ab",
          "sourceEventKind": "updated",
          "capturedAt": 1784390000000,
          "provider": "meituan",
          "state": "delivering",
          "statusText": "配送中",
          "confidence": 0.9,
          "orderKey": "notification-hash",
          "sourcePackage": "com.sankuai.meituan"
        }
        """
    }
}
