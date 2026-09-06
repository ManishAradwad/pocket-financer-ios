import CryptoKit
import Foundation

struct AdmittedMessageRef: Codable, Equatable, Sendable {
    let sourceID: UUID
    let admissionReceiptID: UUID
    let sourceDigest: String
}

struct SmsOperationConfiguration: Codable, Equatable, Sendable {
    static let releaseID = "native-integration-v1"

    let contract: String
    let releaseID: String
    let operationID: UUID
    let parentOperationID: UUID?
    let sourceID: UUID
    let trigger: String
    let createdAtEpochMilliseconds: Int64
    let primaryCurrency: String
    let enabledProfiles: [String]
    let sourceTimestampEpochMilliseconds: Int64?
    let sourceTimestampProvenance: String
    let admissionTimestampEpochMilliseconds: Int64
    let timezoneIdentifier: String
    let analyzerVersion: String
    let unicodeVersion: String
    let selectorModelIdentifier: String
    let selectorRuntimeVersion: String
    let promptVersion: String
    let validationProfile: String
    let persistencePolicy: String
    let rolloutMode: String
    let generationMode: String
    let decoding: String
    let answerTokenLimit: Int
    let rawOutputByteLimit: Int
    let parserDeadlineMilliseconds: Int

    init(
        operationID: UUID,
        parentOperationID: UUID? = nil,
        sourceID: UUID,
        trigger: String,
        createdAt: Date,
        primaryCurrency: String,
        enabledProfiles: [String],
        sourceTimestamp: Date?,
        sourceTimestampProvenance: String,
        admissionTimestamp: Date,
        timezoneIdentifier: String,
        selectorModelIdentifier: String,
        selectorRuntimeVersion: String
    ) {
        contract = "pocketfinancer.processing-config/1"
        releaseID = Self.releaseID
        self.operationID = operationID
        self.parentOperationID = parentOperationID
        self.sourceID = sourceID
        self.trigger = trigger
        createdAtEpochMilliseconds = createdAt.epochMilliseconds
        self.primaryCurrency = primaryCurrency.uppercased()
        self.enabledProfiles = enabledProfiles.sorted()
        sourceTimestampEpochMilliseconds = sourceTimestamp?.epochMilliseconds
        self.sourceTimestampProvenance = sourceTimestampProvenance
        admissionTimestampEpochMilliseconds = admissionTimestamp.epochMilliseconds
        self.timezoneIdentifier = timezoneIdentifier
        analyzerVersion = "pocketfinancer.structural-sms-analyzer/2"
        unicodeVersion = "14.0.0"
        self.selectorModelIdentifier = selectorModelIdentifier
        self.selectorRuntimeVersion = selectorRuntimeVersion
        promptVersion = "pocketfinancer.selector-prompt/1"
        validationProfile = "pocketfinancer.selector-validation-profile/2"
        persistencePolicy = "pocketfinancer.persistence-policy/1"
        rolloutMode = "shadow"
        generationMode = "DIRECT_NON_THINKING"
        decoding = "greedy"
        answerTokenLimit = 512
        rawOutputByteLimit = 16_384
        parserDeadlineMilliseconds = 60_000
    }

    var canonicalJSON: String {
        get throws { try CanonicalJSON.string(self) }
    }

    var sha256: String {
        get throws { try CanonicalJSON.sha256(self) }
    }
}

struct SmsOperationSnapshot: Equatable, Sendable {
    let operationID: UUID
    let parentOperationID: UUID?
    let stableEventID: UUID
    let configuration: SmsOperationConfiguration
    let configurationJSON: String
    let configurationHash: String
}

enum SmsProcessingOutcome: Equatable, Sendable {
    case terminallyDiscarded(operationID: UUID, reason: String)
    case retainedForReview(operationID: UUID, reviewCaseID: UUID, reasons: [String])
    case persisted(operationID: UUID, transactionIDs: [UUID], alreadyCommitted: Bool)
    case retryableFailure(operationID: UUID, reviewCaseID: UUID, reason: String)
    case stopped(operationID: UUID, reviewCaseID: UUID, reason: String)
}

struct StopReceipt: Equatable, Sendable {
    let operationID: UUID
    let state: SmsOperationState
    let committed: Bool
}

enum SmsFieldGroundingClassification: String, Codable, Sendable {
    case selectedExistingCandidate = "selected_existing_candidate"
    case changedInterpretationAmongCandidates = "changed_interpretation_among_candidates"
    case suppliedSourceSupportedCandidateMiss = "supplied_source_supported_candidate_miss"
    case suppliedManualUngroundedValue = "supplied_manual_ungrounded_value"
}

struct SmsFieldCorrection: Codable, Equatable, Sendable {
    let field: String
    let classification: SmsFieldGroundingClassification
    let previousRevisionID: UUID?
    let candidateID: String?
    let evidence: SmsEvidenceSpan?
    let newValue: String
}

enum ReviewCommandKind: String, Codable, Sendable {
    case confirm
    case correct
    case reject
    case resolveMultipleEvents = "resolve_multiple_events"
    case saveDraft = "save_draft"
    case retry
}

struct ReviewCommand: Codable, Equatable, Sendable {
    let actionID: UUID
    let reviewCaseID: UUID
    let expectedRevision: Int
    let kind: ReviewCommandKind
    let corrections: [SmsFieldCorrection]
    let retryConfiguration: String?
}

struct ReviewReceipt: Equatable, Sendable {
    let actionID: UUID
    let reviewCaseID: UUID
    let resultingRevision: Int
    let replayed: Bool
}

enum SmsCandidateKind: String, Codable, Sendable {
    case amount
    case direction
    case account
    case counterparty
}

struct SmsEvidenceSpan: Codable, Equatable, Sendable {
    let startCharacter: Int
    let endCharacter: Int
    let startUTF8: Int
    let endUTF8: Int
    let text: String
}

struct SmsCandidate: Codable, Equatable, Sendable {
    let id: String
    let kind: SmsCandidateKind
    let clauseID: String?
    let evidence: SmsEvidenceSpan?
    let explicitlyAbsent: Bool
    let value: [String: String]
}

struct SmsClause: Codable, Equatable, Sendable {
    let id: String
    let evidence: SmsEvidenceSpan
    let states: [String]
    let financialFamilies: [String]
}

struct SmsAnalysis: Codable, Equatable, Sendable {
    let contract: String
    let analysisID: String
    let configurationHash: String
    let sourceHash: String
    let source: String
    let clauses: [SmsClause]
    let candidates: [SmsCandidate]
    let reasonCodes: [String]
    let completedEventCount: Int
}

enum SelectorDecision: String, Codable, Sendable {
    case none
    case abstain
    case posted
}

struct SelectorPostedSelection: Codable, Equatable, Sendable {
    let amountCandidateID: String
    let directionCandidateID: String
    let accountCandidateID: String
    let counterpartyCandidateID: String
}

struct GroundedSelectorResult: Codable, Equatable, Sendable {
    let decision: SelectorDecision
    let posted: SelectorPostedSelection?
}

enum PersistenceGateResult: String, Codable, Sendable {
    case eligible
    case reviewRequired = "review_required"
    case notPosted = "not_posted"
    case multipleEvents = "multiple_events"
    case blockedByMode = "blocked_by_mode"
    case invalidOperation = "invalid_operation"
}

struct PersistenceGateCheck: Codable, Equatable, Sendable {
    let check: String
    let passed: Bool
    let reasonCode: String?
}

struct PersistenceGateDecision: Codable, Equatable, Sendable {
    let result: PersistenceGateResult
    let primaryReason: String
    let checks: [PersistenceGateCheck]
}

protocol SmsProcessingObserver: Sendable {
    func didReceive(_ event: SmsProcessingObserverEvent) async
}

struct SmsProcessingObserverEvent: Equatable, Sendable {
    let operationID: UUID
    let sequence: Int
    let stage: String
    let status: String
    let reasonCodes: [String]
}

struct SmsTraceReceipt: Equatable, Sendable {
    let eventID: UUID
    let sequence: Int
    let eventHash: String
}

struct NoOpSmsProcessingObserver: SmsProcessingObserver {
    func didReceive(_: SmsProcessingObserverEvent) async {}
}

enum CanonicalJSON {
    nonisolated static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    nonisolated static func string<T: Encodable>(_ value: T) throws -> String {
        guard let result = String(data: try data(value), encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return result
    }

    nonisolated static func sha256<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try data(value)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Date {
    fileprivate nonisolated var epochMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }
}
