import Foundation

/// Random-id generators matching the Flutter SDK's wire formats.
enum Identifiers {
    static func randomHex(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var out = String()
        out.reserveCapacity(byteCount * 2)
        for _ in 0..<byteCount {
            let byte = UInt8.random(in: 0...255, using: &generator)
            out += String(format: "%02x", byte)
        }
        return out
    }

    /// `anon_<32 hex>` — persistent anonymous subject id.
    static func anonymousId() -> String { "anon_" + randomHex(byteCount: 16) }

    /// `sess_<24 hex>` — per-flow / per-launch session id.
    static func sessionId() -> String { "sess_" + randomHex(byteCount: 12) }

    /// `e_<32 hex>` — client-side event dedup id.
    static func eventId() -> String { "e_" + randomHex(byteCount: 16) }
}
