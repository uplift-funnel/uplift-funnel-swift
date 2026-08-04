import Foundation

// What the person answered, readable while they are still answering.
//
// Until now the answers reached the host in exactly one place: the completion
// callback, once, at the end. An app that wanted to branch its own content on
// "which goal did they pick" had to catch that callback and store the answers
// itself — so the SDK collected the data and the host built the memory.
//
// This is the memory. It is also, deliberately, the part of the product that is
// hard to remove: once the app's content logic reads `UpliftFunnel.profile(_:)`,
// taking the SDK out is a sprint rather than an afternoon.
//
// ── What goes in ────────────────────────────────────────────────────────────
//
// Only committed variable writes — the same events analytics records as
// `variable_set`. Not the flow's declared defaults, not the `{{product.*}}`
// values the host published through `setProducts`, not the `userVariables` the
// host passed in at start. A profile is what the subject said; a default is what
// the author guessed, a price is a fact about the store, and a host-supplied
// variable is something the host already knows. Mixing them in would make
// `profileAll()` a bag of everything, and the one question it answers —
// "what has this person told us?" — would stop having an answer.
//
// ── Sensitive values ────────────────────────────────────────────────────────
//
// They are stored, like everything else. `sensitive` has always meant "the host
// sees it, the Uplift API does not" (see `FunnelVariable.sensitive`), and the
// host is who reads this. Withholding them here would make `profile(_:)` return
// a value before an app restart and nil after it, for reasons no caller can see.
// They live in `UserDefaults` unencrypted, which is the same place the host
// would have put them, and they never reach the uploader — that redaction is
// untouched and enforced separately.

/// One change to the profile. `value` is nil when the entry was cleared.
public struct ProfileChange: Sendable, Equatable {
    public let key: String
    public let value: String?

    public init(key: String, value: String?) {
        self.key = key
        self.value = value
    }
}

/// Versioned like the event queue: a shape change gets a new key rather than a
/// migration that has to be right the first time.
///
/// Outside the actor-isolated type so it can be a default argument — and so a
/// test can name the key without hopping to the main actor.
let kUpliftProfileDefaultsKey = "funnel.profile.v1"

@MainActor
final class ProfileStore {
    private let defaults: UserDefaults
    private let key: String
    private var values: [String: String]
    private var continuations: [UUID: AsyncStream<ProfileChange>.Continuation] = [:]

    init(defaults: UserDefaults, key: String = kUpliftProfileDefaultsKey) {
        self.defaults = defaults
        self.key = key
        self.values = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    var all: [String: String] { values }

    func value(_ name: String) -> String? { values[name] }

    /// Record an answer. No-op when the value is unchanged, so a re-commit
    /// (a focus-loss write right after a navigation flush) does not wake every
    /// observer for nothing.
    func set(_ name: String, _ value: String) {
        guard values[name] != value else { return }
        values[name] = value
        persist()
        publish(ProfileChange(key: name, value: value))
    }

    /// Fold the server's snapshot in *under* what this device already holds.
    ///
    /// Spec 15 §2 says the profile is the server snapshot plus the local
    /// session's variables, and the ordering is the whole substance of that
    /// sentence. A local value is either newer (the person answered it a moment
    /// ago, and the event carrying it may still be in the upload queue) or
    /// unknowable to the server — a `sensitive` answer never leaves the device
    /// at all. Letting the snapshot win would make an answer visibly revert
    /// mid-session.
    ///
    /// What it buys: answers given on another device, or before a reinstall,
    /// are readable here. That is the half of the profile a local store cannot
    /// have.
    func mergeSnapshot(_ snapshot: [String: String]) {
        var added: [ProfileChange] = []
        for (name, value) in snapshot where values[name] == nil {
            values[name] = value
            added.append(ProfileChange(key: name, value: value))
        }
        guard !added.isEmpty else { return }
        persist()
        for change in added.sorted(by: { $0.key < $1.key }) { publish(change) }
    }

    /// Drop everything. Called on `resetIdentity` — a new anonymous id means a
    /// different person on the device, and their profile starting out as the
    /// last person's answers is worse than starting empty.
    ///
    /// Emits one change per dropped key: a host that reacted to a value
    /// appearing has to be able to react to it going away.
    func clear() {
        guard !values.isEmpty else { return }
        let dropped = values.keys.sorted()
        values.removeAll()
        persist()
        for name in dropped {
            publish(ProfileChange(key: name, value: nil))
        }
    }

    /// A fresh stream per caller. `AsyncStream` has one consumer, so two
    /// observers sharing one stream would silently split the changes between
    /// them — each gets their own, and drops their continuation on cancellation.
    func changes() -> AsyncStream<ProfileChange> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations[token] = nil
                }
            }
        }
    }

    /// Test seam: how many observers are attached.
    var observerCount: Int { continuations.count }

    // MARK: - Private

    private func publish(_ change: ProfileChange) {
        for continuation in continuations.values {
            continuation.yield(change)
        }
    }

    private func persist() {
        if values.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(values, forKey: key)
        }
    }
}
