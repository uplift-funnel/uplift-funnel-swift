import Foundation

// Canonical runtime models, ported from the Flutter SDK's `models.dart`.
// The SDK renders the server-expanded primitive tree, so these stay thin:
// a flow, its screens (each carrying a primitive `root` tree), transitions,
// variables and theme tokens. Archetype lowering happens server-side and
// never reaches the device.

// MARK: - Errors

/// A transition didn't lead anywhere reachable, or a comparison couldn't be
/// made. Shared by the engine and the condition evaluator.
public struct FlowEngineError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "FlowEngineError: \(message)" }
}

/// The served flow JSON doesn't satisfy the contract (missing required
/// fields, unknown enum values in typed positions). The fetcher maps this to
/// `invalidPayload` and falls back to cache.
public struct FlowParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "FlowParseError: \(message)" }
}

// MARK: - Transition + Condition

public enum FunnelConditionOp: String, CaseIterable, Sendable {
    case eq = "=="
    case neq = "!="
    case gt = ">"
    case lt = "<"
    case gte = ">="
    case lte = "<="
    case contains = "contains"
    case notContains = "not_contains"
    case isSet = "is_set"
    case isNotSet = "is_not_set"
}

public struct FunnelCondition: Sendable, Equatable {
    /// Variable name. A flow-declared name (`goal`) or a context path
    /// (`device.platform`).
    public let varName: String
    public let op: FunnelConditionOp
    /// Comparison value; `.null` for `is_set` / `is_not_set`.
    public let value: JSONValue

    public init(varName: String, op: FunnelConditionOp, value: JSONValue = .null) {
        self.varName = varName
        self.op = op
        self.value = value
    }

    public init(json: JSONValue) throws {
        guard let varName = json["var"].stringValue else {
            throw FlowParseError("Condition is missing \"var\": \(json.serializedString())")
        }
        guard let opRaw = json["op"].stringValue,
              let op = FunnelConditionOp(rawValue: opRaw) else {
            throw FlowParseError("Unknown condition op: \(json["op"].serializedString())")
        }
        self.varName = varName
        self.op = op
        self.value = json["value"]
    }
}

public struct FunnelTransition: Sendable, Equatable {
    /// `nil` means this is the default fall-through rule.
    public let condition: FunnelCondition?
    /// Either a screen id within the same flow, or `end:<reason>`.
    public let go: String

    public init(condition: FunnelCondition? = nil, go: String) {
        self.condition = condition
        self.go = go
    }

    public var isDefault: Bool { condition == nil }
    public var isTerminal: Bool { go.hasPrefix("end:") }
    public var terminalReason: String? {
        isTerminal ? String(go.dropFirst(4)) : nil
    }

    public init(json: JSONValue) throws {
        guard let go = json["go"].stringValue else {
            throw FlowParseError("Transition is missing \"go\": \(json.serializedString())")
        }
        self.go = go
        self.condition = json["if"].objectValue != nil
            ? try FunnelCondition(json: json["if"])
            : nil
    }
}

// MARK: - Variable

public enum FunnelVariableType: String, CaseIterable, Sendable {
    case string
    case number
    case boolean
    case arrayString = "array_string"
    case date
}

public struct FunnelVariable: Sendable, Equatable {
    public let name: String
    public let type: FunnelVariableType
    public let defaultValue: JSONValue

    /// Whether this answer stays on the device.
    ///
    /// The host app always receives the value — it's their user's data, and
    /// collecting it is the point. This governs only what reaches the Uplift
    /// API: a sensitive variable is reported as answered/not-answered, never
    /// as its content. Set in the dashboard, and derived server-side from the
    /// input that writes it, so flows authored before the flag existed arrive
    /// classified.
    public let sensitive: Bool

    public init(json: JSONValue) throws {
        guard let name = json["name"].stringValue else {
            throw FlowParseError("Variable is missing \"name\"")
        }
        guard let typeRaw = json["type"].stringValue,
              let type = FunnelVariableType(rawValue: typeRaw) else {
            throw FlowParseError("Unknown variable type: \(json["type"].serializedString())")
        }
        self.name = name
        self.type = type
        self.defaultValue = json["default"]
        self.sensitive = json["sensitive"].boolValue == true
    }
}

// MARK: - Theme tokens

public enum FunnelShadowStyle: String, Sendable {
    case none, soft, hard
}

public enum FunnelFontWeightScale: String, Sendable {
    case light, regular, medium, bold
}

public struct FunnelColorTokens: Sendable, Equatable {
    public let primary: String
    public let accent: String?
    public let background: String
    public let surface: String
    public let textPrimary: String
    public let textSecondary: String
    public let border: String?
    public let error: String?
    public let success: String?

    init(json: JSONValue) throws {
        guard let primary = json["primary"].stringValue,
              let background = json["background"].stringValue,
              let surface = json["surface"].stringValue,
              let textPrimary = json["text_primary"].stringValue,
              let textSecondary = json["text_secondary"].stringValue else {
            throw FlowParseError("Color tokens missing a required color")
        }
        self.primary = primary
        self.background = background
        self.surface = surface
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.accent = json["accent"].stringValue
        self.border = json["border"].stringValue
        self.error = json["error"].stringValue
        self.success = json["success"].stringValue
    }
}

public struct FunnelThemeTokens: Sendable, Equatable {
    public let colors: FunnelColorTokens
    public let fontFamily: String
    public let fontWeightScale: FunnelFontWeightScale
    public let cornerRadius: Double
    public let shadowStyle: FunnelShadowStyle
    /// Custom shadow overrides (schema ShapeTokens extras); optional.
    public let shadowBlur: Double?
    public let shadowOffsetY: Double?
    public let shadowColor: String?
    public let spacingUnit: Double

    init(json: JSONValue) throws {
        colors = try FunnelColorTokens(json: json["colors"])
        guard let family = json["typography"]["font_family"].stringValue else {
            throw FlowParseError("Typography tokens missing font_family")
        }
        fontFamily = family
        if let scaleRaw = json["typography"]["font_weight_scale"].stringValue {
            guard let scale = FunnelFontWeightScale(rawValue: scaleRaw) else {
                throw FlowParseError("Unknown font_weight_scale: \(scaleRaw)")
            }
            fontWeightScale = scale
        } else {
            fontWeightScale = .regular
        }
        guard let radius = json["shape"]["corner_radius"].doubleValue,
              let shadowRaw = json["shape"]["shadow_style"].stringValue,
              let shadow = FunnelShadowStyle(rawValue: shadowRaw) else {
            throw FlowParseError("Shape tokens missing corner_radius/shadow_style")
        }
        cornerRadius = radius
        shadowStyle = shadow
        shadowBlur = json["shape"]["shadow_blur"].doubleValue
        shadowOffsetY = json["shape"]["shadow_offset_y"].doubleValue
        shadowColor = json["shape"]["shadow_color"].stringValue
        guard let unit = json["spacing"]["unit"].doubleValue else {
            throw FlowParseError("Spacing tokens missing unit")
        }
        spacingUnit = unit
    }
}

public struct FunnelThemeData: Sendable, Equatable {
    public let tokens: FunnelThemeTokens
    public let darkModeVariant: FunnelThemeTokens?

    static func fromJSONOrNil(_ json: JSONValue) throws -> FunnelThemeData? {
        guard json.objectValue != nil else { return nil }
        return FunnelThemeData(
            tokens: try FunnelThemeTokens(json: json["tokens"]),
            darkModeVariant: json["dark_mode_variant"].objectValue != nil
                ? try FunnelThemeTokens(json: json["dark_mode_variant"])
                : nil
        )
    }
}

// MARK: - Screen

/// A screen in a flow. Every screen the SDK receives is a primitive-tree
/// screen — the server lowers archetypes into `root` before serving.
public struct FunnelScreen: Sendable {
    public let id: String
    public let transitions: [FunnelTransition]

    /// Raw archetype string as authored — advisory metadata only, never a
    /// dispatch key. Empty when the screen didn't declare one.
    public let archetypeRaw: String

    /// The screen's primitive node tree, still raw JSON. Handed to
    /// `PrimNode(json:)` by the render layer. `.object([:])` when a screen is
    /// missing one (rendered as a neutral placeholder rather than throwing).
    public let root: JSONValue

    /// Raw `top_bar` / `background` / `style` maps, read by the primitive
    /// renderer directly.
    public let topBarRaw: JSONValue
    public let backgroundRaw: JSONValue
    public let styleRaw: JSONValue

    public init(json: JSONValue) throws {
        guard let id = json["id"].stringValue else {
            throw FlowParseError("Screen is missing \"id\"")
        }
        self.id = id
        self.transitions = try (json["transitions"].arrayValue ?? [])
            .map { try FunnelTransition(json: $0) }
        self.archetypeRaw = json["archetype"].stringValue ?? ""
        self.root = json["root"].objectValue != nil ? json["root"] : .object([:])
        // Schema names the field "top_bar"; accept "topBar" too for symmetry
        // with what the dashboard's draft serializer sometimes emits.
        let topBar = json["top_bar"].objectValue != nil ? json["top_bar"] : json["topBar"]
        self.topBarRaw = topBar.objectValue != nil ? topBar : .null
        self.backgroundRaw = json["background"].objectValue != nil ? json["background"] : .null
        self.styleRaw = json["style"].objectValue != nil ? json["style"] : .null
    }
}

// MARK: - Flow

public struct FunnelFlow: Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String?
    public let description: String?
    public let entryScreenId: String
    public let variables: [FunnelVariable]
    public let theme: FunnelThemeData?
    public let screens: [FunnelScreen]

    /// The full decoded flow JSON, kept verbatim. The render layer reads
    /// `theme` / `localizations` / `locales` / `default_locale` off this.
    public let raw: JSONValue

    public init(json: JSONValue) throws {
        guard let schemaVersion = json["schema_version"].intValue else {
            throw FlowParseError("Flow is missing schema_version")
        }
        guard let id = json["id"].stringValue else {
            throw FlowParseError("Flow is missing id")
        }
        guard let entry = json["entry_screen_id"].stringValue else {
            throw FlowParseError("Flow is missing entry_screen_id")
        }
        guard let screensJson = json["screens"].arrayValue else {
            throw FlowParseError("Flow is missing screens")
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = json["name"].stringValue
        self.description = json["description"].stringValue
        self.entryScreenId = entry
        self.variables = try (json["variables"].arrayValue ?? [])
            .map { try FunnelVariable(json: $0) }
        self.theme = try FunnelThemeData.fromJSONOrNil(json["theme"])
        self.screens = try screensJson.map { try FunnelScreen(json: $0) }
        self.raw = json
    }

    public static func parse(_ data: Data) throws -> FunnelFlow {
        try FunnelFlow(json: JSONValue.parse(data))
    }

    /// Look up a screen by id; `nil` when absent.
    public func screen(byId id: String) -> FunnelScreen? {
        screens.first { $0.id == id }
    }
}
