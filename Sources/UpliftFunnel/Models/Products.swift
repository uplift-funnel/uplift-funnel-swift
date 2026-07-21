import Foundation

// Runtime product catalog for paywall display, ported from the Flutter
// SDK's `products.dart`: what the host app knows about its store products
// (from RevenueCat, Adapty, StoreKit, ...) handed to the SDK via
// `UpliftFunnel.setProducts`.
//
// The SDK never talks to a store itself — prices stay store-truth carried
// by the host. Each product fans out into a `<field>.<productId>` variable
// namespace injected at session start, so flow text interpolates
// `{{price.yearly_pro}}` / `{{trial_days.yearly_pro}}` and `plan_picker`
// cards auto-bind their price display through the plan's `product_id`.

/// Subscription billing period of a store product.
public enum ProductPeriod: String, Sendable {
    case week, month, year, lifetime
}

/// One store product's display data, as known by the host's billing stack.
/// Only `id` and `price` are required — every other field just unlocks more
/// variables.
public struct UpliftFunnelProduct: Sendable {
    /// Store product identifier — must match the plan's `product_id`
    /// (or platform override) authored in the dashboard.
    public let id: String

    /// Localized price string exactly as the store formats it ("₺899,99").
    /// Injected as `price.<id>`.
    public let price: String

    /// Numeric price in the user's currency. Enables derived per-period
    /// prices (`price_per_month.<id>` for a yearly product) when the
    /// explicit overrides below are absent.
    public let priceAmount: Double?

    /// ISO 4217 code ("TRY", "USD"). Currently informational; derived-price
    /// formatting borrows the symbol from `price` instead.
    public let currencyCode: String?

    /// Billing period. Injected as `period.<id>` and decides which derived
    /// prices make sense.
    public let period: ProductPeriod?

    /// Free-trial length in days. Injected as `trial_days.<id>`.
    public let trialDays: Int?

    /// Whether THIS user can still take the intro/trial offer (per-user
    /// store check — only the host can know). Injected as
    /// `trial_eligible.<id>` (bool), usable by flow conditions.
    public let trialEligible: Bool?

    /// Pre-discount price string. Injected as `original_price.<id>`; the
    /// plan card's struck-through price auto-binds to it.
    public let originalPrice: String?

    /// Explicit "per month" price string — wins over the derived value.
    public let pricePerMonth: String?

    /// Explicit "per week" price string — wins over the derived value.
    public let pricePerWeek: String?

    public init(
        id: String,
        price: String,
        priceAmount: Double? = nil,
        currencyCode: String? = nil,
        period: ProductPeriod? = nil,
        trialDays: Int? = nil,
        trialEligible: Bool? = nil,
        originalPrice: String? = nil,
        pricePerMonth: String? = nil,
        pricePerWeek: String? = nil
    ) {
        self.id = id
        self.price = price
        self.priceAmount = priceAmount
        self.currencyCode = currencyCode
        self.period = period
        self.trialDays = trialDays
        self.trialEligible = trialEligible
        self.originalPrice = originalPrice
        self.pricePerMonth = pricePerMonth
        self.pricePerWeek = pricePerWeek
    }

    /// The `<field>.<id>` variables this product contributes at session
    /// start.
    func toVariables() -> [String: JSONValue] {
        var vars: [String: JSONValue] = ["price.\(id)": .string(price)]
        let perMonth = pricePerMonth ?? derived(divisor: 12, when: .year)
        let perWeek = pricePerWeek
            ?? derived(divisor: 52, when: .year)
            ?? derived(divisor: 4, when: .month)
        if let perMonth { vars["price_per_month.\(id)"] = .string(perMonth) }
        if let perWeek { vars["price_per_week.\(id)"] = .string(perWeek) }
        if let period { vars["period.\(id)"] = .string(period.rawValue) }
        if let trialDays { vars["trial_days.\(id)"] = .string("\(trialDays)") }
        if let trialEligible { vars["trial_eligible.\(id)"] = .bool(trialEligible) }
        if let originalPrice { vars["original_price.\(id)"] = .string(originalPrice) }
        return vars
    }

    /// Derived per-period price: divides `priceAmount` when this product's
    /// `period` matches `when`, reusing `price`'s currency symbol placement
    /// and decimal separator so "₺899,99" derives "₺75,00", not "TRY 75.00".
    /// Returns nil when the amount is missing or no digits are found in
    /// `price` — callers then omit the variable so authored copy shows
    /// instead of a wrongly-formatted guess.
    private func derived(divisor: Int, when: ProductPeriod) -> String? {
        guard let amount = priceAmount, period == when else { return nil }
        let pattern = "[0-9][0-9.,\u{00A0} ]*[0-9]|[0-9]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: price, range: NSRange(price.startIndex..., in: price)),
              let range = Range(match.range, in: price) else {
            return nil
        }
        let digits = String(price[range])
        let prefix = String(price[price.startIndex..<range.lowerBound])
        let suffix = String(price[range.upperBound...])
        // Decimal separator: whichever of ',' / '.' appears LAST in the
        // source number (the earlier one, if any, is grouping).
        let lastComma = digits.range(of: ",", options: .backwards)?.lowerBound
        let lastDot = digits.range(of: ".", options: .backwards)?.lowerBound
        let comma: Bool
        switch (lastComma, lastDot) {
        case (let c?, let d?): comma = c > d
        case (.some, nil): comma = true
        default: comma = false
        }
        var n = String(format: "%.2f", amount / Double(divisor))
        if comma { n = n.replacingOccurrences(of: ".", with: ",") }
        return prefix + n + suffix
    }
}

/// Builds the merged session-start variable map for `products`, keyed by
/// product id. Later entries win on duplicate ids.
func productVariables<S: Sequence>(_ products: S) -> [String: JSONValue]
where S.Element == UpliftFunnelProduct {
    var vars: [String: JSONValue] = [:]
    for p in products {
        vars.merge(p.toVariables()) { _, new in new }
    }
    return vars
}
