import Foundation

// MARK: - Primitives

public enum Archetype: String, Codable, Sendable {
    case welcome
    case valueIntro = "value_intro"
    case singleChoice = "single_choice"
    case multiChoice = "multi_choice"
    case scale
    case slider
    case textInput = "text_input"
    case numericInput = "numeric_input"
    case datePicker = "date_picker"
    case gallery
    case loading
    case permission
    case notificationOptIn = "notification_opt_in"
    case socialProof = "social_proof"
    case commitment
    case personalizedSummary = "personalized_summary"
    case paywallHandoff = "paywall_handoff"
    case finale
    case custom
}

public enum ConditionOp: String, Codable, Sendable {
    case eq = "=="
    case neq = "!="
    case gt = ">"
    case lt = "<"
    case gte = ">="
    case lte = "<="
    case contains
    case notContains = "not_contains"
    case isSet = "is_set"
    case isNotSet = "is_not_set"
}

public struct Condition: Codable, Sendable, Hashable {
    public let varName: String
    public let op: ConditionOp
    public let value: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case varName = "var"
        case op
        case value
    }
}

public struct Transition: Codable, Sendable, Hashable {
    public let condition: Condition?
    public let go: String

    private enum CodingKeys: String, CodingKey {
        case condition = "if"
        case go
    }

    public var isDefault: Bool { condition == nil }
    public var isTerminal: Bool { go.hasPrefix("end:") }
    public var terminalReason: String? { isTerminal ? String(go.dropFirst(4)) : nil }
}

public enum VariableType: String, Codable, Sendable {
    case string
    case number
    case boolean
    case arrayString = "array_string"
    case date
}

public struct Variable: Codable, Sendable, Hashable {
    public let name: String
    public let type: VariableType
    public let `default`: AnyCodable?
}

public struct FunnelAsset: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case image, lottie, video }
    public let kind: Kind
    public let url: String
    public let alt: String?
}

// MARK: - Theme (minimal; v1 ships defaults if absent)

public struct ColorTokens: Codable, Sendable, Hashable {
    public let primary: String
    public let accent: String?
    public let background: String
    public let surface: String
    public let textPrimary: String
    public let textSecondary: String
    public let border: String?
    public let error: String?
    public let success: String?

    private enum CodingKeys: String, CodingKey {
        case primary, accent, background, surface
        case textPrimary = "text_primary"
        case textSecondary = "text_secondary"
        case border, error, success
    }
}

public struct ThemeTokens: Codable, Sendable, Hashable {
    public let colors: ColorTokens
    // We accept additional keys (typography/shape/spacing) but don't model
    // them yet — the SwiftUI views fall back to system defaults.
}

public struct Theme: Codable, Sendable, Hashable {
    public let tokens: ThemeTokens
}

// MARK: - Screen content (per-archetype, minimal v1 = 4 archetypes)

public struct WelcomeContent: Codable, Sendable, Hashable {
    public let title: String
    public let subtitle: String?
    public let ctaLabel: String
    public let hero: FunnelAsset?

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, hero
        case ctaLabel = "cta_label"
    }
}

public struct ChoiceOption: Codable, Sendable, Hashable {
    public let value: String
    public let label: String
    public let emoji: String?
}

public struct SingleChoiceContent: Codable, Sendable, Hashable {
    public let question: String
    public let subtitle: String?
    public let options: [ChoiceOption]
    public let saveTo: String
    public let autoAdvance: Bool?

    private enum CodingKeys: String, CodingKey {
        case question, subtitle, options
        case saveTo = "save_to"
        case autoAdvance = "auto_advance"
    }
}

public struct ScaleContent: Codable, Sendable, Hashable {
    public let question: String
    public let subtitle: String?
    public let min: Int
    public let max: Int
    public let minLabel: String?
    public let maxLabel: String?
    public let saveTo: String

    private enum CodingKeys: String, CodingKey {
        case question, subtitle, min, max
        case minLabel = "min_label"
        case maxLabel = "max_label"
        case saveTo = "save_to"
    }
}

public struct FinaleContent: Codable, Sendable, Hashable {
    public let title: String
    public let subtitle: String?
    public let ctaLabel: String
    public let fireEvent: String?

    private enum CodingKeys: String, CodingKey {
        case title, subtitle
        case ctaLabel = "cta_label"
        case fireEvent = "fire_event"
    }
}

// MARK: - Screen sealed-union

public enum FunnelScreen: Sendable, Hashable {
    case welcome(id: String, content: WelcomeContent, transitions: [Transition])
    case singleChoice(id: String, content: SingleChoiceContent, transitions: [Transition])
    case scale(id: String, content: ScaleContent, transitions: [Transition])
    case finale(id: String, content: FinaleContent, transitions: [Transition])
    /// Any archetype the v1 iOS SDK doesn't render yet. Carries the raw JSON
    /// so the host app can fall through to a custom view if it wants.
    case unsupported(id: String, archetype: Archetype, raw: AnyCodable, transitions: [Transition])

    public var id: String {
        switch self {
        case .welcome(let id, _, _),
             .singleChoice(let id, _, _),
             .scale(let id, _, _),
             .finale(let id, _, _),
             .unsupported(let id, _, _, _):
            return id
        }
    }

    public var archetype: Archetype {
        switch self {
        case .welcome: return .welcome
        case .singleChoice: return .singleChoice
        case .scale: return .scale
        case .finale: return .finale
        case .unsupported(_, let a, _, _): return a
        }
    }

    public var transitions: [Transition] {
        switch self {
        case .welcome(_, _, let t),
             .singleChoice(_, _, let t),
             .scale(_, _, let t),
             .finale(_, _, let t),
             .unsupported(_, _, _, let t):
            return t
        }
    }
}

extension FunnelScreen: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, archetype, content, transitions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let archetype = try c.decode(Archetype.self, forKey: .archetype)
        let transitions = (try? c.decode([Transition].self, forKey: .transitions)) ?? []

        switch archetype {
        case .welcome:
            let content = try c.decode(WelcomeContent.self, forKey: .content)
            self = .welcome(id: id, content: content, transitions: transitions)
        case .singleChoice:
            let content = try c.decode(SingleChoiceContent.self, forKey: .content)
            self = .singleChoice(id: id, content: content, transitions: transitions)
        case .scale:
            let content = try c.decode(ScaleContent.self, forKey: .content)
            self = .scale(id: id, content: content, transitions: transitions)
        case .finale:
            let content = try c.decode(FinaleContent.self, forKey: .content)
            self = .finale(id: id, content: content, transitions: transitions)
        default:
            let raw = try c.decode(AnyCodable.self, forKey: .content)
            self = .unsupported(id: id, archetype: archetype, raw: raw, transitions: transitions)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(archetype, forKey: .archetype)
        try c.encode(transitions, forKey: .transitions)
        switch self {
        case .welcome(_, let content, _): try c.encode(content, forKey: .content)
        case .singleChoice(_, let content, _): try c.encode(content, forKey: .content)
        case .scale(_, let content, _): try c.encode(content, forKey: .content)
        case .finale(_, let content, _): try c.encode(content, forKey: .content)
        case .unsupported(_, _, let raw, _): try c.encode(raw, forKey: .content)
        }
    }
}

// MARK: - Top-level Flow

public struct Flow: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let id: String
    public let name: String?
    public let entryScreenId: String
    public let variables: [Variable]
    public let theme: Theme?
    public let screens: [FunnelScreen]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, name
        case entryScreenId = "entry_screen_id"
        case variables, theme, screens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.entryScreenId = try c.decode(String.self, forKey: .entryScreenId)
        self.variables = (try? c.decode([Variable].self, forKey: .variables)) ?? []
        self.theme = try c.decodeIfPresent(Theme.self, forKey: .theme)
        self.screens = try c.decode([FunnelScreen].self, forKey: .screens)
    }

    public func screen(byId id: String) -> FunnelScreen? {
        screens.first { $0.id == id }
    }

    public static func decode(from data: Data) throws -> Flow {
        let decoder = JSONDecoder()
        return try decoder.decode(Flow.self, from: data)
    }

    public static func decode(fromJSONString json: String) throws -> Flow {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "FunnelOnboarding", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode JSON string as UTF-8"
            ])
        }
        return try decode(from: data)
    }
}

// MARK: - AnyCodable shim (for params/values that can be any JSON type)

public struct AnyCodable: Codable, Sendable, Hashable {
    public let value: AnyHashable

    public init(_ value: AnyHashable) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = AnyHashable("")
        } else if let b = try? c.decode(Bool.self) {
            self.value = AnyHashable(b)
        } else if let i = try? c.decode(Int.self) {
            self.value = AnyHashable(i)
        } else if let d = try? c.decode(Double.self) {
            self.value = AnyHashable(d)
        } else if let s = try? c.decode(String.self) {
            self.value = AnyHashable(s)
        } else if let arr = try? c.decode([AnyCodable].self) {
            self.value = AnyHashable(arr.map { $0.value })
        } else if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = AnyHashable(dict.mapValues { $0.value })
        } else {
            self.value = AnyHashable("")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value.base {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [AnyHashable]: try c.encode(v.map { AnyCodable($0) })
        case let v as [String: AnyHashable]: try c.encode(v.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}
