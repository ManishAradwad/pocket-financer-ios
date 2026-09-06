import SwiftData
import XCTest

@testable import PocketFinancer

final class SmsProcessingStoreTests: XCTestCase {
    @MainActor
    func testOperationClaimTraceReviewAndFeedbackAreDurableAndIdempotent() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = InboxAlert(
            sourceIdentity: "synthetic-source",
            contentDigest: "synthetic-digest",
            origin: .manual,
            sourceApplication: "Messages",
            sender: "SYNTH",
            rawBody: "INR 10 was paid from account **1234.",
            receivedAt: TestFixtures.receivedAt
        )
        context.insert(alert)
        try context.save()

        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: "manual",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            selectorModelIdentifier: "apple-system-language-model",
            selectorRuntimeVersion: "iOS 26",
            now: TestFixtures.receivedAt
        )
        XCTAssertEqual(snapshot.configuration.rolloutMode, "shadow")
        XCTAssertEqual(snapshot.configuration.generationMode, "DIRECT_NON_THINKING")

        let store = SmsProcessingStore(modelContainer: database.container)
        let claim = try await store.claim(
            operationID: snapshot.operationID,
            now: TestFixtures.receivedAt
        )
        let trace = try await store.appendTrace(
            claim,
            stage: "analysis",
            status: "completed",
            reasonCodes: ["amount_candidate_present"],
            now: TestFixtures.receivedAt
        )
        XCTAssertEqual(trace.sequence, 0)
        XCTAssertEqual(trace.eventHash.count, 64)

        let reviewID = try await store.retainForReview(
            claim,
            reasons: ["persistence_blocked_by_rollout_mode"],
            now: TestFixtures.receivedAt
        )
        let actionID = UUID()
        let command = ReviewCommand(
            actionID: actionID,
            reviewCaseID: reviewID,
            expectedRevision: 0,
            kind: .saveDraft,
            corrections: [],
            retryConfiguration: nil
        )
        let first = try await store.resolveReview(command, now: TestFixtures.receivedAt)
        let replay = try await store.resolveReview(command, now: TestFixtures.receivedAt)
        XCTAssertEqual(first.resultingRevision, 1)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(replay.replayed)

        let verificationContext = ModelContext(database.container)
        let operations = try verificationContext.fetch(FetchDescriptor<SmsProcessingOperation>())
        let reviews = try verificationContext.fetch(FetchDescriptor<SmsReviewCase>())
        let feedback = try verificationContext.fetch(FetchDescriptor<SmsUserFeedbackEvent>())
        XCTAssertEqual(operations.first?.state, .retainedReview)
        XCTAssertEqual(reviews.first?.state, .draft)
        XCTAssertEqual(feedback.count, 1)
    }

    @MainActor
    func testLegacyBackfillIsIdempotentAndPreservesExactStoredValues() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alertID = UUID()
        let transaction = Transaction(
            amountMinorUnits: 99,
            currencyCode: "JPY",
            merchant: "SYNTH STORE",
            occurredAt: TestFixtures.receivedAt,
            direction: .debit,
            accountID: nil,
            accountLabel: nil,
            isEdited: true,
            parserName: "Legacy",
            reviewState: .needsReview,
            sourceAlertID: alertID,
            amountEvidenceText: "JPY 99",
            dateEvidenceText: nil
        )
        context.insert(transaction)
        try context.save()

        let store = SmsProcessingStore(modelContainer: database.container)
        try await store.backfillLegacyTransactions(now: TestFixtures.receivedAt)
        try await store.backfillLegacyTransactions(now: TestFixtures.receivedAt)

        let verificationContext = ModelContext(database.container)
        let snapshots = try verificationContext.fetch(
            FetchDescriptor<SmsLegacyTransactionSnapshot>()
        )
        let revisions = try verificationContext.fetch(FetchDescriptor<SmsTransactionRevision>())
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.amountMinorUnits, 99)
        XCTAssertFalse(snapshots.first?.originalEditHistoryKnown ?? true)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.currencyScale, 0)
    }
}
