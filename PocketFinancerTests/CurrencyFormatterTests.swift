import XCTest

@testable import PocketFinancer

final class CurrencyFormatterTests: XCTestCase {
    @MainActor
    func testINRFormattingKeepsIndianDigitGrouping() {
        let formatted = CurrencyFormatter.string(
            minorUnits: Int64(12_345_678),
            currencyCode: "INR"
        )

        XCTAssertTrue(formatted.contains("1,23,456.78"))
    }

    @MainActor
    func testFormatsAggregateBeyondInt64WithoutOverflow() {
        let aggregateMinorUnits = Decimal(Int64.max) + Decimal(Int64.max)

        let formatted = CurrencyFormatter.string(
            minorUnits: aggregateMinorUnits,
            currencyCode: "INR"
        )

        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(formatted.contains("₹") || formatted.contains("INR"))
    }
}
