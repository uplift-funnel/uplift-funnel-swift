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
}
