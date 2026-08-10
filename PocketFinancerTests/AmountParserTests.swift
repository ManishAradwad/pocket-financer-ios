import XCTest

@testable import PocketFinancer

final class AmountParserTests: XCTestCase {
    @MainActor
    func testParsesIndianAmountFormsIntoMinorUnits() throws {
        XCTAssertEqual(try AmountParser.minorUnits(from: "Rs.500", currencyCode: "INR"), 50_000)
        XCTAssertEqual(try AmountParser.minorUnits(from: "INR 2,500.00", currencyCode: "INR"), 250_000)
        XCTAssertEqual(try AmountParser.minorUnits(from: "₹12,50,000.50", currencyCode: "INR"), 125_000_050)
        XCTAssertEqual(try AmountParser.minorUnits(from: "500.5 INR", currencyCode: "INR"), 50_050)
    }

    @MainActor
    func testRejectsInvalidOrUnsafeAmounts() {
        XCTAssertThrowsError(try AmountParser.minorUnits(from: "INR 0", currencyCode: "INR"))
        XCTAssertThrowsError(try AmountParser.minorUnits(from: "INR 12.345", currencyCode: "INR"))
        XCTAssertThrowsError(try AmountParser.minorUnits(from: "NaN", currencyCode: "INR"))
        XCTAssertThrowsError(try AmountParser.minorUnits(from: "USD 5", currencyCode: "USD"))
    }
}
