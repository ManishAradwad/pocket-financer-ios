import XCTest

@testable import PocketFinancer

final class CurrencyFormatterTests: XCTestCase {
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
