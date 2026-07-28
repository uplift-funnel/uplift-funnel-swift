import Foundation

// How a `progress` node advances its screen.
//
// Extracted from `renderProgress` so it can be tested: the package carries no
// ViewInspector, so a decision left inside a SwiftUI `body` is unreachable from
// the suite — and this is exactly the decision that shipped a screen which drew
// its bar at 60% and never moved.

/// Fallback delay for a progress node that must advance but wasn't given a
/// usable duration. Matches what the editor seeds into new nodes.
let kDefaultProgressMs = 3000

/// What a progress node's props mean for advancing.
struct ProgressAdvancePlan: Equatable {
    /// The widget the chosen branch builds fires `next` by itself.
    let selfFires: Bool
    /// It doesn't, so it needs an `AdvanceAfter` wrapper.
    let needsTimeout: Bool
    /// The delay either path runs on, already clamped.
    let effectiveMs: Int

    /// True when this node advances its screen at all.
    var advances: Bool { selfFires || needsTimeout }
}

/// The delay a progress node actually advances on.
///
/// `duration_ms` is optional and `0` is schema-valid, but neither means
/// "advance instantly" — they mean the author never chose. Absent, zero and
/// negative all fall back to `kDefaultProgressMs`; a fractional value truncates
/// rather than being discarded.
///
/// Clamping is not cosmetic: `UInt64(negativeInt)` traps, and a large value
/// overflows the `* 1_000_000` conversion to nanoseconds. Both were reachable
/// from schema-valid content.
func effectiveProgressMs(_ raw: JSONValue) -> Int {
    let parsed: Int
    if let i = raw.intValue {
        parsed = i
    } else if let d = raw.doubleValue, d.isFinite {
        parsed = d > Double(Int.max) ? Int.max : Int(d)
    } else {
        parsed = 0
    }
    return min(max(parsed > 0 ? parsed : kDefaultProgressMs, 0), 600_000)
}

/// Bounds a millisecond value so converting it to nanoseconds is total.
///
/// `UInt64(negativeInt)` traps and `huge * 1_000_000` overflows, and both were
/// reachable from schema-valid content — `duration_ms` has `minimum: 0` and no
/// maximum.
func clampedMs(_ ms: Int) -> Int { min(max(ms, 0), 600_000) }

/// Whether the node was given a duration it can animate to completion on.
func hasAuthoredDuration(_ raw: JSONValue) -> Bool {
    if let i = raw.intValue { return i > 0 }
    if let d = raw.doubleValue, d.isFinite { return d >= 1 }
    return false
}

/// Decides how a progress node advances.
///
/// `screenHasExit` is false when nothing else on the screen can move the user
/// forward, which makes this node the only way out — so it advances even when
/// the author never set `advance_on_complete`. That omission is what produced
/// the original hang, and every prop-keyed fix missed it.
///
/// `selfFires` and `needsTimeout` are exact negations of each other rather than
/// two independent heuristics, so no shape can arm both paths and step two
/// screens on one tick.
func progressAdvancePlan(props p: JSONValue, screenHasExit: Bool)
    -> ProgressAdvancePlan
{
    let style = p["style"].stringValue ?? "bar"
    let duration = p["duration_ms"]
    let shouldAdvance = p["advance_on_complete"].boolValue == true || !screenHasExit

    guard shouldAdvance else {
        return ProgressAdvancePlan(
            selfFires: false, needsTimeout: false,
            effectiveMs: effectiveProgressMs(duration))
    }

    // Mirrors the branch `renderProgress` picks, because that's what decides
    // whether anything fires on its own:
    //   spinner / percentage / steps — draw no completion, never self-fire.
    //   animated_list WITH items     — the checklist schedules its own advance.
    //   everything else              — the bar, which fires off its animation
    //                                  completing, and that animation only
    //                                  exists when a duration was authored.
    let selfFires: Bool
    switch style {
    case "spinner", "percentage", "steps":
        selfFires = false
    case "animated_list" where !(p["items"].arrayValue ?? []).isEmpty:
        selfFires = true
    default:
        selfFires = hasAuthoredDuration(duration)
    }

    return ProgressAdvancePlan(
        selfFires: selfFires,
        needsTimeout: !selfFires,
        effectiveMs: effectiveProgressMs(duration))
}
