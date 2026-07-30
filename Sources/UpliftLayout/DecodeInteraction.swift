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

    private static func collect(
        _ raw: [String: Any], path: String, input: LayoutInput, into map: inout InteractionMap
    ) {
        let behavior = raw["behavior"] as? [String: Any]
        if let g = behavior?["group"] as? [String: Any], let name = g["name"] as? String {
            map.groups[name] = GroupBehavior(
                name: name,
                autoAdvance: (g["auto_advance"] as? Bool) ?? false,
                multi: (g["multi"] as? Bool) ?? false,
                saveTo: (raw["bind"] as? [String: Any])?["save_to"] as? String
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
                target.input = InputBehavior(
                    saveTo: saveTo,
                    kind: i["kind"] as? String ?? "text",
                    placeholder: (raw["props"] as? [String: Any])?["placeholder"]
                        .map { localized($0, input) },
                    secure: (i["secure"] as? Bool) ?? false
                )
            }
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
