import Foundation
import MiPopupCore

public enum RelayDeliveryClientState: Sendable, Equatable {
    case stopped
    case connecting
    case connected
    case waitingToRetry(String)
}

@MainActor
public final class RelayDeliveryClient {
    public typealias DeliveryHandler = @MainActor @Sendable (DeliveryUpdate) async -> Void
    public typealias StateHandler = @MainActor @Sendable (RelayDeliveryClientState) -> Void

    private let configuration: RelayConfiguration
    private let onDelivery: DeliveryHandler
    private let onStateChange: StateHandler?
    private let session: URLSession
    private var runTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?

    public init(
        configuration: RelayConfiguration,
        onStateChange: StateHandler? = nil,
        onDelivery: @escaping DeliveryHandler
    ) {
        self.configuration = configuration
        self.onStateChange = onStateChange
        self.onDelivery = onDelivery
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 15
        // A short resource timeout would tear down an otherwise healthy WSS task.
        sessionConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        session = URLSession(configuration: sessionConfiguration)
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session.invalidateAndCancel()
        onStateChange?(.stopped)
    }

    private func run() async {
        var failureCount = 0
        while !Task.isCancelled {
            do {
                try await connectAndReceive()
                failureCount = 0
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                let delay = Self.retryDelays[min(failureCount, Self.retryDelays.count - 1)]
                failureCount += 1
                onStateChange?(.waitingToRetry(Self.shortError(error)))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        webSocket = nil
    }

    private func connectAndReceive() async throws {
        onStateChange?(.connecting)
        var request = URLRequest(url: configuration.streamURL)
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 32 * 1024
        webSocket = socket
        socket.resume()
        onStateChange?(.connected)
        let pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                if Task.isCancelled { return }
                do {
                    try await ping(socket)
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }

        defer {
            pingTask.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            if webSocket === socket { webSocket = nil }
        }
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let value):
                data = value
            case .string(let value):
                data = Data(value.utf8)
            @unknown default:
                continue
            }
            let decoded: RelayDecodedEvent
            do {
                decoded = try RelayWireCodec.decrypt(data, configuration: configuration)
            } catch {
                #if DEBUG
                print("MiPopup Relay rejected an event: \(error.localizedDescription)")
                #endif
                continue
            }
            await onDelivery(decoded.envelope.payload)
            try await acknowledge(eventId: decoded.relay.eventId)
        }
    }

    private func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func acknowledge(eventId: String) async throws {
        var request = URLRequest(url: configuration.acknowledgementURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["eventId": eventId])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static let retryDelays = [1, 2, 5, 10, 30, 60]

    private static func shortError(_ error: Error) -> String {
        String(error.localizedDescription.prefix(160))
    }
}
