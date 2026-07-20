import Foundation
import MiPopupCore

public final class RecentDeliveryStore: @unchecked Sendable {
    public static let defaultKey = "MiPopup.lanDeliveryState.v1"

    private struct State: Codable {
        var recentEventIds: [String]
        var latestDelivery: DeliveryUpdate?
    }

    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int
    private let lock = NSLock()
    private var state: State
    private var recentEventIdSet: Set<String>

    public init(
        defaults: UserDefaults = .standard,
        key: String = RecentDeliveryStore.defaultKey,
        capacity: Int = 256
    ) {
        self.defaults = defaults
        self.key = key
        self.capacity = max(1, capacity)

        let restored = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        let ids = Array((restored?.recentEventIds ?? []).suffix(self.capacity))
        state = State(
            recentEventIds: ids,
            latestDelivery: restored?.latestDelivery
        )
        recentEventIdSet = Set(ids)
    }

    public var latestDelivery: DeliveryUpdate? {
        withLock { state.latestDelivery }
    }

    public func contains(eventId: String) -> Bool {
        withLock { recentEventIdSet.contains(eventId) }
    }

    @discardableResult
    public func record(_ update: DeliveryUpdate) -> Bool {
        withLock {
            guard recentEventIdSet.insert(update.eventId).inserted else {
                return false
            }

            state.recentEventIds.append(update.eventId)
            if state.recentEventIds.count > capacity {
                let overflow = state.recentEventIds.count - capacity
                let removed = state.recentEventIds.prefix(overflow)
                state.recentEventIds.removeFirst(overflow)
                recentEventIdSet.subtract(removed)
            }
            if state.latestDelivery == nil
                || update.capturedAt >= (state.latestDelivery?.capturedAt ?? 0) {
                state.latestDelivery = update
            }
            persist()
            return true
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
