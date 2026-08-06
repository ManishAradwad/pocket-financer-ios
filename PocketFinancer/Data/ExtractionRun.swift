import Foundation
import SwiftData

enum ExtractionValidationOutcome: String, CaseIterable, Sendable {
    case notPerformed = "not_performed"
    case passed
    case failed
}

enum ExtractionRunDisposition: String, CaseIterable, Sendable {
    case imported
    case queued
    case needsReview = "needs_review"
}

/// A local, owner-visible snapshot of one parser attempt.
///
/// `exactInstructions`, `exactRequest`, and the draft fields are sensitive financial
/// evidence. They belong only in the protected SwiftData store and must never be logged.
@Model
final class ExtractionRun {
    @Attribute(.unique) var id: UUID
    var alertID: UUID
    var attemptIndex: Int
    var startedAt: Date
    var responseReceivedAt: Date?
    var completedAt: Date?
    var parserName: String
    var contractVersion: String
    var profileVersion: String
    var localeIdentifier: String
    var localeWasSupported: Bool?
    var supportedLanguageIdentifiersRawValue: String
    var exactInstructions: String
    var exactRequest: String
    var draftClassificationRawValue: String?
    var draftDirection: String?
    var draftAmountText: String?
    var draftMerchant: String?
    var draftAccountLabel: String?
    var draftOccurredAtText: String?
    var draftCurrencyCode: String?
    var validationClassificationStateRawValue: String?
    var validationDirectionStateRawValue: String?
    var validationAmountStateRawValue: String?
    var validationMerchantStateRawValue: String?
    var validationAccountStateRawValue: String?
    var validationDateStateRawValue: String?
    var validationOutcomeRawValue: String?
    var safeResultCode: String?
    var terminalDispositionRawValue: String?
    var acceptedTransactionID: UUID?
    var acceptedAmountMinorUnits: Int64?
    var acceptedCurrencyCode: String?
    var acceptedDirectionRawValue: String?
    var acceptedMerchant: String?
    var acceptedAccountLabel: String?
    var acceptedOccurredAt: Date?
    var acceptedReviewStateRawValue: String?
    var acceptedAmountEvidenceText: String?
    var acceptedDateEvidenceText: String?

    init(
        id: UUID = UUID(),
        alertID: UUID,
        attemptIndex: Int,
        startedAt: Date,
        parserName: String,
        contractVersion: String,
        profileVersion: String,
        localeIdentifier: String,
        localeWasSupported: Bool? = nil,
        supportedLanguageIdentifiers: [String] = [],
        exactInstructions: String,
        exactRequest: String
    ) {
        self.id = id
        self.alertID = alertID
        self.attemptIndex = attemptIndex
        self.startedAt = startedAt
        self.parserName = parserName
        self.contractVersion = contractVersion
        self.profileVersion = profileVersion
        self.localeIdentifier = localeIdentifier
        self.localeWasSupported = localeWasSupported
        self.supportedLanguageIdentifiersRawValue = Array(Set(supportedLanguageIdentifiers))
            .sorted()
            .joined(separator: "\n")
        self.exactInstructions = exactInstructions
        self.exactRequest = exactRequest
    }

    var parserDraft: ParsedAlertDraft? {
        guard
            let classificationRawValue = draftClassificationRawValue,
            let classification = DraftClassification(rawValue: classificationRawValue),
            let direction = draftDirection,
            let amountText = draftAmountText,
            let merchant = draftMerchant,
            let accountLabel = draftAccountLabel,
            let occurredAtText = draftOccurredAtText,
            let currencyCode = draftCurrencyCode
        else {
            return nil
        }

        return ParsedAlertDraft(
            classification: classification,
            direction: direction,
            amountText: amountText,
            merchant: merchant,
            accountLabel: accountLabel,
            occurredAtText: occurredAtText,
            currencyCode: currencyCode
        )
    }

    var supportedLanguageIdentifiers: [String] {
        supportedLanguageIdentifiersRawValue
            .split(separator: "\n")
            .map(String.init)
    }

    var validationOutcome: ExtractionValidationOutcome? {
        validationOutcomeRawValue.flatMap(ExtractionValidationOutcome.init(rawValue:))
    }

    var terminalDisposition: ExtractionRunDisposition? {
        terminalDispositionRawValue.flatMap(ExtractionRunDisposition.init(rawValue:))
    }

    var acceptedDirection: TransactionDirection? {
        acceptedDirectionRawValue.flatMap(TransactionDirection.init(rawValue:))
    }

    var acceptedReviewState: ReviewState? {
        acceptedReviewStateRawValue.flatMap(ReviewState.init(rawValue:))
    }

    var totalDuration: TimeInterval? {
        completedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    var parserDuration: TimeInterval? {
        responseReceivedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    func recordParserDraft(_ draft: ParsedAlertDraft, receivedAt: Date) {
        guard responseReceivedAt == nil else { return }
        responseReceivedAt = receivedAt
        draftClassificationRawValue = draft.classification.rawValue
        draftDirection = draft.direction
        draftAmountText = draft.amountText
        draftMerchant = draft.merchant
        draftAccountLabel = draft.accountLabel
        draftOccurredAtText = draft.occurredAtText
        draftCurrencyCode = draft.currencyCode
    }

    func recordValidation(_ report: EvidenceValidationReport) {
        guard validationOutcomeRawValue == nil else { return }
        validationClassificationStateRawValue = report.state(for: .classification).rawValue
        validationDirectionStateRawValue = report.state(for: .direction).rawValue
        validationAmountStateRawValue = report.state(for: .amount).rawValue
        validationMerchantStateRawValue = report.state(for: .merchant).rawValue
        validationAccountStateRawValue = report.state(for: .account).rawValue
        validationDateStateRawValue = report.state(for: .date).rawValue
        validationOutcomeRawValue =
            report.validatedDraft == nil
            ? ExtractionValidationOutcome.failed.rawValue
            : ExtractionValidationOutcome.passed.rawValue
    }

    func recordValidationNotPerformed() {
        guard validationOutcomeRawValue == nil else { return }
        let notRun = EvidenceValidationStageState.notRun.rawValue
        validationClassificationStateRawValue = notRun
        validationDirectionStateRawValue = notRun
        validationAmountStateRawValue = notRun
        validationMerchantStateRawValue = notRun
        validationAccountStateRawValue = notRun
        validationDateStateRawValue = notRun
        validationOutcomeRawValue = ExtractionValidationOutcome.notPerformed.rawValue
    }

    func validationState(for stage: EvidenceValidationStage) -> EvidenceValidationStageState? {
        let rawValue: String?
        switch stage {
        case .classification:
            rawValue = validationClassificationStateRawValue
        case .direction:
            rawValue = validationDirectionStateRawValue
        case .amount:
            rawValue = validationAmountStateRawValue
        case .merchant:
            rawValue = validationMerchantStateRawValue
        case .account:
            rawValue = validationAccountStateRawValue
        case .date:
            rawValue = validationDateStateRawValue
        }
        return rawValue.flatMap(EvidenceValidationStageState.init(rawValue:))
    }

    func recordAcceptedTransaction(_ transaction: Transaction) {
        guard acceptedTransactionID == nil else { return }
        acceptedTransactionID = transaction.id
        acceptedAmountMinorUnits = transaction.amountMinorUnits
        acceptedCurrencyCode = transaction.currencyCode
        acceptedDirectionRawValue = transaction.direction.rawValue
        acceptedMerchant = transaction.merchant
        acceptedAccountLabel = transaction.accountLabel
        acceptedOccurredAt = transaction.occurredAt
        acceptedReviewStateRawValue = transaction.reviewState.rawValue
        acceptedAmountEvidenceText = transaction.amountEvidenceText
        acceptedDateEvidenceText = transaction.dateEvidenceText
    }

    func complete(
        safeResultCode: String,
        disposition: ExtractionRunDisposition,
        at completedAt: Date
    ) {
        guard self.completedAt == nil else { return }
        self.safeResultCode = safeResultCode
        self.terminalDispositionRawValue = disposition.rawValue
        self.completedAt = completedAt
    }
}
