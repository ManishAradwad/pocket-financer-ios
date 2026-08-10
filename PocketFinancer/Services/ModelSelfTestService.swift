import Foundation

enum ModelSelfTestOutcome: String, Equatable, Sendable {
    case passed
    case failed
}

enum ModelSelfTestValidationOutcome: String, Equatable, Sendable {
    case passed
    case failed
    case notRun = "not_run"
}

struct ModelSelfTestFailure: Equatable, Sendable {
    let safeCode: String
    let ownerMessage: String
    let isRetryable: Bool
}

struct ModelSelfTestAPILimitation: Equatable, Identifiable, Sendable {
    let metric: String
    let explanation: String

    var id: String { metric }
}

/// An ephemeral, owner-visible audit of one synthetic Foundation Models request.
///
/// This value can contain the exact prompt and model-derived fields. Keep it in
/// memory only: never persist, log, transmit, or attach it to diagnostics.
struct ModelSelfTestResult: Equatable, Identifiable, Sendable {
    let id: UUID
    let outcome: ModelSelfTestOutcome
    let startedAt: Date
    let completedAt: Date
    let elapsed: TimeInterval

    let parserName: String
    let contractVersion: String
    let profileVersion: String
    let localeIdentifier: String
    let localeWasSupported: Bool?
    let supportedLanguageIdentifiers: [String]
    let requestDeadline: String
    let scheduling: String
    let guardrails: String

    let exactInstructions: String
    let exactRequest: String
    let syntheticBody: String
    let syntheticSender: String
    let receivedAt: Date

    let parserDraft: ParsedAlertDraft?
    let validationOutcome: ModelSelfTestValidationOutcome
    let validationSafeCode: String
    let validationMessage: String
    let validatedDraft: ValidatedTransactionDraft?
    let failure: ModelSelfTestFailure?

    let apiLimitations: [ModelSelfTestAPILimitation]

    var passed: Bool { outcome == .passed }

    var summary: String {
        if passed {
            return "Apple Foundation Models produced a grounded extraction for the synthetic alert."
        }
        return failure?.ownerMessage ?? "The local synthetic model test did not pass."
    }

    /// Kept as a compatibility convenience for call sites that only need a short status.
    var message: String { summary }
}

enum ModelSelfTestService {
    static let timeout = FoundationModelExtractionContract.timeout
    static let syntheticBody =
        "HDFC Bank: Rs.500.00 debited from a/c XXXXXX0000 on 05-08-2026 at Demo Store."
    static let syntheticSender = "AX-HDFCBK"

    static let apiLimitations = [
        ModelSelfTestAPILimitation(
            metric: "System model build or version",
            explanation: "Not exposed by the public Apple Foundation Models API used by Pocket Financer."
        ),
        ModelSelfTestAPILimitation(
            metric: "Input and output token counts",
            explanation:
                "Not exposed by the public iOS 26 Foundation Models interface used by this build."
        ),
        ModelSelfTestAPILimitation(
            metric: "Tokens per second",
            explanation: "Not exposed; elapsed wall-clock time is the only performance measurement shown."
        ),
        ModelSelfTestAPILimitation(
            metric: "Numeric context-window size",
            explanation:
                "Not exposed by the public iOS 26 interface. It can report that a request exceeded the window without revealing its numeric capacity."
        ),
        ModelSelfTestAPILimitation(
            metric: "KV-cache details",
            explanation: "Not exposed by the public Apple Foundation Models API."
        ),
        ModelSelfTestAPILimitation(
            metric: "Confidence, probabilities, or logits",
            explanation: "Not exposed by the public Apple Foundation Models API."
        ),
        ModelSelfTestAPILimitation(
            metric: "Hidden reasoning",
            explanation: "Not exposed. Pocket Financer neither requests nor claims to display chain-of-thought."
        ),
    ]

    static func run(
        parser: any TransactionParsing = FoundationModelTransactionParser(),
        timeout: Duration = timeout,
        receivedAt requestedReceivedAt: Date? = nil
    ) async -> ModelSelfTestResult {
        let startedAt = Date()
        let receivedAt = requestedReceivedAt ?? startedAt
        let exactRequest = FoundationModelExtractionContract.requestPrompt(
            body: syntheticBody,
            receivedAt: receivedAt
        )

        do {
            let draft = try await parseWithDeadline(
                parser: parser,
                receivedAt: receivedAt,
                timeout: timeout
            )

            switch EvidenceValidator().validate(
                draft,
                body: syntheticBody,
                receivedAt: receivedAt
            ) {
            case .success(let validated):
                guard matchesExpectedSyntheticTransaction(validated) else {
                    return makeResult(
                        outcome: .failed,
                        startedAt: startedAt,
                        parser: parser,
                        timeout: timeout,
                        receivedAt: receivedAt,
                        exactRequest: exactRequest,
                        parserDraft: draft,
                        validationOutcome: .passed,
                        validationSafeCode: "validation_passed",
                        validationMessage:
                            "Every accepted field was grounded in the synthetic body, but the result did not match the known synthetic transaction.",
                        validatedDraft: validated,
                        failure: ModelSelfTestFailure(
                            safeCode: "synthetic_expectation_mismatch",
                            ownerMessage:
                                "The model produced grounded fields, but they did not match the expected INR 500.00 debit and account suffix.",
                            isRetryable: false
                        )
                    )
                }

                return makeResult(
                    outcome: .passed,
                    startedAt: startedAt,
                    parser: parser,
                    timeout: timeout,
                    receivedAt: receivedAt,
                    exactRequest: exactRequest,
                    parserDraft: draft,
                    validationOutcome: .passed,
                    validationSafeCode: "validation_passed",
                    validationMessage:
                        "Every accepted field was grounded against the synthetic alert before the result was marked passed.",
                    validatedDraft: validated,
                    failure: nil
                )

            case .failure(let issue):
                return makeResult(
                    outcome: .failed,
                    startedAt: startedAt,
                    parser: parser,
                    timeout: timeout,
                    receivedAt: receivedAt,
                    exactRequest: exactRequest,
                    parserDraft: draft,
                    validationOutcome: .failed,
                    validationSafeCode: issue.rawValue,
                    validationMessage: evidenceFailureMessage(for: issue),
                    validatedDraft: nil,
                    failure: ModelSelfTestFailure(
                        safeCode: issue.rawValue,
                        ownerMessage:
                            "The model returned a structured draft, but local evidence validation rejected it safely (\(issue.rawValue)).",
                        isRetryable: false
                    )
                )
            }
        } catch let error as TransactionParserError {
            return makeResult(
                outcome: .failed,
                startedAt: startedAt,
                parser: parser,
                timeout: timeout,
                receivedAt: receivedAt,
                exactRequest: exactRequest,
                parserDraft: nil,
                validationOutcome: .notRun,
                validationSafeCode: "validation_not_run",
                validationMessage:
                    "Evidence validation did not run because no ParsedAlertDraft was returned.",
                validatedDraft: nil,
                failure: ModelSelfTestFailure(
                    safeCode: error.safeCode,
                    ownerMessage: parserFailureMessage(
                        for: error,
                        localeIdentifier: parser.requestMetadata.localeIdentifier
                    ),
                    isRetryable: error.isRetryable
                )
            )
        } catch is CancellationError {
            let error = TransactionParserError.cancelled
            return makeResult(
                outcome: .failed,
                startedAt: startedAt,
                parser: parser,
                timeout: timeout,
                receivedAt: receivedAt,
                exactRequest: exactRequest,
                parserDraft: nil,
                validationOutcome: .notRun,
                validationSafeCode: "validation_not_run",
                validationMessage:
                    "Evidence validation did not run because no ParsedAlertDraft was returned.",
                validatedDraft: nil,
                failure: ModelSelfTestFailure(
                    safeCode: error.safeCode,
                    ownerMessage: parserFailureMessage(
                        for: error,
                        localeIdentifier: parser.requestMetadata.localeIdentifier
                    ),
                    isRetryable: error.isRetryable
                )
            )
        } catch {
            return makeResult(
                outcome: .failed,
                startedAt: startedAt,
                parser: parser,
                timeout: timeout,
                receivedAt: receivedAt,
                exactRequest: exactRequest,
                parserDraft: nil,
                validationOutcome: .notRun,
                validationSafeCode: "validation_not_run",
                validationMessage:
                    "Evidence validation did not run because no ParsedAlertDraft was returned.",
                validatedDraft: nil,
                failure: ModelSelfTestFailure(
                    safeCode: "self_test_failed",
                    ownerMessage:
                        "The local model test stopped with an unclassified, privacy-safe failure. No transaction was stored.",
                    isRetryable: false
                )
            )
        }
    }

    private static func makeResult(
        outcome: ModelSelfTestOutcome,
        startedAt: Date,
        parser: any TransactionParsing,
        timeout: Duration,
        receivedAt: Date,
        exactRequest: String,
        parserDraft: ParsedAlertDraft?,
        validationOutcome: ModelSelfTestValidationOutcome,
        validationSafeCode: String,
        validationMessage: String,
        validatedDraft: ValidatedTransactionDraft?,
        failure: ModelSelfTestFailure?
    ) -> ModelSelfTestResult {
        let completedAt = Date()
        let requestMetadata = parser.requestMetadata
        return ModelSelfTestResult(
            id: UUID(),
            outcome: outcome,
            startedAt: startedAt,
            completedAt: completedAt,
            elapsed: max(0, completedAt.timeIntervalSince(startedAt)),
            parserName: parser.parserName,
            contractVersion: FoundationModelExtractionContract.contractVersion,
            profileVersion: FoundationModelExtractionContract.extractionProfileVersion,
            localeIdentifier: requestMetadata.localeIdentifier,
            localeWasSupported: requestMetadata.localeWasSupported,
            supportedLanguageIdentifiers: requestMetadata.supportedLanguageIdentifiers,
            requestDeadline: durationDescription(timeout),
            scheduling: FoundationModelExtractionContract.requestSchedulingDescription,
            guardrails: FoundationModelExtractionContract.guardrailsDescription,
            exactInstructions: FoundationModelExtractionContract.instructions,
            exactRequest: exactRequest,
            syntheticBody: syntheticBody,
            syntheticSender: syntheticSender,
            receivedAt: receivedAt,
            parserDraft: parserDraft,
            validationOutcome: validationOutcome,
            validationSafeCode: validationSafeCode,
            validationMessage: validationMessage,
            validatedDraft: validatedDraft,
            failure: failure,
            apiLimitations: apiLimitations
        )
    }

    private static func parseWithDeadline(
        parser: any TransactionParsing,
        receivedAt: Date,
        timeout: Duration
    ) async throws -> ParsedAlertDraft {
        try await withThrowingTaskGroup(of: ParsedAlertDraft.self) { group in
            group.addTask {
                try await parser.parse(
                    body: syntheticBody,
                    sender: syntheticSender,
                    receivedAt: receivedAt
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransactionParserError.timedOut
            }

            guard let first = try await group.next() else {
                throw TransactionParserError.generationFailed
            }
            group.cancelAll()
            return first
        }
    }

    private static func matchesExpectedSyntheticTransaction(
        _ validated: ValidatedTransactionDraft
    ) -> Bool {
        validated.amountMinorUnits == 50_000
            && validated.currencyCode == "INR"
            && validated.direction == .debit
            && hasGroundedAccountSuffix(validated.accountLabel)
    }

    private static func hasGroundedAccountSuffix(_ accountLabel: String) -> Bool {
        let digits = accountLabel.filter(\.isNumber)
        return digits.suffix(4) == "0000"
            && syntheticBody.range(of: accountLabel, options: [.caseInsensitive, .literal]) != nil
    }

    private static func durationDescription(_ duration: Duration) -> String {
        if duration == FoundationModelExtractionContract.timeout {
            return FoundationModelExtractionContract.timeoutDescription
        }

        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        if seconds >= 1, seconds.rounded() == seconds {
            let wholeSeconds = Int(seconds)
            return "\(wholeSeconds) \(wholeSeconds == 1 ? "second" : "seconds")"
        }
        return String(format: "%.3f seconds", seconds)
    }

    private static func evidenceFailureMessage(for issue: EvidenceValidationIssue) -> String {
        switch issue {
        case .modelRejected:
            "The draft classified the synthetic completed debit as non-financial."
        case .explicitlyUnsuccessfulTransaction:
            "The synthetic alert unexpectedly contained failed or negated transaction wording."
        case .invalidDirection:
            "The draft direction was neither debit nor credit."
        case .directionNotGrounded:
            "The draft direction was not supported by wording in the synthetic alert."
        case .amountNotGrounded:
            "The draft amount was not copied exactly from the synthetic alert."
        case .amountCandidateMismatch:
            "The draft amount did not match the plausible transaction amount in the synthetic alert."
        case .ambiguousTransactionAmount:
            "The synthetic alert did not contain exactly one plausible transaction amount."
        case .invalidAmount:
            "The grounded amount could not be parsed safely into minor currency units."
        case .merchantNotGrounded:
            "The draft merchant was not copied exactly from the synthetic alert."
        case .accountNotGrounded:
            "The draft account label was missing or was not copied exactly from the synthetic alert."
        case .invalidAccountEvidence:
            "The draft account label did not contain a usable masked suffix."
        case .dateNotGrounded:
            "The draft date text was not copied exactly from the synthetic alert."
        case .invalidDate:
            "The grounded date text could not be parsed safely."
        }
    }

    private static func parserFailureMessage(
        for error: TransactionParserError,
        localeIdentifier: String
    ) -> String {
        switch error {
        case .modelUnavailable(.deviceNotEligible):
            "This device is not eligible for Apple's on-device Foundation Model."
        case .modelUnavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is off. Enable it and confirm that the iPhone and Siri languages match a model-supported language."
        case .modelUnavailable(.modelNotReady):
            "Apple reported modelNotReady. The public API does not expose download progress or a more specific cause; keep the iPhone on power and Wi-Fi, then try again."
        case .modelUnavailable(.unknown):
            "Apple reported an availability state this app does not recognize. No private cause is available to Pocket Financer."
        case .timedOut:
            "The on-device model did not finish within the local time limit."
        case .cancelled:
            "The on-device model test was interrupted. Try again while Pocket Financer remains open."
        case .assetsUnavailable:
            "Apple's local model assets are not ready. Keep this iPhone on Wi-Fi and power, then try again."
        case .unsupportedLanguageOrLocale:
            "The local model rejected the checked model locale \(localeIdentifier) or detected an unsupported input language. Confirm that the iPhone and Siri languages match a supported English language. The iPhone region can remain India."
        case .guardrailViolation:
            "Apple's local model safety system blocked the synthetic financial alert."
        case .unsupportedGuide:
            "The installed local model does not support part of Pocket Financer's extraction schema."
        case .decodingFailure:
            "The local model responded, but its structured extraction could not be decoded."
        case .rateLimited:
            "The local model is temporarily busy. Wait briefly, then try again."
        case .concurrentRequests:
            "Another local model request was already running. Try the test again."
        case .modelRefused:
            "Apple's local model declined the synthetic financial extraction request."
        case .contextWindowExceeded:
            "The synthetic test unexpectedly exceeded the local model's context limit."
        case .generationFailed:
            "The on-device model could not produce a structured extraction for the synthetic alert."
        }
    }
}
