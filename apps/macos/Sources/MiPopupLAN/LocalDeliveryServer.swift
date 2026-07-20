import Foundation
import MiPopupCore
@preconcurrency import Network

public enum LocalDeliveryServerState: Sendable, Equatable {
    case stopped
    case waiting(String)
    case ready(port: UInt16)
    case failed(String)
}

public final class LocalDeliveryServer: @unchecked Sendable {
    public static let serviceType = "_mipopup._tcp"

    public typealias DeliveryHandler = @MainActor @Sendable (DeliveryUpdate) -> Void
    public typealias StateHandler = @MainActor @Sendable (LocalDeliveryServerState) -> Void

    public let restoredLatestDelivery: DeliveryUpdate?

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var decoder = LengthPrefixedFrameDecoder()
        var isReceiving = false
        var receivedFrameCount = 0

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "com.mipopup.macos.lan-server")
    private let serviceName: String
    private let advertiseBonjour: Bool
    private let store: RecentDeliveryStore
    private let onDelivery: DeliveryHandler
    private let onStateChange: StateHandler?
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var pendingEventIds: Set<String> = []

    public init(
        serviceName: String = "MiPopup",
        advertiseBonjour: Bool = true,
        store: RecentDeliveryStore = RecentDeliveryStore(),
        onStateChange: StateHandler? = nil,
        onDelivery: @escaping DeliveryHandler
    ) {
        self.serviceName = serviceName
        self.advertiseBonjour = advertiseBonjour
        self.store = store
        self.onStateChange = onStateChange
        self.onDelivery = onDelivery
        restoredLatestDelivery = store.latestDelivery
    }

    public func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: .any)
            if advertiseBonjour {
                listener.service = NWListener.Service(
                    name: serviceName,
                    type: Self.serviceType
                )
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.serviceRegistrationUpdateHandler = { change in
                #if DEBUG
                print("MiPopup LAN Bonjour registration: \(change)")
                #endif
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            publish(state: .failed(error.localizedDescription))
        }
    }

    private func stopOnQueue() {
        clients.values.forEach { $0.connection.cancel() }
        clients.removeAll()
        pendingEventIds.removeAll()
        listener?.cancel()
        listener = nil
        publish(state: .stopped)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .setup:
            break
        case .waiting(let error):
            publish(state: .waiting(error.localizedDescription))
        case .ready:
            guard let port = listener?.port?.rawValue else {
                publish(state: .failed("局域网监听端口不可用。"))
                return
            }
            publish(state: .ready(port: port))
        case .failed(let error):
            listener?.cancel()
            listener = nil
            publish(state: .failed(error.localizedDescription))
        case .cancelled:
            listener = nil
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 8 else {
            connection.cancel()
            return
        }

        let id = UUID()
        clients[id] = Client(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, id: id)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, id: UUID) {
        switch state {
        case .ready:
            receiveNext(from: id)
        case .failed, .cancelled:
            removeClient(id)
        default:
            break
        }
    }

    private func receiveNext(from id: UUID) {
        guard let client = clients[id], !client.isReceiving else { return }
        client.isReceiving = true
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self, let client = self.clients[id] else { return }
            client.isReceiving = false

            if let data, !data.isEmpty {
                do {
                    let frames = try client.decoder.append(data)
                    guard client.receivedFrameCount + frames.count <= 32 else {
                        self.removeClient(id)
                        return
                    }
                    client.receivedFrameCount += frames.count
                    for frame in frames {
                        try self.handle(frame: frame, from: id)
                    }
                } catch {
                    #if DEBUG
                    print("MiPopup LAN rejected frame: \(error.localizedDescription)")
                    #endif
                    self.removeClient(id)
                    return
                }
            }

            if isComplete || error != nil {
                self.removeClient(id)
            } else {
                self.receiveNext(from: id)
            }
        }
    }

    private func handle(frame: Data, from clientId: UUID) throws {
        let envelope = try DeliveryWireCodec.decodeEnvelope(frame)
        let update = envelope.payload

        if store.contains(eventId: update.eventId) {
            sendAcknowledgement(
                eventId: update.eventId,
                status: .duplicate,
                to: clientId
            )
            return
        }
        guard pendingEventIds.insert(update.eventId).inserted else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onDelivery(update)
            self.finishAccepting(update, clientId: clientId)
        }
    }

    private func finishAccepting(_ update: DeliveryUpdate, clientId: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingEventIds.remove(update.eventId)
            let inserted = self.store.record(update)
            self.sendAcknowledgement(
                eventId: update.eventId,
                status: inserted ? .accepted : .duplicate,
                to: clientId
            )
        }
    }

    private func sendAcknowledgement(
        eventId: String,
        status: DeliveryAcknowledgementStatus,
        to clientId: UUID
    ) {
        guard let client = clients[clientId] else { return }
        let acknowledgement = DeliveryAcknowledgement(
            eventId: eventId,
            status: status,
            acceptedAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        guard let payload = try? JSONEncoder().encode(acknowledgement),
              let frame = try? LengthPrefixedFrameEncoder.encode(payload) else {
            removeClient(clientId)
            return
        }
        client.connection.send(
            content: frame,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.removeClient(clientId)
                }
            }
        )
    }

    private func removeClient(_ id: UUID) {
        clients.removeValue(forKey: id)?.connection.cancel()
    }

    private func publish(state: LocalDeliveryServerState) {
        guard let onStateChange else { return }
        Task { @MainActor in
            onStateChange(state)
        }
    }
}
