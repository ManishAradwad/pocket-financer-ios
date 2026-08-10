import Foundation
import FoundationModels

@Generable
private enum GeneratedTransactionKind {
    case debit
    case credit
    case refund
    case reversal
    case nonFinancial
}

@Generable(description: "Verbatim transaction fields copied from one financial alert")
private struct GeneratedTransactionAlert {
    @Guide(
        description: "Classify the completed action; requests, OTPs, offers, balances, and due notices are nonFinancial"
    )
    var kind: GeneratedTransactionKind

    @Guide(description: "Exact amount substring including currency marker, copied from the alert")
    var amountText: String?

    @Guide(
        description:
            "Exact merchant, VPA, beneficiary, or counterparty substring copied from the alert; nil when absent")
    var merchantText: String?

    @Guide(description: "Exact masked account or card label substring copied from the alert")
    var accountText: String?

    @Guide(description: "Exact transaction date/time substring copied from the alert; nil when absent")
    var dateText: String?

    @Guide(description: "ISO 4217 currency code", .anyOf(["INR"]))
    var currencyCode: String?
}

struct FoundationModelTransactionParser: TransactionParsing {
    private struct ProgressReportingError: Error {
        let underlyingError: any Error
    }

    let parserName = FoundationModelExtractionContract.parserName
    let requestMetadata: TransactionParserRequestMetadata

    private let model: SystemLanguageModel
    private let processingLocale: Locale

    init(
        processingLocale: Locale = FoundationModelExtractionContract.modelProcessingLocale,
        model: SystemLanguageModel = .default
    ) {
        self.processingLocale = processingLocale
        self.model = model
        requestMetadata = TransactionParserRequestMetadata(
            localeIdentifier: processingLocale.identifier,
            localeWasSupported: model.supportsLocale(processingLocale),
            supportedLanguageIdentifiers: ModelDiagnostics.languageIdentifiers(
                model.supportedLanguages
            )
        )
    }

    func parse(body: String, sender: String, receivedAt: Date) async throws -> ParsedAlertDraft {
        try await parse(
            body: body,
            sender: sender,
            receivedAt: receivedAt,
            progress: { _ in }
        )
    }

    func parse(
        body: String,
        sender _: String,
        receivedAt: Date,
        progress: @escaping TransactionParserProgressHandler
    ) async throws -> ParsedAlertDraft {
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw TransactionParserError.modelUnavailable(Self.map(reason))
        }

        guard model.supportsLocale(processingLocale) else {
            throw TransactionParserError.unsupportedLanguageOrLocale
        }

        let session = LanguageModelSession(model: model) {
            FoundationModelExtractionContract.instructions
        }

        let prompt = FoundationModelExtractionContract.requestPrompt(
            body: body,
            receivedAt: receivedAt
        )

        do {
            try await Self.report(.requestQueued(at: .now), to: progress)
            let generated = try await FoundationModelExecutionGate.shared.withPermit {
                try await Self.report(.generationStarted(at: .now), to: progress)

                let stream = session.streamResponse(
                    to: prompt,
                    generating: GeneratedTransactionAlert.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                var sequenceIndex = 0
                var lastRawContentJSON: String?
                var lastWasComplete: Bool?

                for try await snapshot in stream {
                    let rawContentJSON = snapshot.rawContent.jsonString
                    let isComplete = snapshot.rawContent.isComplete
                    try await Self.report(
                        .generationSnapshot(
                            TransactionParserGenerationSnapshot(
                                sequenceIndex: sequenceIndex,
                                capturedAt: .now,
                                rawContentJSON: rawContentJSON,
                                isComplete: isComplete,
                                formatIdentifier: TransactionParserGenerationSnapshot
                                    .currentFormatIdentifier
                            )
                        ),
                        to: progress
                    )
                    sequenceIndex += 1
                    lastRawContentJSON = rawContentJSON
                    lastWasComplete = isComplete
                }

                let response = try await stream.collect()
                let finalRawContentJSON = response.rawContent.jsonString
                let finalIsComplete = response.rawContent.isComplete
                if lastRawContentJSON != finalRawContentJSON || lastWasComplete != finalIsComplete {
                    try await Self.report(
                        .generationSnapshot(
                            TransactionParserGenerationSnapshot(
                                sequenceIndex: sequenceIndex,
                                capturedAt: .now,
                                rawContentJSON: finalRawContentJSON,
                                isComplete: finalIsComplete,
                                formatIdentifier: TransactionParserGenerationSnapshot
                                    .currentFormatIdentifier
                            )
                        ),
                        to: progress
                    )
                }
                try await Self.report(.generationCompleted(at: .now), to: progress)
                return response.content
            }
            return Self.map(generated)
        } catch let error as ProgressReportingError {
            throw error.underlyingError
        } catch is CancellationError {
            throw TransactionParserError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapGenerationError(error)
        } catch {
            throw TransactionParserError.generationFailed
        }
    }

    private static func report(
        _ update: TransactionParserProgress,
        to progress: TransactionParserProgressHandler
    ) async throws {
        do {
            try await progress(update)
        } catch {
            throw ProgressReportingError(underlyingError: error)
        }
    }

    private static func map(_ output: GeneratedTransactionAlert) -> ParsedAlertDraft {
        let classification: DraftClassification
        let direction: String
        switch output.kind {
        case .debit:
            classification = .transaction
            direction = TransactionDirection.debit.rawValue
        case .credit, .refund, .reversal:
            classification = .transaction
            direction = TransactionDirection.credit.rawValue
        case .nonFinancial:
            classification = .nonTransaction
            direction = ""
        }

        return ParsedAlertDraft(
            classification: classification,
            direction: direction,
            amountText: output.amountText ?? "",
            merchant: output.merchantText ?? "",
            accountLabel: output.accountText ?? "",
            occurredAtText: output.dateText ?? "",
            currencyCode: output.currencyCode ?? "INR"
        )
    }

    private static func map(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> ModelUnavailabilityReason {
        switch reason {
        case .deviceNotEligible:
            .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            .appleIntelligenceNotEnabled
        case .modelNotReady:
            .modelNotReady
        @unknown default:
            .unknown
        }
    }

    static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> TransactionParserError {
        switch error {
        case .exceededContextWindowSize:
            .contextWindowExceeded
        case .assetsUnavailable:
            .assetsUnavailable
        case .guardrailViolation:
            .guardrailViolation
        case .unsupportedGuide:
            .unsupportedGuide
        case .unsupportedLanguageOrLocale:
            .unsupportedLanguageOrLocale
        case .decodingFailure:
            .decodingFailure
        case .rateLimited:
            .rateLimited
        case .concurrentRequests:
            .concurrentRequests
        case .refusal:
            .modelRefused
        @unknown default:
            .generationFailed
        }
    }
}
