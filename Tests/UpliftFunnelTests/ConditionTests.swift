import XCTest
@testable import UpliftFunnel

final class ConditionTests: XCTestCase {
    private func eval(
        _ op: FunnelConditionOp, value: JSONValue = .null,
        stored: JSONValue?
    ) throws -> Bool {
        let c = FunnelCondition(varName: "v", op: op, value: value)
        return try evaluateCondition(c) { _ in stored }
    }

    func testIsSetAndIsNotSet() throws {
        XCTAssertTrue(try eval(.isSet, stored: "x"))
        XCTAssertFalse(try eval(.isSet, stored: nil))
        // JSON null counts as not set.
        XCTAssertFalse(try eval(.isSet, stored: .null))
        XCTAssertTrue(try eval(.isNotSet, stored: nil))
        XCTAssertFalse(try eval(.isNotSet, stored: "x"))
    }

    func testLooseEquality() throws {
        XCTAssertTrue(try eval(.eq, value: "lose", stored: "lose"))
        XCTAssertFalse(try eval(.eq, value: "lose", stored: "gain"))
        // Numbers compare numerically.
        XCTAssertTrue(try eval(.eq, value: 5, stored: 5.0))
        // Number vs numeric string compares via string form (Dart parity).
        XCTAssertTrue(try eval(.eq, value: "5", stored: 5))
        XCTAssertTrue(try eval(.eq, value: 5, stored: "5"))
        XCTAssertFalse(try eval(.eq, value: 5, stored: "5.5"))
        // Bool vs its string form.
        XCTAssertTrue(try eval(.eq, value: "true", stored: true))
        // Missing vs null operand.
        XCTAssertTrue(try eval(.eq, value: .null, stored: nil))
        XCTAssertFalse(try eval(.eq, value: "x", stored: nil))
        XCTAssertTrue(try eval(.neq, value: "x", stored: nil))
    }

    func testNumericComparisons() throws {
        XCTAssertTrue(try eval(.gt, value: 10, stored: 11))
        XCTAssertFalse(try eval(.gt, value: 10, stored: 10))
        XCTAssertTrue(try eval(.gte, value: 10, stored: 10))
        XCTAssertTrue(try eval(.lt, value: 10, stored: 9))
        XCTAssertTrue(try eval(.lte, value: 10, stored: 10))
        // Numeric strings parse.
        XCTAssertTrue(try eval(.gt, value: "10", stored: "11"))
    }

    func testNumericComparisonThrowsOnNonNumeric() {
        XCTAssertThrowsError(try eval(.gt, value: 10, stored: "abc"))
        XCTAssertThrowsError(try eval(.gt, value: 10, stored: nil))
    }

    func testContains() throws {
        XCTAssertTrue(try eval(.contains, value: "a", stored: ["a", "b"]))
        XCTAssertFalse(try eval(.contains, value: "c", stored: ["a", "b"]))
        // Substring on strings.
        XCTAssertTrue(try eval(.contains, value: "ell", stored: "hello"))
        XCTAssertFalse(try eval(.contains, value: "z", stored: "hello"))
        // Type-strict list membership (Dart List.contains parity).
        XCTAssertFalse(try eval(.contains, value: "1", stored: [1, 2]))
        XCTAssertTrue(try eval(.contains, value: 1, stored: [1, 2]))
        XCTAssertTrue(try eval(.notContains, value: "c", stored: ["a", "b"]))
        // Non-container haystack contains nothing.
        XCTAssertFalse(try eval(.contains, value: "a", stored: 42))
    }

    func testConditionParsing() throws {
        let ok = try FunnelCondition(json: try JSONValue.parse(
            #"{"var": "goal", "op": "==", "value": "lose"}"#))
        XCTAssertEqual(ok.varName, "goal")
        XCTAssertEqual(ok.op, .eq)
        XCTAssertEqual(ok.value, "lose")

        XCTAssertThrowsError(try FunnelCondition(json: try JSONValue.parse(
            #"{"var": "goal", "op": "~~", "value": 1}"#)))
        XCTAssertThrowsError(try FunnelCondition(json: try JSONValue.parse(
            #"{"op": "==", "value": 1}"#)))
    }
}
