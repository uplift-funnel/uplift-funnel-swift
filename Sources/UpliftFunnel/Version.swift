/// SDK version reported in analytics event context (`context.sdk_version`).
///
/// A Swift package has no manifest version — the git tag is the version — so
/// nothing pins this automatically. `VersionTests` asserts it matches the
/// version the README tells people to install, which is the pair that actually
/// drifts: it already did once, and every event reported 0.1.0 while the
/// README said 0.5.0.
public let kUpliftFunnelSdkVersion = "0.10.1"
