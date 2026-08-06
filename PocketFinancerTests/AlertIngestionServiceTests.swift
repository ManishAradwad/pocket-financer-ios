import SwiftData
import XCTest

@testable import PocketFinancer

final class AlertIngestionServiceTests: XCTestCase {
    @MainActor
    func testSuccessfulImportPersistsTransactionAccountAndRawEvidence() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.validDraft))
        )

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .imported)
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let alerts = try context.fetch(FetchDescriptor<InboxAlert>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.amountMinorUnits, 50_000)
        XCTAssertEqual(alerts.first?.rawBody, TestFixtures.validBody)
        XCTAssertEqual(alerts.first?.status, .imported)
        XCTAssertEqual(accounts.first?.name, "HDFC Bank A/c XX0000")
    }

    @MainActor
    func testAttemptIsDurableBeforeParsingAndPersistsExactDraftBeforeValidation() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let parser = InspectingTransactionParser {
            let runs = (try? context.fetch(FetchDescriptor<ExtractionRun>())) ?? []
            XCTAssertEqual(runs.count, 1)
            XCTAssertEqual(runs.first?.attemptIndex, 1)
            XCTAssertEqual(runs.first?.parserName, "Inspecting Test Parser")
            XCTAssertTrue(runs.first?.exactRequest.contains(TestFixtures.validBody) == true)
            XCTAssertNil(runs.first?.parserDraft)
            XCTAssertNil(runs.first?.completedAt)
            XCTAssertFalse(context.hasChanges)
        }
        let service = AlertIngestionService(context: context, parser: parser)

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "sender-format-is-metadata-only",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .imported)
        let run = try XCTUnwrap(context.fetch(FetchDescriptor<ExtractionRun>()).first)
        XCTAssertEqual(run.alertID, receipt.alertID)
        XCTAssertEqual(run.contractVersion, FoundationModelExtractionContract.contractVersion)
        XCTAssertEqual(run.profileVersion, FoundationModelExtractionContract.extractionProfileVersion)
        XCTAssertEqual(run.localeIdentifier, parser.requestMetadata.localeIdentifier)
        XCTAssertEqual(run.exactInstructions, FoundationModelExtractionContract.instructions)
        XCTAssertEqual(
            run.exactRequest,
            FoundationModelExtractionContract.requestPrompt(
                body: TestFixtures.validBody,
                receivedAt: TestFixtures.receivedAt
            )
        )
        XCTAssertEqual(run.parserDraft, TestFixtures.validDraft)
        XCTAssertNotNil(run.responseReceivedAt)
        XCTAssertNotNil(run.completedAt)
        XCTAssertEqual(run.validationOutcome, .passed)
        XCTAssertEqual(
            EvidenceValidationStage.allCases.map { run.validationState(for: $0) },
            Array(repeating: .passed, count: EvidenceValidationStage.allCases.count)
        )
        XCTAssertEqual(run.safeResultCode, "validation_passed")
        XCTAssertEqual(run.terminalDisposition, .imported)
        XCTAssertEqual(run.acceptedAmountMinorUnits, 50_000)
        XCTAssertEqual(run.acceptedCurrencyCode, "INR")
        XCTAssertEqual(run.acceptedDirection, .debit)
        XCTAssertEqual(run.acceptedMerchant, "Demo Store")
        XCTAssertEqual(run.acceptedAccountLabel, "HDFC Bank A/c XX0000")
        XCTAssertEqual(
            run.acceptedOccurredAt, try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first).occurredAt)
        XCTAssertEqual(run.acceptedReviewState, .confirmed)
        XCTAssertEqual(run.acceptedAmountEvidenceText, "Rs.500.00")
        XCTAssertEqual(run.acceptedDateEvidenceText, "05-08-2026")
        XCTAssertNotNil(run.parserDuration)
        XCTAssertNotNil(run.totalDuration)
    }

    @MainActor
    func testRejectedOTPErasesSensitiveEvidenceAndSkipsModel() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .failure(.generationFailed))
        )
        let body = "123456 is one-time password for Rs.120.00 spent on Card x5678"

        let receipt = try await service.ingest(
            body: body,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .rejected)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .rejected)
        XCTAssertEqual(alert.rejectionCode, AlertRejectionCode.oneTimePassword.rawValue)
        XCTAssertTrue(alert.rawBody.isEmpty)
        XCTAssertTrue(alert.sender.isEmpty)
        XCTAssertTrue(alert.normalizedSender.isEmpty)
        XCTAssertNil(alert.sourceApplication)
        XCTAssertEqual(alert.sourceIdentity, "erased:\(alert.id.uuidString.lowercased())")
        XCTAssertEqual(alert.contentDigest, alert.sourceIdentity)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)
    }

    @MainActor
    func testDuplicateWithinOverlapWindowKeepsMetadataWithoutSecondTransaction() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.validDraft))
        )

        _ = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let duplicateReceipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: " ax-hdfcbk ",
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(10),
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(duplicateReceipt.disposition, .duplicate)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 1)
        let alerts = try context.fetch(FetchDescriptor<InboxAlert>())
        XCTAssertEqual(alerts.count, 2)
        let duplicate = try XCTUnwrap(alerts.first { $0.status == .duplicate })
        XCTAssertNotNil(duplicate.duplicateOfAlertID)
        XCTAssertTrue(duplicate.rawBody.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExtractionRun>()).count, 1)
    }

    @MainActor
    func testSameAlertAfterWindowCanBeLegitimateSecondTransaction() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.validDraft))
        )

        for offset in [TimeInterval(0), TimeInterval(16)] {
            _ = try await service.ingest(
                body: TestFixtures.validBody,
                sender: "AX-HDFCBK",
                receivedAt: TestFixtures.receivedAt.addingTimeInterval(offset),
                sourceApplication: "Messages",
                origin: .shortcut
            )
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 2)
    }

    @MainActor
    func testUnavailableModelLeavesDurableAlertThenRetryRecovers() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let unavailable = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .failure(.modelUnavailable(.modelNotReady)))
        )

        let first = try await unavailable.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(first.disposition, .queued)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .pending)
        XCTAssertEqual(alert.rawBody, TestFixtures.validBody)
        let failedRun = try XCTUnwrap(context.fetch(FetchDescriptor<ExtractionRun>()).first)
        XCTAssertEqual(failedRun.attemptIndex, 1)
        XCTAssertNil(failedRun.parserDraft)
        XCTAssertEqual(failedRun.validationOutcome, .notPerformed)
        XCTAssertEqual(
            EvidenceValidationStage.allCases.map { failedRun.validationState(for: $0) },
            Array(repeating: .notRun, count: EvidenceValidationStage.allCases.count)
        )
        XCTAssertEqual(failedRun.safeResultCode, "model_modelNotReady")
        XCTAssertEqual(failedRun.terminalDisposition, .queued)
        XCTAssertNil(failedRun.acceptedTransactionID)

        let recovered = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.validDraft))
        )
        let second = try await recovered.retry(alertID: alert.id)
        XCTAssertEqual(second.disposition, .imported)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 1)
        XCTAssertEqual(alert.attemptCount, 2)
        let runs = try context.fetch(
            FetchDescriptor<ExtractionRun>(sortBy: [SortDescriptor(\ExtractionRun.attemptIndex)])
        )
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map(\.attemptIndex), [1, 2])
        XCTAssertNil(runs[0].parserDraft)
        XCTAssertEqual(runs[0].safeResultCode, "model_modelNotReady")
        XCTAssertEqual(runs[1].parserDraft, TestFixtures.validDraft)
        XCTAssertEqual(runs[1].validationOutcome, .passed)
        XCTAssertEqual(runs[1].terminalDisposition, .imported)
    }

    @MainActor
    func testRetryableGenerationFailureRemainsQueuedWithSafeCode() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .failure(.assetsUnavailable))
        )

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .queued)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .pending)
        XCTAssertEqual(alert.lastErrorCode, "model_assets_unavailable")
        XCTAssertEqual(alert.rawBody, TestFixtures.validBody)
    }

    @MainActor
    func testTerminalGenerationFailureNeedsReviewAndRetainsEvidence() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .failure(.unsupportedLanguageOrLocale))
        )

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .needsReview)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .needsReview)
        XCTAssertEqual(alert.lastErrorCode, "model_unsupported_language")
        XCTAssertEqual(alert.rawBody, TestFixtures.validBody)
        XCTAssertEqual(alert.sender, "AX-HDFCBK")
    }

    @MainActor
    func testRecoveryRefiltersDurableUnclassifiedAlertBeforeModelWork() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "PocketFinancerRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "PocketFinancer.store")
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let alertID: UUID
        do {
            let database = try AppDatabase(storeURL: storeURL)
            let context = database.container.mainContext
            let body = "Rs.5000 spent on Card XX1111. OTP is 876123. Do not share."
            let alert = InboxAlert(
                sourceIdentity: AlertSourceIdentity.fingerprint(
                    sender: "AX-HDFCBK",
                    body: body,
                    receivedAt: TestFixtures.receivedAt,
                    sourceApplication: "Messages"
                ),
                contentDigest: AlertSourceIdentity.contentDigest(sender: "AX-HDFCBK", body: body),
                origin: .shortcut,
                sourceApplication: "Messages",
                sender: "AX-HDFCBK",
                rawBody: body,
                receivedAt: TestFixtures.receivedAt
            )
            alertID = alert.id
            context.insert(alert)
            try context.save()
        }

        let reopened = try AppDatabase(storeURL: storeURL)
        let context = reopened.container.mainContext
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .failure(.generationFailed))
        )
        let processed = await service.processPending()
        XCTAssertEqual(processed, 1)

        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first { $0.id == alertID })
        XCTAssertEqual(alert.status, .rejected)
        XCTAssertEqual(alert.rejectionCode, AlertRejectionCode.oneTimePassword.rawValue)
        XCTAssertTrue(alert.rawBody.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
    }

    @MainActor
    func testModelNonTransactionRequiresReviewWithoutDestroyingEvidence() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let draft = ParsedAlertDraft(
            classification: .nonTransaction,
            direction: "",
            amountText: "",
            merchant: "",
            accountLabel: "",
            occurredAtText: "",
            currencyCode: "INR"
        )
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(draft))
        )

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .needsReview)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .needsReview)
        XCTAssertEqual(alert.lastErrorCode, EvidenceValidationIssue.modelRejected.rawValue)
        XCTAssertEqual(alert.rawBody, TestFixtures.validBody)
        XCTAssertEqual(alert.sender, "AX-HDFCBK")
    }

    @MainActor
    func testValidationFailureNeedsReviewAndRetainsEvidence() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let hallucinated = ParsedAlertDraft(
            classification: .transaction,
            direction: "debit",
            amountText: "Rs.999.00",
            merchant: "Demo Store",
            accountLabel: "a/c XXXXXX0000",
            occurredAtText: "05-08-2026",
            currencyCode: "INR"
        )
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(hallucinated))
        )

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(receipt.disposition, .needsReview)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.rawBody, TestFixtures.validBody)
        XCTAssertEqual(alert.lastErrorCode, EvidenceValidationIssue.amountNotGrounded.rawValue)
        let run = try XCTUnwrap(context.fetch(FetchDescriptor<ExtractionRun>()).first)
        XCTAssertEqual(run.parserDraft, hallucinated)
        XCTAssertEqual(run.validationOutcome, .failed)
        XCTAssertEqual(run.validationState(for: .classification), .passed)
        XCTAssertEqual(run.validationState(for: .direction), .passed)
        XCTAssertEqual(run.validationState(for: .amount), .failed)
        XCTAssertEqual(run.validationState(for: .merchant), .notRun)
        XCTAssertEqual(run.validationState(for: .account), .notRun)
        XCTAssertEqual(run.validationState(for: .date), .notRun)
        XCTAssertEqual(run.safeResultCode, EvidenceValidationIssue.amountNotGrounded.rawValue)
        XCTAssertEqual(run.terminalDisposition, .needsReview)
        XCTAssertNil(run.acceptedTransactionID)
    }

    @MainActor
    func testRetryUpdatesExistingDraftButNeverOverwritesManualCorrection() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let initial = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.reviewDraft))
        )
        let receipt = try await initial.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(receipt.disposition, .needsReview)
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        transaction.merchant = "Corrected by owner"
        transaction.isEdited = true
        try context.save()

        let retry = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.validDraft))
        )
        _ = try await retry.retry(alertID: alert.id)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 1)
        XCTAssertEqual(transaction.merchant, "Corrected by owner")
        XCTAssertEqual(alert.rawBody, TestFixtures.validBody)
        XCTAssertEqual(alert.status, .imported)
        let run = try XCTUnwrap(context.fetch(FetchDescriptor<ExtractionRun>()).first)
        XCTAssertEqual(run.parserDraft?.merchant, TestFixtures.reviewDraft.merchant)
        XCTAssertEqual(run.acceptedMerchant, "Unknown Merchant")
        XCTAssertEqual(run.acceptedReviewState, .needsReview)
        XCTAssertNotEqual(run.acceptedMerchant, transaction.merchant)
    }

    @MainActor
    func testRetryUpdatesExistingUneditedDraftWithoutCreatingDuplicate() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let initial = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.reviewDraft))
        )
        _ = try await initial.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first)
        let originalID = original.id
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)

        let retry = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.validDraft))
        )
        let receipt = try await retry.retry(alertID: alert.id)

        XCTAssertEqual(receipt.disposition, .imported)
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.id, originalID)
        XCTAssertEqual(transactions.first?.merchant, "Demo Store")
        XCTAssertEqual(transactions.first?.reviewState, .confirmed)
    }

    @MainActor
    func testAutomaticRecoveryRespectsAttemptLimit() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = InboxAlert(
            sourceIdentity: "test-attempt-limit",
            contentDigest: "test-attempt-limit",
            origin: .shortcut,
            sourceApplication: "Messages",
            sender: "AX-HDFCBK",
            rawBody: TestFixtures.validBody,
            receivedAt: TestFixtures.receivedAt
        )
        alert.attemptCount = AlertIngestionService.automaticAttemptLimit
        context.insert(alert)
        try context.save()

        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.validDraft))
        )
        let processed = await service.processPending()
        XCTAssertEqual(processed, 1)
        XCTAssertEqual(alert.status, .needsReview)
        XCTAssertEqual(alert.lastErrorCode, "automatic_retry_limit_reached")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
    }

    @MainActor
    func testRejectsOversizedInputBeforePersistence() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let service = AlertIngestionService(context: context)
        let oversizedBody = String(repeating: "x", count: AlertIngestionService.maximumBodyBytes + 1)

        do {
            _ = try await service.ingest(
                body: oversizedBody,
                sender: "AX-HDFCBK",
                receivedAt: TestFixtures.receivedAt,
                sourceApplication: "Messages",
                origin: .shortcut
            )
            XCTFail("Expected oversized input to be rejected")
        } catch {
            XCTAssertEqual(error as? AlertIngestionError, .inputTooLarge)
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxAlert>()).isEmpty)
    }

    @MainActor
    func testParserDeadlineLeavesAlertRetryable() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            parser: SlowTransactionParser(),
            parserTimeout: .milliseconds(10)
        )
        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(receipt.disposition, .queued)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .pending)
        XCTAssertEqual(alert.lastErrorCode, "model_timed_out")
    }

    @MainActor
    func testEraseAllRemovesLedgerQueueAccountsAndEvidence() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(result: .success(TestFixtures.validDraft))
        )
        _ = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .manual
        )

        try LocalDataService(context: context).eraseAll()
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxAlert>()).isEmpty)
    }
}
