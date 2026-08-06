import XCTest

@testable import PocketFinancer

final class AlertSourceIdentityTests: XCTestCase {
    @MainActor
    func testSenderNormalizationAndExactBodySemantics() {
        let date = Date(timeIntervalSince1970: 1_000)
        let first = AlertSourceIdentity.fingerprint(
            sender: " ax-hdfcbk ",
            body: "Rs 500 debited",
            receivedAt: date,
            sourceApplication: "Messages"
        )
        let normalized = AlertSourceIdentity.fingerprint(
            sender: "AX-HDFCBK",
            body: "Rs 500 debited",
            receivedAt: date,
            sourceApplication: "Messages"
        )
        let changedBody = AlertSourceIdentity.fingerprint(
            sender: "AX-HDFCBK",
            body: "Rs 500 debited ",
            receivedAt: date,
            sourceApplication: "Messages"
        )

        XCTAssertEqual(first, normalized)
        XCTAssertNotEqual(first, changedBody)
        XCTAssertEqual(first.count, 64)
        XCTAssertFalse(AlertSourceIdentity.opaqueCandidateKey(sourceIdentity: first).contains("HDFC"))
    }
}
