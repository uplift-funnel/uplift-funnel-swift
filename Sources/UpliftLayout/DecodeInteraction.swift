import Foundation

/// The document's `behavior` group → an `InteractionMap`.
///
/// Walks the RAW document rather than the laid-out tree, and deliberately: a
/// node removed by a failing condition has no frame, so it can never be hit,
/// and a map built from the raw tree is therefore no less correct and one pass
/// simpler. It also means interaction survives a layout that threw.
extension LayoutDecoder {
    public static func interactions(
        flow: [String: Any], screenIndex: Int, locale: String? = nil,
        input: LayoutInput = LayoutInput()
    ) -> InteractionMap {
        guard let screens = flow["screens"] as? [[String: Any]],
              screens.indices.contains(screenIndex),
              let root = screens[screenIndex]["root"] as? [String: Any]
        else { return InteractionMap() }

        var merged = input
        if merged.catalog.isEmpty {
            let loc = locale ?? (flow["default_locale"] as? String) ?? "en"
            let all = flow["localizations"] as? [String: [String: String]] ?? [:]
            merged.catalog = all[loc] ?? [:]
        }
        var map = InteractionMap()
        collect(root, path: "", input: merged, into: &map)
        return map
    }

    /// The `on_complete` action of a countdown on this screen that has reached
    /// zero, or nil while one is still running or the screen has none.
    ///
    /// Walks the raw document for the same reason `interactions` does, and asks
    /// `countdownVars` rather than recomputing the deadline, so "is it done"
    /// has exactly one definition and the token an author gates on and the
    /// action the engine fires can never disagree.
    ///
    /// Without this the field was inert: `behavior.countdown.on_complete` has
    /// been in the schema, in the templates and in served documents the whole
    /// time, and no renderer ever fired it — a loading screen with no button
    /// hung until the user force-quit.
    public static func countdownComplete(
        flow: [String: Any], screenIndex: Int, input: LayoutInput
    ) -> String? {
        guard let screens = flow["screens"] as? [[String: Any]],
              screens.indices.contains(screenIndex),
              let root = screens[screenIndex]["root"] as? [String: Any]
        else { return nil }

        var found: String?
        func walk(_ node: [String: Any]) {
            guard found == nil else { return }
            if let spec = (node["behavior"] as? [String: Any])?["countdown"] as? [String: Any],
               let action = spec["on_complete"] as? String,
               !action.isEmpty,
               countdownVars(spec, input: input)["countdown.done"] != nil {
                found = action
                return
            }
            for child in (node["children"] as? [[String: Any]]) ?? [] { walk(child) }
        }
        walk(root)
        return found
    }

    private static func collect(
        _ raw: [String: Any], path: String, input: LayoutInput, into map: inout InteractionMap
    ) {
        let behavior = raw["behavior"] as? [String: Any]
        if let g = behavior?["group"] as? [String: Any], let name = g["name"] as? String {
            // `mode`, not `multi`. The schema has only ever emitted
            // `behavior.group.mode: "single" | "multi"`; reading a `multi`
            // boolean that no document contains meant every multi-select group
            // decoded as single and each tap replaced the last answer.
            map.groups[name] = GroupBehavior(
                name: name,
                autoAdvance: (g["auto_advance"] as? Bool) ?? false,
                multi: (g["mode"] as? String) == "multi",
                saveTo: (raw["bind"] as? [String: Any])?["save_to"] as? String,
                min: (g["min"] as? NSNumber)?.intValue,
                max: (g["max"] as? NSNumber)?.intValue
            )
        }

        var target = TapTarget(path: path)
        if let s = behavior?["select"] as? [String: Any],
           let group = s["group"] as? String, let value = s["value"] as? String {
            target.select = SelectBehavior(
                group: group,
                value: value,
                title: (s["title"] != nil) ? localized(s["title"], input) : nil
            )
        }
        // A string or a list — the schema allows both and the web spreads it.
        if let one = behavior?["tap"] as? String {
            target.actions = [one]
        } else if let many = behavior?["tap"] as? [String] {
            target.actions = many
        }
        if let i = behavior?["input"] as? [String: Any] {
            // The field may be this node's own or a descendant's, the same way
            // validation resolves it: a box carrying `behavior.input` claims
            // the input beneath it, because the input has no edge of its own.
            if let saveTo = (raw["bind"] as? [String: Any])?["save_to"] as? String {
                let p = raw["props"] as? [String: Any]
                target.input = InputBehavior(
                    saveTo: saveTo,
                    kind: i["kind"] as? String ?? "text",
                    placeholder: p?["placeholder"].map { localized($0, input) },
                    secure: (i["secure"] as? Bool) ?? false,
                    min: (p?["min"] as? NSNumber)?.doubleValue,
                    max: (p?["max"] as? NSNumber)?.doubleValue,
                    step: (p?["step"] as? NSNumber)?.doubleValue,
                    variant: p?["variant"] as? String
                )
            }
        }
        // The sealed leaves. Their behaviour is their TYPE — none of them
        // carries `behavior.tap` — so each is claimed here or not at all.
        let saveTo = (raw["bind"] as? [String: Any])?["save_to"] as? String
        let props = raw["props"] as? [String: Any]
        switch raw["type"] as? String {
        case "photo_upload":
            if let saveTo {
                target.photoUpload = PhotoUploadBehavior(
                    saveTo: saveTo,
                    source: props?["source"] as? String ?? "both",
                    shape: props?["shape"] as? String ?? "square"
                )
            }
        case "signin":
            if let saveTo {
                let listed = (props?["providers"] as? [[String: Any]]) ?? []
                var labels: [String: String] = [:]
                for entry in listed {
                    guard let id = entry["provider"] as? String, entry["label"] != nil else { continue }
                    labels[id] = localized(entry["label"], input)
                }
                target.signIn = SignInBehavior(
                    saveTo: saveTo,
                    providers: listed.compactMap { $0["provider"] as? String },
                    labels: labels,
                    appearance: props?["appearance"] as? String ?? "auto",
                    advanceOnSuccess: (props?["advance_on_success"] as? Bool) ?? true
                )
            }
        case "permission":
            if let saveTo {
                target.permission = PermissionBehavior(
                    saveTo: saveTo,
                    permission: props?["permission"] as? String ?? "notifications",
                    advanceOnResult: (props?["advance_on_result"] as? Bool) ?? true
                )
            }
        default:
            break
        }

        if target.isInteractive { map.targets[path] = target }

        for (index, child) in ((raw["children"] as? [[String: Any]]) ?? []).enumerated() {
            collect(
                child,
                path: path.isEmpty ? "\(index)" : "\(path).\(index)",
                input: input, into: &map
            )
        }
    }
}
