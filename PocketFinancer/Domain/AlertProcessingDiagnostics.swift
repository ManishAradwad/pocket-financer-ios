import Foundation

struct ProcessingCodePresentation: Equatable, Sendable {
    let title: String
    let detail: String
}

enum AlertProcessingDiagnostics {
    static func statusTitle(_ status: AlertStatus) -> String {
        switch status {
        case .pending:
            "Saved for retry"
        case .processing:
            "Processing locally"
        case .imported:
            "Imported"
        case .needsReview:
            "Needs review"
        case .rejected:
            "Rejected deterministically"
        case .duplicate:
            "Duplicate"
        }
    }

    static func originTitle(_ origin: AlertOrigin) -> String {
        switch origin {
        case .shortcut:
            "Shortcut automation"
        case .manual:
            "Manual import"
        }
    }

    static func attemptDuration(
        lastAttemptAt: Date?,
        updatedAt: Date,
        status: AlertStatus
    ) -> TimeInterval? {
        guard status != .processing, let lastAttemptAt else { return nil }
        return max(0, updatedAt.timeIntervalSince(lastAttemptAt))
    }

    static func durationText(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "Under 1 second"
        }
        if duration < 60 {
            return String(format: "%.1f seconds", duration)
        }

        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)m \(seconds)s"
    }

    static func presentation(for code: String) -> ProcessingCodePresentation {
        switch code {
        case "model_appleIntelligenceNotEnabled":
            .init(
                title: "Apple Intelligence is disabled",
                detail: "The alert remains saved locally and can be retried after Apple Intelligence is enabled."
            )
        case "model_modelNotReady":
            .init(
                title: "Model is not ready",
                detail:
                    "Apple reports only modelNotReady, without download progress or a more specific public cause. The alert remains retryable."
            )
        case "model_assets_unavailable":
            .init(
                title: "Model assets unavailable",
                detail: "Apple's local assets were unavailable for this attempt; the alert remains retryable."
            )
        case "model_deviceNotEligible":
            .init(
                title: "Device is not eligible",
                detail: "This device cannot run the system language model, so the retained alert needs manual review."
            )
        case "model_unknown":
            .init(
                title: "Model unavailable",
                detail: "Apple reported an unrecognized availability state; the alert remains retryable."
            )
        case "model_timed_out":
            .init(
                title: "Attempt timed out",
                detail:
                    "Pocket Financer requested cancellation after 60 seconds. Apple's model may take additional time to release the local request."
            )
        case "model_cancelled":
            .init(
                title: "Attempt interrupted",
                detail: "Local processing was cancelled before a structured result was accepted."
            )
        case "model_rate_limited":
            .init(
                title: "Model temporarily busy",
                detail: "Apple rate-limited this local request; the alert remains retryable."
            )
        case "model_concurrent_requests":
            .init(
                title: "Another model request was active",
                detail: "The system rejected overlapping work; Pocket Financer serializes future requests."
            )
        case "model_unsupported_language":
            .init(
                title: "Language or locale unsupported",
                detail:
                    "Apple's model rejected the checked app locale or request language. Confirm that iPhone and Siri languages match a model-supported language; Apple does not identify which setting caused a mismatch."
            )
        case "model_guardrail_violation":
            .init(
                title: "Apple guardrail stopped generation",
                detail: "The system safety layer blocked this extraction. Pocket Financer did not accept a transaction."
            )
        case "model_refused":
            .init(
                title: "Model declined the request",
                detail: "Apple's model refused to produce the requested structured extraction."
            )
        case "model_unsupported_guide":
            .init(
                title: "Extraction schema unsupported",
                detail: "The installed model could not use part of Pocket Financer's guided output schema."
            )
        case "model_decoding_failed":
            .init(
                title: "Structured output could not be decoded",
                detail: "A response arrived, but it did not decode into the required transaction structure."
            )
        case "model_context_window_exceeded":
            .init(
                title: "Model context limit exceeded",
                detail: "The request exceeded the system model's available context window."
            )
        case "model_generation_failed":
            .init(
                title: "No structured extraction produced",
                detail: "The local model did not return a transaction structure that Pocket Financer could inspect."
            )
        case EvidenceValidationIssue.modelRejected.rawValue:
            .init(
                title: "Model classified this as non-financial",
                detail: "That model-only decision is untrusted, so the original evidence remains available for review."
            )
        case EvidenceValidationIssue.explicitlyUnsuccessfulTransaction.rawValue:
            .init(
                title: "Transaction was explicitly unsuccessful",
                detail:
                    "Failed, declined, unsuccessful, or negated wording prevented the model output from creating a transaction."
            )
        case EvidenceValidationIssue.invalidDirection.rawValue:
            .init(
                title: "Invalid direction",
                detail: "The output direction was neither debit nor credit."
            )
        case EvidenceValidationIssue.directionNotGrounded.rawValue:
            .init(
                title: "Direction was not grounded",
                detail: "The debit or credit direction was not supported by wording in the alert body."
            )
        case EvidenceValidationIssue.amountNotGrounded.rawValue:
            .init(
                title: "Amount was not grounded",
                detail: "The extracted amount was not copied exactly from the alert body."
            )
        case EvidenceValidationIssue.amountCandidateMismatch.rawValue:
            .init(
                title: "Amount was not the transaction value",
                detail:
                    "The selected amount did not match the one plausible transaction amount after balance and limit figures were excluded."
            )
        case EvidenceValidationIssue.ambiguousTransactionAmount.rawValue:
            .init(
                title: "Transaction amount was ambiguous",
                detail:
                    "The alert contained zero or multiple plausible transaction amounts, so no amount was accepted automatically."
            )
        case EvidenceValidationIssue.invalidAmount.rawValue:
            .init(
                title: "Amount was invalid",
                detail: "The grounded amount could not be parsed safely into minor currency units."
            )
        case EvidenceValidationIssue.merchantNotGrounded.rawValue:
            .init(
                title: "Merchant was not grounded",
                detail: "The extracted merchant or counterparty was not copied exactly from the alert body."
            )
        case EvidenceValidationIssue.accountNotGrounded.rawValue:
            .init(
                title: "Account was not grounded",
                detail: "The extracted account or card label was missing or not copied exactly from the alert body."
            )
        case EvidenceValidationIssue.invalidAccountEvidence.rawValue:
            .init(
                title: "Account evidence was too vague",
                detail:
                    "The extracted account or card text did not include at least three visible suffix digits, so it could not identify a usable local account."
            )
        case EvidenceValidationIssue.dateNotGrounded.rawValue:
            .init(
                title: "Date was not grounded",
                detail: "The extracted date text was not copied exactly from the alert body."
            )
        case EvidenceValidationIssue.invalidDate.rawValue:
            .init(
                title: "Date was invalid",
                detail: "The grounded date text could not be parsed safely."
            )
        case AlertRejectionCode.missingAmount.rawValue:
            .init(title: "No currency amount", detail: "The body did not contain an amount marked with Rs, INR, or ₹.")
        case AlertRejectionCode.missingAccount.rawValue:
            .init(
                title: "No account reference",
                detail: "The body did not contain a supported masked account or card reference.")
        case AlertRejectionCode.missingTransactionVerb.rawValue:
            .init(
                title: "No completed transaction wording",
                detail: "The body did not contain a supported completed-transaction verb.")
        case AlertRejectionCode.oneTimePassword.rawValue:
            .init(
                title: "OTP or verification alert",
                detail: "The deterministic filter found one-time password or verification-code wording.")
        case AlertRejectionCode.collectRequest.rawValue:
            .init(
                title: "Payment request",
                detail: "The deterministic filter found collect-request or mandate-request wording.")
        case AlertRejectionCode.promotion.rawValue:
            .init(
                title: "Promotional message",
                detail: "The deterministic filter found high-confidence offer or solicitation wording.")
        case AlertRejectionCode.unsuccessfulTransaction.rawValue:
            .init(
                title: "Unsuccessful transaction",
                detail:
                    "The deterministic filter found failed, declined, unsuccessful, or explicitly negated transaction wording."
            )
        case AlertRejectionCode.emptyBody.rawValue:
            .init(title: "Empty alert", detail: "No alert body was available to inspect.")
        case "persistence_failed":
            .init(
                title: "Local save failed",
                detail: "Pocket Financer could not finish a local database update for this attempt.")
        case "automatic_retry_limit_reached":
            .init(
                title: "Automatic retry limit reached",
                detail:
                    "Automatic processing stopped after three attempts. The retained alert can still be retried explicitly."
            )
        case "parser_failed":
            .init(title: "Parser failed", detail: "The parser stopped with an unclassified, privacy-safe failure.")
        case "validation_passed":
            .init(
                title: "Evidence validation passed",
                detail:
                    "The mapped parser draft was grounded against the retained alert before ledger fields were saved.")
        default:
            .init(
                title: "Recorded processing code",
                detail: "Pocket Financer retained this privacy-safe code for inspection.")
        }
    }
}
