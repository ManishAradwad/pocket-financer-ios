import SwiftData
import XCTest

@testable import PocketFinancer

final class AlertIngestionServiceTests: XCTestCase {
    @MainActor
    func testDefaultParserFactoryIsLazyUntilAnEligibleAlertReachesModelWork() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let counter = ParserFactoryCallCounter()
        let parser = FakeTransactionParser(result: .success(TestFixtures.validDraft))
        let service = AlertIngestionService(
            context: context,
            parserFactory: {
                await counter.recordCall()
                return parser
            }
        )

        let emptyProcessedCount = await service.processPending()
        let emptyFactoryCallCount = await counter.callCount
        XCTAssertEqual(emptyProcessedCount, 0)
        XCTAssertEqual(emptyFactoryCallCount, 0)

        _ = try service.enqueue(
            body: "HDFC Bank: debit notice for a/c XXXXXX0000.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let ineligibleProcessedCount = await service.processPending()
        let ineligibleFactoryCallCount = await counter.callCount
        XCTAssertEqual(ineligibleProcessedCount, 1)
        XCTAssertEqual(ineligibleFactoryCallCount, 0)

        _ = try service.enqueue(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(20),
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let eligibleProcessedCount = await service.processPending()
        let eligibleFactoryCallCount = await counter.callCount
        XCTAssertEqual(eligibleProcessedCount, 1)
        XCTAssertEqual(eligibleFactoryCallCount, 1)

        _ = try service.enqueue(
            body: "HDFC Bank: Rs.700.00 debited from a/c XXXXXX0000 on 05-08-2026 at Demo Store.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(40),
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let secondEligibleProcessedCount = await service.processPending()
        let cachedFactoryCallCount = await counter.callCount
        XCTAssertEqual(secondEligibleProcessedCount, 1)
        XCTAssertEqual(cachedFactoryCallCount, 1)
    }

    @MainActor
    func testCancelledParserDiscoveryDoesNotBlockReplacementDrain() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let gate = ParserFactoryGate()
        let staleParser = FakeTransactionParser(
            parserName: "Cancelled Discovery Parser",
            result: .success(TestFixtures.validDraft)
        )
        let staleService = AlertIngestionService(
            context: context,
            parserFactory: {
                await gate.waitForRelease()
                return staleParser
            }
        )
        _ = try staleService.enqueue(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        let staleDrain = Task { await staleService.processPending() }
        await gate.waitUntilStarted()
        staleDrain.cancel()

        let replacementService = AlertIngestionService(
            context: context,
            parser: FakeTransactionParser(
                parserName: "Replacement Parser",
                result: .success(TestFixtures.validDraft)
            )
        )
        let replacementProcessed = await replacementService.processPending()

        XCTAssertEqual(replacementProcessed, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExtractionRun>()).count, 1)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.attemptCount, 1)
        XCTAssertEqual(alert.parserName, "Replacement Parser")

        await gate.release()
        _ = await staleDrain.value
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExtractionRun>()).count, 1)
    }

    @MainActor
    func testCancellationDuringParserCannotCommitDraftOrTransaction() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let gate = ParserFactoryGate()
        let service = AlertIngestionService(
            context: context,
            parser: CancellationIgnoringTransactionParser(gate: gate)
        )
        _ = try service.enqueue(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        let processingTask = Task { await service.processPending() }
        await gate.waitUntilStarted()
        processingTask.cancel()
        await gate.release()
        _ = await processingTask.value

        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .pending)
        XCTAssertEqual(alert.lastErrorCode, "model_cancelled")
        let run = try XCTUnwrap(context.fetch(FetchDescriptor<ExtractionRun>()).first)
        XCTAssertNil(run.parserDraft)
        XCTAssertNil(run.acceptedTransactionID)
        XCTAssertEqual(run.safeResultCode, "model_cancelled")
        XCTAssertEqual(run.terminalDisposition, .queued)
    }

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
        let extractionRun = try XCTUnwrap(context.fetch(FetchDescriptor<ExtractionRun>()).first)
        let filterRun = try XCTUnwrap(context.fetch(FetchDescriptor<DeterministicFilterRun>()).first)
        XCTAssertEqual(filterRun.alertID, alerts.first?.id)
        XCTAssertEqual(filterRun.evaluationIndex, 1)
        XCTAssertEqual(filterRun.rulesVersion, AlertFilter.rulesVersion)
        XCTAssertEqual(filterRun.decision, .eligible)
        XCTAssertNil(filterRun.rejectionCode)
        XCTAssertFalse(filterRun.senderWasUsed)
        XCTAssertEqual(filterRun.extractionRunID, extractionRun.id)
        XCTAssertEqual(
            filterRun.stages?.map(\.state),
            Array(repeating: .passed, count: AlertFilterStageID.allCases.count)
        )
    }

    @MainActor
    func testStreamingParserPersistsEveryExactStructuredSnapshotBeforeLedgerWrite() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let snapshots = [
            TransactionParserGenerationSnapshot(
                sequenceIndex: 0,
                capturedAt: TestFixtures.receivedAt.addingTimeInterval(0.1),
                rawContentJSON: #"{"kind":"debit"}"#,
                isComplete: false,
                formatIdentifier: TransactionParserGenerationSnapshot.currentFormatIdentifier
            ),
            TransactionParserGenerationSnapshot(
                sequenceIndex: 1,
                capturedAt: TestFixtures.receivedAt.addingTimeInterval(0.2),
                rawContentJSON: #"{"kind":"debit","amountText":"Rs.500.00"}"#,
                isComplete: false,
                formatIdentifier: TransactionParserGenerationSnapshot.currentFormatIdentifier
            ),
            TransactionParserGenerationSnapshot(
                sequenceIndex: 2,
                capturedAt: TestFixtures.receivedAt.addingTimeInterval(0.3),
                rawContentJSON:
                    #"{"kind":"debit","amountText":"Rs.500.00","merchantText":"Demo Store","accountText":"a/c XXXXXX0000","dateText":"05-08-2026","currencyCode":"INR"}"#,
                isComplete: true,
                formatIdentifier: TransactionParserGenerationSnapshot.currentFormatIdentifier
            ),
        ]
        let service = AlertIngestionService(
            context: context,
            parser: StreamingTransactionParser(
                snapshots: snapshots,
                draft: TestFixtures.validDraft
            )
        )

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .imported)
        let run = try XCTUnwrap(context.fetch(FetchDescriptor<ExtractionRun>()).first)
        let stored = try context.fetch(
            FetchDescriptor<StructuredGenerationSnapshot>(
                sortBy: [SortDescriptor(\StructuredGenerationSnapshot.sequenceIndex)]
            )
        )
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored.map(\.extractionRunID), Array(repeating: run.id, count: 3))
        XCTAssertEqual(stored.map(\.sequenceIndex), [0, 1, 2])
        XCTAssertEqual(stored.map(\.rawContentJSON), snapshots.map(\.rawContentJSON))
        XCTAssertEqual(stored.map(\.isComplete), [false, false, true])
        XCTAssertEqual(
            stored.map(\.formatIdentifier),
            Array(
                repeating: StructuredGenerationSnapshot.currentFormatIdentifier,
                count: 3
            )
        )
        XCTAssertEqual(run.parserDraft, TestFixtures.validDraft)
        XCTAssertEqual(run.validationOutcome, .passed)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 1)
    }

    @MainActor
    func testSnapshotPersistenceFailureStopsBeforeValidationAndLedgerWrite() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let snapshot = TransactionParserGenerationSnapshot(
            sequenceIndex: 0,
            capturedAt: TestFixtures.receivedAt.addingTimeInterval(0.1),
            rawContentJSON: #"{"kind":"debit"}"#,
            isComplete: false,
            formatIdentifier: TransactionParserGenerationSnapshot.currentFormatIdentifier
        )
        var saveAttempt = 0
        let service = AlertIngestionService(
            context: context,
            parser: StreamingTransactionParser(
                snapshots: [snapshot],
                draft: TestFixtures.validDraft
            ),
            contextSaver: { context in
                saveAttempt += 1
                if saveAttempt == 4 {
                    throw AlertIngestionError.persistenceFailed
                }
                try context.save()
            }
        )

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .processingIncomplete)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .processing)
        XCTAssertEqual(alert.rawBody, TestFixtures.validBody)
        let run = try XCTUnwrap(context.fetch(FetchDescriptor<ExtractionRun>()).first)
        XCTAssertNil(run.parserDraft)
        XCTAssertNil(run.validationOutcome)
        XCTAssertNil(run.completedAt)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
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
        XCTAssertEqual(run.contractVersion, "foundation-transaction-extraction.v3")
        XCTAssertEqual(run.profileVersion, "3")
        XCTAssertEqual(run.localeIdentifier, "en-US")
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
        let filterRun = try XCTUnwrap(context.fetch(FetchDescriptor<DeterministicFilterRun>()).first)
        XCTAssertEqual(filterRun.decision, .rejectAndErase)
        XCTAssertEqual(filterRun.rejectionCode, .oneTimePassword)
        XCTAssertNil(filterRun.extractionRunID)
        XCTAssertEqual(filterRun.stages?.first?.state, .passed)
        XCTAssertEqual(filterRun.stages?.dropFirst().first?.state, .failed)
    }

    @MainActor
    func testCompletedAlertFilterExceptionsRetainEvidenceAndReachModel() async throws {
        let bodies = [
            TestFixtures.validBody + " This debit was processed without OTP.",
            TestFixtures.validBody + " Explore offers in the bank app.",
        ]

        for body in bodies {
            let database = try AppDatabase(inMemory: true)
            let context = database.container.mainContext
            let service = AlertIngestionService(
                context: context,
                parser: FakeTransactionParser(result: .success(TestFixtures.validDraft))
            )

            let receipt = try await service.ingest(
                body: body,
                sender: "AX-HDFCBK",
                receivedAt: TestFixtures.receivedAt,
                sourceApplication: "Messages",
                origin: .shortcut
            )

            XCTAssertEqual(receipt.disposition, .imported, body)
            let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
            XCTAssertEqual(alert.status, .imported, body)
            XCTAssertEqual(alert.rawBody, body)
            XCTAssertNil(alert.rejectionCode)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).count, 1)
            XCTAssertEqual(try context.fetch(FetchDescriptor<ExtractionRun>()).count, 1)
            let filterRun = try XCTUnwrap(
                context.fetch(FetchDescriptor<DeterministicFilterRun>()).first
            )
            XCTAssertEqual(filterRun.decision, .eligible, body)
        }
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
    func testOwnerCorrectionDuringRetryIsNotOverwrittenByReturningModel() async throws {
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
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        let originalUpdatedAt = transaction.updatedAt
        let parser = InspectingTransactionParser {
            transaction.merchant = "Corrected while retry was running"
            transaction.isEdited = true
            transaction.reviewState = .confirmed
            transaction.updatedAt = originalUpdatedAt.addingTimeInterval(1)
            alert.status = .imported
            alert.updatedAt = originalUpdatedAt.addingTimeInterval(1)
            try context.save()
        }
        let retry = AlertIngestionService(context: context, parser: parser)

        let receipt = try await retry.retry(alertID: alert.id)

        XCTAssertEqual(receipt.disposition, .imported)
        XCTAssertEqual(transaction.merchant, "Corrected while retry was running")
        XCTAssertTrue(transaction.isEdited)
        XCTAssertEqual(transaction.reviewState, .confirmed)
        XCTAssertEqual(alert.status, .imported)
        let runs = try context.fetch(
            FetchDescriptor<ExtractionRun>(sortBy: [SortDescriptor(\ExtractionRun.attemptIndex)])
        )
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.last?.safeResultCode, "owner_change_preserved")
        XCTAssertEqual(runs.last?.terminalDisposition, .imported)
        XCTAssertNil(runs.last?.acceptedTransactionID)
    }

    @MainActor
    func testOwnerDeletionDuringRetryIsNotRecreatedByReturningModel() async throws {
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
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        let parser = InspectingTransactionParser {
            alert.transactionID = nil
            alert.status = .needsReview
            alert.updatedAt = .now
            context.delete(transaction)
            try context.save()
        }
        let retry = AlertIngestionService(context: context, parser: parser)

        let receipt = try await retry.retry(alertID: alert.id)

        XCTAssertEqual(receipt.disposition, .needsReview)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertNil(alert.transactionID)
        XCTAssertEqual(alert.status, .needsReview)
        let runs = try context.fetch(
            FetchDescriptor<ExtractionRun>(sortBy: [SortDescriptor(\ExtractionRun.attemptIndex)])
        )
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.last?.safeResultCode, "owner_change_preserved")
        XCTAssertEqual(runs.last?.terminalDisposition, .needsReview)
        XCTAssertNil(runs.last?.acceptedTransactionID)
    }

    @MainActor
    func testOwnerDeletionDuringParserDiscoveryIsNotRecreated() async throws {
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
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        let initialAttemptCount = alert.attemptCount
        let gate = ParserFactoryGate()
        let parser = FakeTransactionParser(result: .success(TestFixtures.validDraft))
        let retry = AlertIngestionService(
            context: context,
            parserFactory: {
                await gate.waitForRelease()
                return parser
            }
        )

        let retryTask = Task { try await retry.retry(alertID: alert.id) }
        await gate.waitUntilStarted()
        alert.transactionID = nil
        alert.status = .needsReview
        alert.updatedAt = alert.updatedAt.addingTimeInterval(1)
        context.delete(transaction)
        try context.save()
        await gate.release()

        let receipt = try await retryTask.value
        XCTAssertEqual(receipt.disposition, .needsReview)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertEqual(alert.attemptCount, initialAttemptCount)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExtractionRun>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).count, 1)
    }

    @MainActor
    func testOwnerEditDuringParserDiscoveryReturnsImportedWithoutModelAttempt() async throws {
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
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        let initialAttemptCount = alert.attemptCount
        let gate = ParserFactoryGate()
        let parser = FakeTransactionParser(result: .success(TestFixtures.validDraft))
        let retry = AlertIngestionService(
            context: context,
            parserFactory: {
                await gate.waitForRelease()
                return parser
            }
        )

        let retryTask = Task { try await retry.retry(alertID: alert.id) }
        await gate.waitUntilStarted()
        transaction.merchant = "Owner correction"
        transaction.isEdited = true
        transaction.reviewState = .confirmed
        transaction.updatedAt = transaction.updatedAt.addingTimeInterval(1)
        alert.status = .imported
        alert.updatedAt = alert.updatedAt.addingTimeInterval(1)
        try context.save()
        await gate.release()

        let receipt = try await retryTask.value
        XCTAssertEqual(receipt.disposition, .imported)
        XCTAssertEqual(transaction.merchant, "Owner correction")
        XCTAssertEqual(alert.attemptCount, initialAttemptCount)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExtractionRun>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).count, 1)
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
        let extractionRun = try XCTUnwrap(context.fetch(FetchDescriptor<ExtractionRun>()).first)
        context.insert(
            StructuredGenerationSnapshot(
                extractionRunID: extractionRun.id,
                sequenceIndex: 0,
                capturedAt: TestFixtures.receivedAt,
                rawContentJSON: #"{"kind":"debit"}"#,
                isComplete: false
            )
        )
        try context.save()

        try LocalDataService(context: context).eraseAll()
        XCTAssertTrue(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxAlert>()).isEmpty)
    }

    @MainActor
    func testEraseAllInvalidatesInFlightGenerationBeforeItCanWriteAgain() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let snapshots = [
            TransactionParserGenerationSnapshot(
                sequenceIndex: 0,
                capturedAt: TestFixtures.receivedAt.addingTimeInterval(0.1),
                rawContentJSON: #"{"kind":"debit"}"#,
                isComplete: false,
                formatIdentifier: TransactionParserGenerationSnapshot.currentFormatIdentifier
            ),
            TransactionParserGenerationSnapshot(
                sequenceIndex: 1,
                capturedAt: TestFixtures.receivedAt.addingTimeInterval(0.2),
                rawContentJSON: #"{"kind":"debit","amountText":"Rs.500.00"}"#,
                isComplete: false,
                formatIdentifier: TransactionParserGenerationSnapshot.currentFormatIdentifier
            ),
        ]
        let parser = ErasingStreamingTransactionParser(
            snapshots: snapshots,
            draft: TestFixtures.validDraft,
            eraseDuringGeneration: {
                try LocalDataService(context: context).eraseAll()
            }
        )
        let service = AlertIngestionService(context: context, parser: parser)

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .manual
        )

        XCTAssertEqual(receipt.disposition, .processingIncomplete)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxAlert>()).isEmpty)
    }

    @MainActor
    func testEraseAllDuringLazyParserLoadCannotRecreateEvidence() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let gate = ParserFactoryGate()
        let parser = FakeTransactionParser(result: .success(TestFixtures.validDraft))
        let service = AlertIngestionService(
            context: context,
            parserFactory: {
                await gate.waitForRelease()
                return parser
            }
        )
        _ = try service.enqueue(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        let processingTask = Task { await service.processPending() }
        await gate.waitUntilStarted()
        try LocalDataService(context: context).eraseAll()
        await gate.release()

        let processed = await processingTask.value
        XCTAssertEqual(processed, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxAlert>()).isEmpty)
    }

    @MainActor
    func testEraseAllStopsPrefetchedPendingLoopFromRestartingAfterGeneration() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let snapshot = TransactionParserGenerationSnapshot(
            sequenceIndex: 0,
            capturedAt: TestFixtures.receivedAt.addingTimeInterval(0.1),
            rawContentJSON: #"{"kind":"debit"}"#,
            isComplete: false,
            formatIdentifier: TransactionParserGenerationSnapshot.currentFormatIdentifier
        )
        let parser = ErasingStreamingTransactionParser(
            snapshots: [snapshot],
            draft: TestFixtures.validDraft,
            eraseDuringGeneration: {
                try LocalDataService(context: context).eraseAll()
            }
        )
        let service = AlertIngestionService(context: context, parser: parser)
        _ = try service.enqueue(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        _ = try service.enqueue(
            body: "HDFC Bank: Rs.700.00 debited from a/c XXXXXX0000 on 05-08-2026 at Demo Store.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(20),
            sourceApplication: "Messages",
            origin: .shortcut
        )

        let processed = await service.processPending()

        XCTAssertEqual(processed, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxAlert>()).isEmpty)
    }
}

private actor ParserFactoryCallCounter {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

private actor ParserFactoryGate {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        didStart = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private struct CancellationIgnoringTransactionParser: TransactionParsing {
    let parserName = "Cancellation-Ignoring Test Parser"
    let requestMetadata = TestFixtures.parserRequestMetadata
    let gate: ParserFactoryGate

    func parse(body: String, sender: String, receivedAt: Date) async throws -> ParsedAlertDraft {
        await gate.waitForRelease()
        return TestFixtures.validDraft
    }
}
