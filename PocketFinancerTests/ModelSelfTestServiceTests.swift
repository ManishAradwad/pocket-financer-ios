import XCTest

@testable import PocketFinancer

final class ModelSelfTestServiceTests: XCTestCase {
    @MainActor
    func testPassedReportCapturesExactContractInputDraftAndValidatedFields() async throws {
        let receivedAt = Date(timeIntervalSince1970: 1_785_955_200.125)
        let draft = ParsedAlertDraft(
            classification: .transaction,
            direction: "debit",
            amountText: "Rs.500.00",
            merchant: "Demo Store",
            accountLabel: "XXXXXX0000",
            occurredAtText: "05-08-2026",
            currencyCode: "INR"
        )
        let parser = VerifyingSelfTestParser(expectedReceivedAt: receivedAt, draft: draft)

        let result = await ModelSelfTestService.run(
            parser: parser,
            timeout: .seconds(1),
            receivedAt: receivedAt
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.parserName, parser.parserName)
        XCTAssertEqual(result.contractVersion, FoundationModelExtractionContract.contractVersion)
        XCTAssertEqual(result.profileVersion, FoundationModelExtractionContract.extractionProfileVersion)
        XCTAssertEqual(result.localeIdentifier, parser.requestMetadata.localeIdentifier)
        XCTAssertEqual(result.localeWasSupported, true)
        XCTAssertEqual(result.supportedLanguageIdentifiers, ["en", "hi"])
        XCTAssertEqual(result.requestDeadline, "1 second")
        XCTAssertEqual(result.scheduling, FoundationModelExtractionContract.requestSchedulingDescription)
        XCTAssertEqual(result.guardrails, FoundationModelExtractionContract.guardrailsDescription)
        XCTAssertEqual(result.exactInstructions, FoundationModelExtractionContract.instructions)
        XCTAssertEqual(
            result.exactRequest,
            FoundationModelExtractionContract.requestPrompt(
                body: ModelSelfTestService.syntheticBody,
                receivedAt: receivedAt
            )
        )
        XCTAssertEqual(result.syntheticBody, ModelSelfTestService.syntheticBody)
        XCTAssertEqual(result.syntheticSender, ModelSelfTestService.syntheticSender)
        XCTAssertEqual(result.receivedAt, receivedAt)
        XCTAssertEqual(result.parserDraft, draft)
        XCTAssertEqual(result.validationOutcome, .passed)
        XCTAssertEqual(result.validationSafeCode, "validation_passed")
        XCTAssertEqual(result.validatedDraft?.amountMinorUnits, 50_000)
        XCTAssertEqual(result.validatedDraft?.currencyCode, "INR")
        XCTAssertEqual(result.validatedDraft?.direction, .debit)
        XCTAssertEqual(result.validatedDraft?.merchant, "Demo Store")
        XCTAssertEqual(result.validatedDraft?.accountLabel, "XXXXXX0000")
        XCTAssertNil(result.failure)
        XCTAssertGreaterThanOrEqual(result.completedAt, result.startedAt)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0)
        XCTAssertEqual(result.apiLimitations, ModelSelfTestService.apiLimitations)
        XCTAssertTrue(result.apiLimitations.contains { $0.metric.localizedCaseInsensitiveContains("token") })
        XCTAssertTrue(result.apiLimitations.contains { $0.metric.localizedCaseInsensitiveContains("context") })
        XCTAssertTrue(result.apiLimitations.contains { $0.metric.localizedCaseInsensitiveContains("reasoning") })
    }

    @MainActor
    func testEvidenceFailureRetainsExactParserDraftAndSafeCodeInMemory() async {
        let draft = ParsedAlertDraft(
            classification: .transaction,
            direction: "debit",
            amountText: "Rs.900.00",
            merchant: "Demo Store",
            accountLabel: "XXXXXX0000",
            occurredAtText: "05-08-2026",
            currencyCode: "INR"
        )

        let result = await ModelSelfTestService.run(
            parser: FakeTransactionParser(result: .success(draft)),
            timeout: .seconds(1),
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.parserDraft, draft)
        XCTAssertEqual(result.validationOutcome, .failed)
        XCTAssertEqual(result.validationSafeCode, EvidenceValidationIssue.amountNotGrounded.rawValue)
        XCTAssertNil(result.validatedDraft)
        XCTAssertEqual(result.failure?.safeCode, EvidenceValidationIssue.amountNotGrounded.rawValue)
        XCTAssertEqual(result.failure?.isRetryable, false)
        XCTAssertTrue(result.summary.localizedCaseInsensitiveContains("validation rejected"))
    }

    @MainActor
    func testParserFailureReportsSafeMappedErrorAndSkipsValidation() async {
        let result = await ModelSelfTestService.run(
            parser: FakeTransactionParser(result: .failure(.assetsUnavailable)),
            timeout: .seconds(1),
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertFalse(result.passed)
        XCTAssertNil(result.parserDraft)
        XCTAssertEqual(result.validationOutcome, .notRun)
        XCTAssertEqual(result.validationSafeCode, "validation_not_run")
        XCTAssertNil(result.validatedDraft)
        XCTAssertEqual(result.failure?.safeCode, TransactionParserError.assetsUnavailable.safeCode)
        XCTAssertEqual(result.failure?.isRetryable, true)
        XCTAssertTrue(result.failure?.ownerMessage.localizedCaseInsensitiveContains("assets") == true)
    }

    @MainActor
    func testUnsupportedLocaleFailureNamesExactCheckedLocaleWithoutInventingCause() async {
        let metadata = TransactionParserRequestMetadata(
            localeIdentifier: "zz_IN",
            localeWasSupported: false,
            supportedLanguageIdentifiers: ["en", "hi"]
        )
        let result = await ModelSelfTestService.run(
            parser: FakeTransactionParser(
                requestMetadata: metadata,
                result: .failure(.unsupportedLanguageOrLocale)
            ),
            timeout: .seconds(1),
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertEqual(result.localeIdentifier, "zz_IN")
        XCTAssertEqual(result.localeWasSupported, false)
        XCTAssertEqual(result.supportedLanguageIdentifiers, ["en", "hi"])
        XCTAssertTrue(result.failure?.ownerMessage.contains("zz_IN") == true)
        XCTAssertTrue(result.failure?.ownerMessage.contains("iPhone and Siri languages") == true)
        XCTAssertTrue(result.failure?.ownerMessage.contains("does not identify") == true)
    }

    @MainActor
    func testModelNotReadyFailureStatesPublicLimitWithoutClaimingDownloadProgress() async {
        let result = await ModelSelfTestService.run(
            parser: FakeTransactionParser(result: .failure(.modelUnavailable(.modelNotReady))),
            timeout: .seconds(1),
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertEqual(result.failure?.safeCode, "model_modelNotReady")
        XCTAssertTrue(result.failure?.ownerMessage.contains("modelNotReady") == true)
        XCTAssertTrue(result.failure?.ownerMessage.contains("does not expose download progress") == true)
    }

    @MainActor
    func testTimesOutWithStructuredReport() async {
        let result = await ModelSelfTestService.run(
            parser: SlowTransactionParser(),
            timeout: .milliseconds(10),
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.requestDeadline, "0.010 seconds")
        XCTAssertEqual(result.failure?.safeCode, TransactionParserError.timedOut.safeCode)
        XCTAssertEqual(result.validationOutcome, .notRun)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("time limit"))
    }
}

private struct VerifyingSelfTestParser: TransactionParsing {
    let parserName = "Input-verifying test parser"
    let requestMetadata = TestFixtures.parserRequestMetadata
    let expectedReceivedAt: Date
    let draft: ParsedAlertDraft

    func parse(body: String, sender: String, receivedAt: Date) async throws -> ParsedAlertDraft {
        guard
            body == ModelSelfTestService.syntheticBody,
            sender == ModelSelfTestService.syntheticSender,
            receivedAt == expectedReceivedAt
        else {
            throw TransactionParserError.generationFailed
        }
        return draft
    }
}
