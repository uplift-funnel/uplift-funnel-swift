import XCTest
@testable import UpliftFunnel

final class ProductsTests: XCTestCase {
    func testBasicPriceVariable() {
        let vars = UpliftFunnelProduct(id: "yearly_pro", price: "₺899,99").toVariables()
        XCTAssertEqual(vars["price.yearly_pro"], "₺899,99")
        XCTAssertNil(vars["price_per_month.yearly_pro"])
    }

    func testDerivedPerPeriodPricesKeepCommaDecimalAndSymbol() {
        let vars = UpliftFunnelProduct(
            id: "yearly", price: "₺899,99", priceAmount: 899.99,
            period: .year
        ).toVariables()
        // 899.99 / 12 = 75.00 — comma decimal + prefix symbol preserved.
        XCTAssertEqual(vars["price_per_month.yearly"], "₺75,00")
        // 899.99 / 52 = 17.31
        XCTAssertEqual(vars["price_per_week.yearly"], "₺17,31")
        XCTAssertEqual(vars["period.yearly"], "year")
    }

    func testDerivedDotDecimalWithSuffixSymbol() {
        let vars = UpliftFunnelProduct(
            id: "y", price: "99.99 USD", priceAmount: 99.99, period: .year
        ).toVariables()
        XCTAssertEqual(vars["price_per_month.y"], "8.33 USD")
    }

    func testMonthlyDerivesWeekOnly() {
        let vars = UpliftFunnelProduct(
            id: "m", price: "$9.99", priceAmount: 9.99, period: .month
        ).toVariables()
        XCTAssertNil(vars["price_per_month.m"], "no per-month derivation for monthly")
        XCTAssertEqual(vars["price_per_week.m"], "$2.50")
    }

    func testExplicitOverridesWinOverDerived() {
        let vars = UpliftFunnelProduct(
            id: "y", price: "$120", priceAmount: 120, period: .year,
            pricePerMonth: "$10/mo", pricePerWeek: "$2.50/wk"
        ).toVariables()
        XCTAssertEqual(vars["price_per_month.y"], "$10/mo")
        XCTAssertEqual(vars["price_per_week.y"], "$2.50/wk")
    }

    func testTrialAndOriginalPriceVariables() {
        let vars = UpliftFunnelProduct(
            id: "p", price: "$1", trialDays: 7, trialEligible: true,
            originalPrice: "$2"
        ).toVariables()
        XCTAssertEqual(vars["trial_days.p"], "7")
        XCTAssertEqual(vars["trial_eligible.p"], true)
        XCTAssertEqual(vars["original_price.p"], "$2")
    }

    func testNoDigitsInPriceSkipsDerivation() {
        let vars = UpliftFunnelProduct(
            id: "p", price: "Free", priceAmount: 100, period: .year
        ).toVariables()
        XCTAssertNil(vars["price_per_month.p"])
    }

    func testProductVariablesMergesLaterWins() {
        let vars = productVariables([
            UpliftFunnelProduct(id: "a", price: "$1"),
            UpliftFunnelProduct(id: "a", price: "$2"),
            UpliftFunnelProduct(id: "b", price: "$3"),
        ])
        XCTAssertEqual(vars["price.a"], "$2")
        XCTAssertEqual(vars["price.b"], "$3")
    }

    // MARK: - the scope a plan card reads

    /// The `{{product.*}}` namespace, which is a DIFFERENT map from the flat
    /// `<field>.<id>` variables above. Both exist because a plan card composed
    /// of ordinary boxes has no way to name its own product: the binding is on
    /// the box and the text inside it just says `{{product.price}}`.
    func testScopedStringsCoverEveryTokenTheDecoderPublishes() {
        let scope = UpliftFunnelProduct(
            id: "yearly", price: "$59.99", priceAmount: 59.99, period: .year,
            trialDays: 7, originalPrice: "$89.99"
        ).toScopedStrings()
        XCTAssertEqual(scope["price"], "$59.99")
        XCTAssertEqual(scope["period"], "year")
        XCTAssertEqual(scope["trial"], "7-day")
        XCTAssertEqual(scope["original_price"], "$89.99")
        XCTAssertEqual(scope["savings"], "Save 33%")
    }

    /// Every key is present even when the product carries nothing for it, so
    /// the token resolves to an empty string rather than falling through to the
    /// literal braces. A card with no trial draws no trial; it does not draw
    /// `{{product.trial}}`.
    func testAThinProductStillFillsEveryKey() {
        let scope = UpliftFunnelProduct(id: "basic", price: "$1").toScopedStrings()
        XCTAssertEqual(scope["price"], "$1")
        for key in ["period", "trial", "original_price", "savings"] {
            XCTAssertEqual(scope[key], "", "\(key) should be present and empty")
        }
    }

    /// Only the host can localize a savings phrase, so an explicit one wins.
    func testAnExplicitSavingsPhraseWinsOverTheDerivedOne() {
        let scope = UpliftFunnelProduct(
            id: "yearly", price: "₺600,00", priceAmount: 600, originalPrice: "₺1.200,00",
            savings: "%50 tasarruf"
        ).toScopedStrings()
        XCTAssertEqual(scope["savings"], "%50 tasarruf")
    }

    func testSavingsIsDerivedThroughACommaDecimal() {
        let scope = UpliftFunnelProduct(
            id: "yearly", price: "₺600,00", priceAmount: 600, originalPrice: "₺1.200,00"
        ).toScopedStrings()
        XCTAssertEqual(scope["savings"], "Save 50%")
    }

    func testNoSavingsWhenTheDiscountIsNotReal() {
        // Original missing, original unparseable, and a "discount" that is not
        // one — none of which should invent a badge.
        XCTAssertEqual(
            UpliftFunnelProduct(id: "a", price: "$5", priceAmount: 5).toScopedStrings()["savings"], "")
        XCTAssertEqual(
            UpliftFunnelProduct(id: "a", price: "$5", priceAmount: 5, originalPrice: "free")
                .toScopedStrings()["savings"], "")
        XCTAssertEqual(
            UpliftFunnelProduct(id: "a", price: "$5", priceAmount: 5, originalPrice: "$4")
                .toScopedStrings()["savings"], "")
    }

    /// The map the renderer is handed, keyed by the ref a `behavior.product`
    /// names. Nothing built this until now — the renderer's `products` property
    /// was declared, passed down, and never once assigned.
    func testProductScopeIsKeyedByRef() {
        let scope = productScope([
            "com.app.annual": UpliftFunnelProduct(id: "com.app.annual", price: "$59.99", period: .year)
        ])
        XCTAssertEqual(scope["com.app.annual"]?["price"], "$59.99")
        XCTAssertEqual(scope["com.app.annual"]?["period"], "year")
    }
}
