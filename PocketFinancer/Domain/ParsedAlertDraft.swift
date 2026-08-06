import Foundation

enum DraftClassification: String, Sendable {
    case transaction
    case nonTransaction = "non_transaction"
}

struct ParsedAlertDraft: Equatable, Sendable {
    let classification: DraftClassification
    let direction: String
    let amountText: String
    let merchant: String
    let accountLabel: String
    let occurredAtText: String
    let currencyCode: String
}

/// Public, owner-visible configuration captured before one parser request starts.
///
/// A Foundation Models parser reports the exact `Locale` identifier it will pass to
/// `supportsLocale`, whether that check succeeded when the metadata was captured, and
/// the language identifiers advertised by the system model. Deterministic test parsers
/// may leave model-only fields unavailable.
struct TransactionParserRequestMetadata: Equatable, Sendable {
    let localeIdentifier: String
    let localeWasSupported: Bool?
    let supportedLanguageIdentifiers: [String]
}

protocol TransactionParsing: Sendable {
    var parserName: String { get }
    var requestMetadata: TransactionParserRequestMetadata { get }

    func parse(
        body: String,
        sender: String,
        receivedAt: Date
    ) async throws -> ParsedAlertDraft
}

extension TransactionParsing {
    var requestMetadata: TransactionParserRequestMetadata {
        TransactionParserRequestMetadata(
            localeIdentifier: Locale.current.identifier,
            localeWasSupported: nil,
            supportedLanguageIdentifiers: []
        )
    }
}

enum TransactionParserError: Error, Equatable, Sendable {
    case modelUnavailable(ModelUnavailabilityReason)
    case timedOut
    case cancelled
    case assetsUnavailable
    case unsupportedLanguageOrLocale
    case guardrailViolation
    case unsupportedGuide
    case decodingFailure
    case rateLimited
    case concurrentRequests
    case modelRefused
    case contextWindowExceeded
    case generationFailed

    nonisolated var isRetryable: Bool {
        switch self {
        case .modelUnavailable(.appleIntelligenceNotEnabled),
            .modelUnavailable(.modelNotReady),
            .modelUnavailable(.unknown),
            .timedOut,
            .cancelled,
            .assetsUnavailable,
            .rateLimited,
            .concurrentRequests:
            true
        case .modelUnavailable(.deviceNotEligible),
            .unsupportedLanguageOrLocale,
            .guardrailViolation,
            .unsupportedGuide,
            .decodingFailure,
            .modelRefused,
            .contextWindowExceeded,
            .generationFailed:
            false
        }
    }

    nonisolated var safeCode: String {
        switch self {
        case .modelUnavailable(let reason):
            "model_\(reason.rawValue)"
        case .timedOut:
            "model_timed_out"
        case .cancelled:
            "model_cancelled"
        case .assetsUnavailable:
            "model_assets_unavailable"
        case .unsupportedLanguageOrLocale:
            "model_unsupported_language"
        case .guardrailViolation:
            "model_guardrail_violation"
        case .unsupportedGuide:
            "model_unsupported_guide"
        case .decodingFailure:
            "model_decoding_failed"
        case .rateLimited:
            "model_rate_limited"
        case .concurrentRequests:
            "model_concurrent_requests"
        case .modelRefused:
            "model_refused"
        case .contextWindowExceeded:
            "model_context_window_exceeded"
        case .generationFailed:
            "model_generation_failed"
        }
    }
}

enum ModelUnavailabilityReason: String, Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown
}
