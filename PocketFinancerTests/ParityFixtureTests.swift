import Foundation
import XCTest

@testable import PocketFinancer

final class ParityFixtureTests: XCTestCase {
    @MainActor
    func testCheckedInParityFixtureExecutesPinnedAndroidSemantics() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "transaction_parity_v1", withExtension: "json")
        )
        let document = try JSONDecoder().decode(ParityDocument.self, from: Data(contentsOf: url))

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.androidCommit, "a9b7df44be2183daac3a05cadbfd40b8f309cd4b")
        XCTAssertGreaterThanOrEqual(document.cases.count, 4)

        for fixture in document.cases {
            let filterResult = AlertFilter().evaluate(sender: fixture.sender, body: fixture.body)
            XCTAssertEqual(filterResult.isEligible, fixture.prefilterAccepted, fixture.id)
            XCTAssertEqual(filterResult.rejectionCode?.rawValue, fixture.rejectionCode, fixture.id)

            guard fixture.prefilterAccepted else { continue }
            let amountText = try XCTUnwrap(fixture.amountText, fixture.id)
            let currency = try XCTUnwrap(fixture.currency, fixture.id)
            XCTAssertEqual(
                try AmountParser.minorUnits(from: amountText, currencyCode: currency),
                fixture.amountMinorUnits,
                fixture.id
            )

            let draft = ParsedAlertDraft(
                classification: .transaction,
                direction: try XCTUnwrap(fixture.direction, fixture.id),
                amountText: amountText,
                merchant: fixture.merchantText ?? "",
                accountLabel: try XCTUnwrap(fixture.accountText, fixture.id),
                occurredAtText: fixture.dateText ?? "",
                currencyCode: currency
            )
            let validated = try EvidenceValidator().validate(
                draft,
                body: fixture.body,
                receivedAt: TestFixtures.receivedAt
            ).get()
            XCTAssertEqual(validated.amountMinorUnits, fixture.amountMinorUnits, fixture.id)
            XCTAssertEqual(validated.direction.rawValue, fixture.direction, fixture.id)
        }
    }
}

private struct ParityDocument: Decodable {
    let schemaVersion: Int
    let androidCommit: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let id: String
    let sender: String
    let body: String
    let prefilterAccepted: Bool
    let rejectionCode: String?
    let direction: String?
    let amountText: String?
    let amountMinorUnits: Int64?
    let currency: String?
    let merchantText: String?
    let accountText: String?
    let dateText: String?
}
