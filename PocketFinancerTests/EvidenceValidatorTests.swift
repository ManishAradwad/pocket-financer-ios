import XCTest

@testable import PocketFinancer

final class EvidenceValidatorTests: XCTestCase {
    @MainActor
    func testAcceptsGroundedDebit() throws {
        let report = EvidenceValidator().report(
            TestFixtures.validDraft,
            body: TestFixtures.validBody,
            receivedAt: TestFixtures.receivedAt
        )
        let value = try report.result.get()
        XCTAssertEqual(value.amountMinorUnits, 50_000)
        XCTAssertEqual(value.direction, .debit)
        XCTAssertEqual(value.merchant, "Demo Store")
        XCTAssertEqual(value.reviewState, .confirmed)
        XCTAssertNil(report.issue)
        XCTAssertEqual(
            report.stages,
            EvidenceValidationStage.allCases.map { .init(stage: $0, state: .passed) }
        )
    }

    @MainActor
    func testTreatsRefundAndReversalAsGroundedCredits() throws {
        let body = "Rs.250.00 refunded to a/c XX1234 on 05-08-2026 by Demo Store"
        let draft = ParsedAlertDraft(
            classification: .transaction,
            direction: "credit",
            amountText: "Rs.250.00",
            merchant: "Demo Store",
            accountLabel: "a/c XX1234",
            occurredAtText: "05-08-2026",
            currencyCode: "INR"
        )
        XCTAssertEqual(try EvidenceValidator().validate(draft, body: body, receivedAt: .now).get().direction, .credit)
    }

    @MainActor
    func testRejectsHallucinatedAmountMerchantAndDate() {
        var draft = TestFixtures.validDraft
        draft = ParsedAlertDraft(
            classification: draft.classification,
            direction: draft.direction,
            amountText: "Rs.900.00",
            merchant: draft.merchant,
            accountLabel: draft.accountLabel,
            occurredAtText: draft.occurredAtText,
            currencyCode: draft.currencyCode
        )
        XCTAssertEqual(
            EvidenceValidator().validate(draft, body: TestFixtures.validBody, receivedAt: .now),
            .failure(.amountNotGrounded)
        )

        let merchantDraft = ParsedAlertDraft(
            classification: .transaction,
            direction: "debit",
            amountText: "Rs.500.00",
            merchant: "Invented Merchant",
            accountLabel: "a/c XXXXXX0000",
            occurredAtText: "05-08-2026",
            currencyCode: "INR"
        )
        XCTAssertEqual(
            EvidenceValidator().validate(merchantDraft, body: TestFixtures.validBody, receivedAt: .now),
            .failure(.merchantNotGrounded)
        )

        let dateDraft = ParsedAlertDraft(
            classification: .transaction,
            direction: "debit",
            amountText: "Rs.500.00",
            merchant: "Demo Store",
            accountLabel: "a/c XXXXXX0000",
            occurredAtText: "01-01-2030",
            currencyCode: "INR"
        )
        XCTAssertEqual(
            EvidenceValidator().validate(dateDraft, body: TestFixtures.validBody, receivedAt: .now),
            .failure(.dateNotGrounded)
        )
    }

    @MainActor
    func testTraceStopsAtFirstUnsafeFieldAndMarksRemainingStagesNotRun() {
        let draft = ParsedAlertDraft(
            classification: .transaction,
            direction: "debit",
            amountText: "Rs.500.00",
            merchant: "Invented Merchant",
            accountLabel: "a/c XXXXXX0000",
            occurredAtText: "05-08-2026",
            currencyCode: "INR"
        )

        let report = EvidenceValidator().report(
            draft,
            body: TestFixtures.validBody,
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertEqual(report.issue, .merchantNotGrounded)
        XCTAssertEqual(
            report.stages,
            [
                .init(stage: .classification, state: .passed),
                .init(stage: .direction, state: .passed),
                .init(stage: .amount, state: .passed),
                .init(stage: .merchant, state: .failed),
                .init(stage: .account, state: .notRun),
                .init(stage: .date, state: .notRun),
            ]
        )
    }

    @MainActor
    func testMissingOptionalEvidenceRequiresReviewRatherThanInventingIt() throws {
        let value = try EvidenceValidator().validate(
            TestFixtures.reviewDraft,
            body: TestFixtures.validBody,
            receivedAt: TestFixtures.receivedAt
        ).get()
        XCTAssertEqual(value.merchant, "Unknown Merchant")
        XCTAssertEqual(value.occurredAt, TestFixtures.receivedAt)
        XCTAssertEqual(value.reviewState, .needsReview)
    }

    @MainActor
    func testRejectsModelClassificationAndInvalidDirection() {
        let nonTransaction = ParsedAlertDraft(
            classification: .nonTransaction,
            direction: "",
            amountText: "",
            merchant: "",
            accountLabel: "",
            occurredAtText: "",
            currencyCode: "INR"
        )
        XCTAssertEqual(
            EvidenceValidator().validate(nonTransaction, body: TestFixtures.validBody, receivedAt: .now),
            .failure(.modelRejected)
        )

        let invalidDirection = ParsedAlertDraft(
            classification: .transaction,
            direction: "transfer",
            amountText: TestFixtures.validDraft.amountText,
            merchant: TestFixtures.validDraft.merchant,
            accountLabel: TestFixtures.validDraft.accountLabel,
            occurredAtText: TestFixtures.validDraft.occurredAtText,
            currencyCode: "INR"
        )
        XCTAssertEqual(
            EvidenceValidator().validate(invalidDirection, body: TestFixtures.validBody, receivedAt: .now),
            .failure(.invalidDirection)
        )
    }

    @MainActor
    func testRejectsUngroundedDirectionAndAccount() {
        let wrongDirection = ParsedAlertDraft(
            classification: .transaction,
            direction: "credit",
            amountText: TestFixtures.validDraft.amountText,
            merchant: TestFixtures.validDraft.merchant,
            accountLabel: TestFixtures.validDraft.accountLabel,
            occurredAtText: TestFixtures.validDraft.occurredAtText,
            currencyCode: "INR"
        )
        XCTAssertEqual(
            EvidenceValidator().validate(wrongDirection, body: TestFixtures.validBody, receivedAt: .now),
            .failure(.directionNotGrounded)
        )

        let inventedAccount = ParsedAlertDraft(
            classification: .transaction,
            direction: TestFixtures.validDraft.direction,
            amountText: TestFixtures.validDraft.amountText,
            merchant: TestFixtures.validDraft.merchant,
            accountLabel: "a/c XXXXXX9999",
            occurredAtText: TestFixtures.validDraft.occurredAtText,
            currencyCode: "INR"
        )
        XCTAssertEqual(
            EvidenceValidator().validate(inventedAccount, body: TestFixtures.validBody, receivedAt: .now),
            .failure(.accountNotGrounded)
        )
    }

    @MainActor
    func testRejectsInvalidGroundedAmountAndDate() {
        let zeroBody = "HDFC Bank: Rs.0.00 debited from a/c XX0000 on 05-08-2026."
        let zeroDraft = ParsedAlertDraft(
            classification: .transaction,
            direction: "debit",
            amountText: "Rs.0.00",
            merchant: "",
            accountLabel: "a/c XX0000",
            occurredAtText: "05-08-2026",
            currencyCode: "INR"
        )
        XCTAssertEqual(
            EvidenceValidator().validate(zeroDraft, body: zeroBody, receivedAt: .now),
            .failure(.invalidAmount)
        )

        let invalidDateBody = "HDFC Bank: Rs.1.00 debited from a/c XX0000 on 32-13-2026."
        let invalidDateDraft = ParsedAlertDraft(
            classification: .transaction,
            direction: "debit",
            amountText: "Rs.1.00",
            merchant: "",
            accountLabel: "a/c XX0000",
            occurredAtText: "32-13-2026",
            currencyCode: "INR"
        )
        XCTAssertEqual(
            EvidenceValidator().validate(invalidDateDraft, body: invalidDateBody, receivedAt: .now),
            .failure(.invalidDate)
        )
    }
}
