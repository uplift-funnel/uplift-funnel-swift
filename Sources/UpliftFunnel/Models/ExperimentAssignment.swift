import Foundation

/// Typed A/B assignment surfaced to host code.
///
/// Parsed from the two response headers the experiments endpoint returns:
///
///   - `X-Uplift-Experiment: <experimentId>:<variantId>`
///   - `X-Uplift-Variant-Name: <label, percent-encoded UTF-8>` (optional)
///
/// The name header is percent-encoded by the server (HTTP header values must
/// be ISO-8859-1, names are user input — em-dashes, Turkish characters,
/// emoji) and decoded here, symmetrically.
///
/// A running experiment that the subject was bucketed into yields a non-nil
/// assignment; no experiment / not-in-traffic yields nil (the header is
/// simply absent).
public struct UpliftFunnelExperimentAssignment: Sendable, Equatable, Hashable {
    /// The experiment the subject was routed by.
    public let experimentId: String

    /// The variant the subject is stickily bucketed into.
    public let variantId: String

    /// Human-readable variant label (`baseline`, `blue-cta`, …) when the
    /// server sent `X-Uplift-Variant-Name`; nil otherwise.
    public let variantName: String?

    public init(experimentId: String, variantId: String, variantName: String? = nil) {
        self.experimentId = experimentId
        self.variantId = variantId
        self.variantName = variantName
    }

    /// Parse from the raw header pair. Returns nil when `experimentHeader`
    /// is absent/blank or doesn't contain the expected `<expId>:<variantId>`
    /// shape — a malformed header must never crash the SDK, it just means
    /// "no assignment".
    public static func fromHeaders(
        experimentHeader: String?,
        variantNameHeader: String?
    ) -> UpliftFunnelExperimentAssignment? {
        guard let experimentHeader else { return nil }
        let raw = experimentHeader.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        guard let sep = raw.firstIndex(of: ":"),
              sep != raw.startIndex,
              raw.index(after: sep) != raw.endIndex else { return nil }
        let experimentId = String(raw[..<sep]).trimmingCharacters(in: .whitespaces)
        let variantId = String(raw[raw.index(after: sep)...])
            .trimmingCharacters(in: .whitespaces)
        guard !experimentId.isEmpty, !variantId.isEmpty else { return nil }
        let name = decodeNameHeader(
            variantNameHeader?.trimmingCharacters(in: .whitespaces))
        return UpliftFunnelExperimentAssignment(
            experimentId: experimentId,
            variantId: variantId,
            variantName: (name?.isEmpty == false) ? name : nil)
    }

    /// The server percent-encodes the name header; decode it back. A raw
    /// (legacy or hand-crafted) value that isn't valid percent-encoding is
    /// kept as-is — a malformed header must never crash the SDK.
    private static func decodeNameHeader(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.removingPercentEncoding ?? raw
    }

    /// The compact `<expId>:<variantId>` form.
    public func toHeaderValue() -> String { "\(experimentId):\(variantId)" }

    /// Serialize for UserDefaults persistence. Includes the variant name so
    /// a warm-cache start can surface the full assignment.
    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "experiment_id": .string(experimentId),
            "variant_id": .string(variantId),
        ]
        if let variantName { obj["variant_name"] = .string(variantName) }
        return .object(obj)
    }

    /// Inverse of `toJSON()`. Returns nil on any malformed/partial input.
    static func fromJSON(_ json: JSONValue) -> UpliftFunnelExperimentAssignment? {
        guard let expId = json["experiment_id"].stringValue, !expId.isEmpty,
              let varId = json["variant_id"].stringValue, !varId.isEmpty else {
            return nil
        }
        let name = json["variant_name"].stringValue
        return UpliftFunnelExperimentAssignment(
            experimentId: expId, variantId: varId,
            variantName: (name?.isEmpty == false) ? name : nil)
    }
}
