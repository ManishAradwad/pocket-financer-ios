import Foundation
import XCTest

@testable import PocketFinancer

final class AlertDateParserTests: XCTestCase {
    @MainActor
    func testMissingEvidenceUsesReceivedDate() {
        XCTAssertEqual(AlertDateParser.date(from: "", receivedAt: TestFixtures.receivedAt), TestFixtures.receivedAt)
    }

    @MainActor
    func testParsesSupportedIndianDateFormats() throws {
        let calendar = Calendar(identifier: .gregorian)
        for evidence in ["05-08-2026", "05/08/2026", "05-08-26", "05/08/26"] {
            let date = try XCTUnwrap(
                AlertDateParser.date(from: evidence, receivedAt: TestFixtures.receivedAt), evidence)
            let components = calendar.dateComponents(in: .current, from: date)
            XCTAssertEqual(components.day, 5, evidence)
            XCTAssertEqual(components.month, 8, evidence)
            XCTAssertEqual(components.year, 2026, evidence)
        }
    }

    @MainActor
    func testRejectsImpossibleDate() {
        XCTAssertNil(AlertDateParser.date(from: "32-13-2026", receivedAt: TestFixtures.receivedAt))
    }
}
