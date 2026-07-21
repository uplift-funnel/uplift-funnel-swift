import Foundation

// Lightweight primitive-tree model, ported from the Flutter SDK's
// `render/primitive/node.dart` (Spec v2 §2, §3).

/// A single node in a primitive tree. Untyped `props`/`style` JSON keeps the
/// model tiny and forward-compatible: unknown props ride along untouched and
/// unknown node types render a neutral placeholder (§9 unknown-node rule).
public struct PrimNode: Sendable {
    public let type: String
    public let id: String?
    public let style: JSONValue
    public let props: JSONValue
    public let children: [PrimNode]

    /// Data binding for smart nodes; `bind.save_to` is the target variable.
    public let bind: JSONValue

    public var saveTo: String? { bind["save_to"].stringValue }

    public init(json: JSONValue) {
        self.type = json["type"].stringValue ?? "unknown"
        self.id = json["id"].stringValue
        self.style = json["style"].objectValue != nil ? json["style"] : .object([:])
        self.props = json["props"].objectValue != nil ? json["props"] : .object([:])
        self.bind = json["bind"].objectValue != nil ? json["bind"] : .object([:])
        self.children = (json["children"].arrayValue ?? [])
            .filter { $0.objectValue != nil }
            .map { PrimNode(json: $0) }
    }

    public init(
        type: String,
        id: String? = nil,
        style: JSONValue = .object([:]),
        props: JSONValue = .object([:]),
        children: [PrimNode] = [],
        bind: JSONValue = .object([:])
    ) {
        self.type = type
        self.id = id
        self.style = style
        self.props = props
        self.children = children
        self.bind = bind
    }
}

/// Store product id of a raw `plan_picker` plan map for the CURRENT platform:
/// the `product_id_ios` / `product_id_android` override when running there
/// (macOS counts as iOS — same App Store catalog), else `product_id`. `nil`
/// when the plan declares none.
public func planProductId(
    _ plan: JSONValue,
    platform: String? = nil
) -> String? {
    let platform = platform ?? DeviceContext.platform
    let override: JSONValue
    switch platform {
    case "ios", "macos":
        override = plan["product_id_ios"]
    case "android":
        override = plan["product_id_android"]
    default:
        override = .null
    }
    let v = override.stringValue ?? plan["product_id"].stringValue
    return (v?.isEmpty == false) ? v : nil
}

/// A parsed primitive flow — just the bits the renderer needs: theme,
/// localization catalog and screens with their `root` trees.
public struct PrimFlow: Sendable {
    public let defaultLocale: String
    public let locales: [String]
    public let localizations: JSONValue
    public let theme: PrimTheme
    public let screens: [PrimScreen]

    public init(json: JSONValue) {
        self.defaultLocale = json["default_locale"].stringValue ?? "en"
        self.locales = (json["locales"].arrayValue ?? [])
            .compactMap { $0.stringifiedValue }
        self.localizations = json["localizations"].objectValue != nil
            ? json["localizations"] : .object([:])
        self.theme = PrimTheme(json: json["theme"])
        self.screens = (json["screens"].arrayValue ?? [])
            .filter { $0.objectValue != nil }
            .map { PrimScreen(json: $0) }
    }
}

/// A screen: chrome (top_bar / background / style) kept out of the tree,
/// `root` is the tree.
public struct PrimScreen: Sendable {
    public let id: String
    public let archetype: String?
    /// Raw top_bar chrome, e.g. `{ progress: "dots", close: true }`.
    public let topBar: JSONValue
    /// Raw full-bleed background: `{ asset: {kind, url}, overlay?, height? }`.
    public let background: JSONValue
    /// Raw per-screen style override; only `background` (full-frame color) is
    /// consumed at screen level — the rest styles the tree's own nodes.
    public let style: JSONValue
    public let root: PrimNode?

    public init(json: JSONValue) {
        self.id = json["id"].stringValue ?? ""
        self.archetype = json["archetype"].stringValue
        self.topBar = json["top_bar"].objectValue != nil ? json["top_bar"] : .object([:])
        self.background = json["background"].objectValue != nil ? json["background"] : .object([:])
        self.style = json["style"].objectValue != nil ? json["style"] : .object([:])
        self.root = json["root"].objectValue != nil ? PrimNode(json: json["root"]) : nil
    }
}

/// The theme tokens the renderer needs: colors, corner radius, spacing unit.
public struct PrimTheme: Sendable {
    public let colors: [String: String]
    public let cornerRadius: Double
    public let shadowStyle: String
    public let spacingUnit: Double
    public let fontFamily: String

    public init(json: JSONValue) {
        self.init(tokens: json["tokens"])
    }

    /// Builds from a `tokens` object (also used to select the
    /// `dark_mode_variant` token set — see `PrimTheme.resolve`).
    public init(tokens: JSONValue) {
        var colors: [String: String] = [:]
        for (key, value) in tokens["colors"].objectValue ?? [:] {
            colors[key] = value.stringifiedValue ?? value.serializedString()
        }
        self.colors = colors
        self.cornerRadius = tokens["shape"]["corner_radius"].doubleValue ?? 12
        self.shadowStyle = tokens["shape"]["shadow_style"].stringValue ?? "soft"
        self.spacingUnit = tokens["spacing"]["unit"].doubleValue ?? 4
        self.fontFamily = tokens["typography"]["font_family"].stringValue ?? "system"
    }

    /// Resolves the theme for the current appearance: picks
    /// `dark_mode_variant` tokens when `dark` and the flow declares them.
    public static func resolve(themeJson: JSONValue, dark: Bool) -> PrimTheme {
        if dark, themeJson["dark_mode_variant"].objectValue != nil {
            return PrimTheme(tokens: themeJson["dark_mode_variant"])
        }
        return PrimTheme(json: themeJson)
    }
}
