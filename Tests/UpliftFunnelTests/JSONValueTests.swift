import XCTest
@testable import UpliftFunnel

final class JSONValueTests: XCTestCase {
    func testParsesArbitraryJSON() throws {
        let json = """
        {"a": 1, "b": "two", "c": true, "d": null, "e": [1, "x"], "f": {"g": 2.5}}
        """
        let v = try JSONValue.parse(json)
        XCTAssertEqual(v["a"].intValue, 1)
        XCTAssertEqual(v["b"].stringValue, "two")
        XCTAssertEqual(v["c"].boolValue, true)
        XCTAssertTrue(v["d"].isNull)
        XCTAssertTrue(v["missing"].isNull)
        XCTAssertEqual(v["e"][1].stringValue, "x")
        XCTAssertEqual(v["e"][9].stringValue, nil)
        XCTAssertEqual(v["f"]["g"].doubleValue, 2.5)
    }

    func testNumAwareAccessors() {
        XCTAssertEqual(JSONValue.string("42").doubleValue, 42)
        XCTAssertEqual(JSONValue.string(" 3.5 ").doubleValue, 3.5)
        XCTAssertEqual(JSONValue.string("abc").doubleValue, nil)
        XCTAssertEqual(JSONValue.number(7).intValue, 7)
        XCTAssertEqual(JSONValue.number(7.5).intValue, nil)
        XCTAssertEqual(JSONValue.number(7).stringifiedValue, "7")
        XCTAssertEqual(JSONValue.number(7.5).stringifiedValue, "7.5")
        XCTAssertEqual(JSONValue.bool(true).stringifiedValue, "true")
    }

    func testEncodesWholeNumbersWithoutFraction() throws {
        let v: JSONValue = ["ts": 1721400000000, "ratio": 0.5]
        let s = v.serializedString()
        XCTAssertTrue(s.contains("1721400000000"))
        XCTAssertFalse(s.contains("1721400000000.0"))
        XCTAssertTrue(s.contains("0.5"))
    }

    func testRoundTripsThroughFoundation() {
        let v = JSONValue(any: ["k": [1, true, "s", nil] as [Any?]])
        XCTAssertEqual(v["k"][0].intValue, 1)
        XCTAssertEqual(v["k"][1].boolValue, true)
        XCTAssertEqual(v["k"][2].stringValue, "s")
        XCTAssertTrue(v["k"][3].isNull)
    }

    func testBoolNotConfusedWithNumber() throws {
        let v = try JSONValue.parse(#"{"b": true, "n": 1}"#)
        XCTAssertEqual(v["b"].boolValue, true)
        XCTAssertNil(v["b"].doubleValue)
        XCTAssertNil(v["n"].boolValue)
        XCTAssertEqual(v["n"].doubleValue, 1)
    }

    func testFixturesParse() throws {
        for name in ["primitive-catalog", "primitive-slice"] {
            let url = try XCTUnwrap(Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures"))
            let v = try JSONValue.parse(try Data(contentsOf: url))
            XCTAssertEqual(v["schema_version"].intValue, 1)
            XCTAssertFalse(v["screens"].arrayValue?.isEmpty ?? true)
        }
    }
}
