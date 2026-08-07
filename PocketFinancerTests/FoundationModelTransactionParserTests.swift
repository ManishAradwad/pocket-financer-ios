import Foundation
import FoundationModels
import XCTest

@testable import PocketFinancer

final class FoundationModelTransactionParserTests: XCTestCase {
    @MainActor
    func testDefaultParserUsesTheContractModelLocaleInsteadOfTheFormattingLocale() {
        let parser = FoundationModelTransactionParser()

        XCTAssertEqual(
            parser.requestMetadata.localeIdentifier,
            FoundationModelExtractionContract.modelProcessingLocaleIdentifier
        )
        XCTAssertEqual(parser.requestMetadata.localeIdentifier, "en-US")
    }

    @MainActor
    func testParserCapturesExactRequestedLocaleAndSortedModelLanguages() {
        let parser = FoundationModelTransactionParser(processingLocale: Locale(identifier: "en_IN"))

        XCTAssertEqual(parser.requestMetadata.localeIdentifier, "en_IN")
        XCTAssertEqual(
            parser.requestMetadata.supportedLanguageIdentifiers,
            parser.requestMetadata.supportedLanguageIdentifiers.sorted()
        )
    }

    @MainActor
    func testMapsGenerationErrorsToPrivacySafeCategories() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "must not be persisted or shown")

        XCTAssertEqual(
            FoundationModelTransactionParser.mapGenerationError(.assetsUnavailable(context)),
            .assetsUnavailable
        )
        XCTAssertEqual(
            FoundationModelTransactionParser.mapGenerationError(.unsupportedLanguageOrLocale(context)),
            .unsupportedLanguageOrLocale
        )
        XCTAssertEqual(
            FoundationModelTransactionParser.mapGenerationError(.guardrailViolation(context)),
            .guardrailViolation
        )
        XCTAssertEqual(
            FoundationModelTransactionParser.mapGenerationError(.concurrentRequests(context)),
            .concurrentRequests
        )
        XCTAssertEqual(
            FoundationModelTransactionParser.mapGenerationError(.decodingFailure(context)),
            .decodingFailure
        )
    }

    func testParserErrorRetryPolicyAndSafeCodes() {
        XCTAssertTrue(TransactionParserError.assetsUnavailable.isRetryable)
        XCTAssertTrue(TransactionParserError.rateLimited.isRetryable)
        XCTAssertTrue(TransactionParserError.concurrentRequests.isRetryable)
        XCTAssertTrue(TransactionParserError.modelUnavailable(.modelNotReady).isRetryable)
        XCTAssertFalse(TransactionParserError.modelUnavailable(.deviceNotEligible).isRetryable)
        XCTAssertFalse(TransactionParserError.unsupportedLanguageOrLocale.isRetryable)
        XCTAssertFalse(TransactionParserError.modelRefused.isRetryable)
        XCTAssertEqual(TransactionParserError.modelRefused.safeCode, "model_refused")
    }
}
