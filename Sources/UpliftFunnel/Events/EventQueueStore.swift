import Foundation

/// Persistence for the pending-event buffer so events survive an app kill.
public protocol EventQueueStore: Sendable {
    func load() -> [[String: JSONValue]]
    func save(_ events: [[String: JSONValue]])
    func clear()
}

/// UserDefaults-backed store. Stores the buffer as a JSON array under a
/// single key (same name the Flutter SDK uses in SharedPreferences).
public final class UserDefaultsEventQueueStore: EventQueueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "funnel.event_queue.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [[String: JSONValue]] {
        guard let raw = defaults.string(forKey: key), !raw.isEmpty else { return [] }
        // Corrupt entry — drop it rather than crash on next launch.
        guard let decoded = try? JSONValue.parse(raw),
              let list = decoded.arrayValue else { return [] }
        return list.compactMap { $0.objectValue }
    }

    public func save(_ events: [[String: JSONValue]]) {
        let json = JSONValue.array(events.map { .object($0) })
        defaults.set(json.serializedString(), forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

final class InMemoryEventQueueStore: EventQueueStore, @unchecked Sendable {
    private var stored: [[String: JSONValue]] = []
    private let lock = NSLock()

    var events: [[String: JSONValue]] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func load() -> [[String: JSONValue]] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ events: [[String: JSONValue]]) {
        lock.lock(); defer { lock.unlock() }
        stored = events
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = []
    }
}
