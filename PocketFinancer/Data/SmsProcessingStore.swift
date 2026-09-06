import CryptoKit
import Foundation
import SwiftData

enum SmsProcessingStoreError: Error, Equatable, Sendable {
    case sourceNotFound
    case operationNotFound
    case reviewCaseNotFound
    case configurationMismatch
    case stateConflict
    case lostOwnership
    case revisionConflict
    case invalidCommand
    case saveFailed
}

struct SmsOperationClaim: Equatable, Sendable {
    let operationID: UUID
    let ownerToken: UUID
    let generation: Int64
    let expiresAt: Date
}

@ModelActor
actor SmsProcessingStore {
    static let claimLease: TimeInterval = 120

    func operation(id: UUID) throws -> SmsProcessingOperation? {
        let operationID = id
        return try modelContext.fetch(
            FetchDescriptor<SmsProcessingOperation>(predicate: #Predicate { $0.id == operationID })
        ).first
    }

    func claim(operationID: UUID, now: Date = .now) throws -> SmsOperationClaim {
        guard let operation = try operation(id: operationID) else {
            throw SmsProcessingStoreError.operationNotFound
        }
        if operation.settledAt != nil {
            throw SmsProcessingStoreError.stateConflict
        }
        if let ownerToken = operation.ownerToken,
            let expiresAt = operation.claimExpiresAt,
            expiresAt > now
        {
            return SmsOperationClaim(
                operationID: operationID,
                ownerToken: ownerToken,
                generation: operation.ownerGeneration,
                expiresAt: expiresAt
            )
        }
        let ownerToken = UUID()
        let expiresAt = now.addingTimeInterval(Self.claimLease)
        operation.ownerGeneration += 1
        operation.ownerToken = ownerToken
        operation.claimExpiresAt = expiresAt
        operation.state = .claimed
        operation.transitionSequence += 1
        operation.updatedAt = now
        try saveOrRollback()
        return SmsOperationClaim(
            operationID: operationID,
            ownerToken: ownerToken,
            generation: operation.ownerGeneration,
            expiresAt: expiresAt
        )
    }

    func heartbeat(_ claim: SmsOperationClaim, now: Date = .now) throws -> SmsOperationClaim {
        let operation = try requireOwned(claim, now: now)
        let expiresAt = now.addingTimeInterval(Self.claimLease)
        operation.claimExpiresAt = expiresAt
        operation.updatedAt = now
        try saveOrRollback()
        return SmsOperationClaim(
            operationID: claim.operationID,
            ownerToken: claim.ownerToken,
            generation: claim.generation,
            expiresAt: expiresAt
        )
    }

    func transition(
        _ claim: SmsOperationClaim,
        expected: SmsOperationState,
        to next: SmsOperationState,
        now: Date = .now
    ) throws {
        let operation = try requireOwned(claim, now: now)
        guard operation.state == expected else { throw SmsProcessingStoreError.stateConflict }
        operation.state = next
        operation.transitionSequence += 1
        operation.updatedAt = now
        try saveOrRollback()
    }

    func appendTrace(
        _ claim: SmsOperationClaim,
        stage: String,
        status: String,
        reasonCodes: [String] = [],
        detailJSON: String? = nil,
        now: Date = .now
    ) throws -> SmsTraceReceipt {
        _ = try requireOwned(claim, now: now)
        let operationID = claim.operationID
        let existing = try modelContext.fetch(
            FetchDescriptor<SmsProcessingTraceEvent>(
                predicate: #Predicate { $0.operationID == operationID },
                sortBy: [SortDescriptor(\.sequence)]
            )
        )
        let sequence = existing.count
        let previousHash = existing.last?.eventHash
        let eventID = UUID()
        let payload = TraceHashPayload(
            sequence: sequence,
            eventID: eventID.uuidString.lowercased(),
            occurredAtEpochMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded(.towardZero)),
            stage: stage,
            status: status,
            reasonCodes: reasonCodes,
            detailJSON: detailJSON,
            previousEventHash: previousHash
        )
        let event = SmsProcessingTraceEvent(
            id: eventID,
            operationID: operationID,
            sequence: sequence,
            occurredAt: now,
            stage: stage,
            status: status,
            reasonCodes: reasonCodes,
            detailJSON: detailJSON,
            previousEventHash: previousHash,
            eventHash: try CanonicalJSON.sha256(payload)
        )
        modelContext.insert(event)
        try saveOrRollback()
        return SmsTraceReceipt(eventID: eventID, sequence: sequence, eventHash: event.eventHash)
    }

    /// Idempotently records the exact stored state available for pre-V5 transactions.
    /// It deliberately does not claim that an edited row's original extraction is known.
    func backfillLegacyTransactions(now: Date = .now) throws {
        let transactions = try modelContext.fetch(FetchDescriptor<Transaction>())
        let snapshots = try modelContext.fetch(FetchDescriptor<SmsLegacyTransactionSnapshot>())
        let snapshottedIDs = Set(snapshots.map(\.transactionID))
        let revisions = try modelContext.fetch(FetchDescriptor<SmsTransactionRevision>())
        let revisionTransactionIDs = Set(revisions.map(\.transactionID))

        for transaction in transactions where !snapshottedIDs.contains(transaction.id) {
            modelContext.insert(SmsLegacyTransactionSnapshot(transaction: transaction, capturedAt: now))
            guard !revisionTransactionIDs.contains(transaction.id) else { continue }
            modelContext.insert(
                SmsTransactionRevision(
                    transactionID: transaction.id,
                    sourceAlertID: transaction.sourceAlertID,
                    stableEventID: transaction.id,
                    revision: 0,
                    previousRevisionID: nil,
                    operationID: nil,
                    feedbackActionID: nil,
                    amountMinorUnits: transaction.amountMinorUnits,
                    currencyCode: transaction.currencyCode,
                    currencyScale: CurrencyFormatter.supportedScales[
                        transaction.currencyCode.uppercased()
                    ],
                    direction: transaction.directionRawValue,
                    merchant: transaction.merchant,
                    accountID: transaction.accountID,
                    occurredAt: transaction.occurredAt,
                    provenance: "legacy_current_state_original_history_unknown",
                    isCurrentProjection: true,
                    createdAt: now
                )
            )
        }
        try saveOrRollback()
    }

    func retainForReview(
        _ claim: SmsOperationClaim,
        reasons: [String],
        now: Date = .now
    ) throws -> UUID {
        let operation = try requireOwned(claim, now: now)
        let operationID = claim.operationID
        let cases = try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate {
                    $0.currentOperationID == operationID
                })
        )
        let reviewCase: SmsReviewCase
        if let existing = cases.first {
            reviewCase = existing
        } else {
            reviewCase = SmsReviewCase(
                sourceAlertID: operation.sourceAlertID,
                currentOperationID: operationID,
                reasonCodes: reasons
            )
            modelContext.insert(reviewCase)
        }
        operation.state = .retainedReview
        operation.transitionSequence += 1
        operation.updatedAt = now
        operation.settledAt = now
        operation.settlementReceiptJSON = try CanonicalJSON.string(
            ReviewSettlement(reviewCaseID: reviewCase.id, reasons: reasons)
        )
        operation.ownerToken = nil
        operation.claimExpiresAt = nil
        try saveOrRollback()
        return reviewCase.id
    }

    func stop(operationID: UUID, now: Date = .now) throws -> StopReceipt {
        guard let operation = try operation(id: operationID) else {
            throw SmsProcessingStoreError.operationNotFound
        }
        if operation.settledAt != nil {
            return StopReceipt(
                operationID: operationID,
                state: operation.state,
                committed: operation.state == .persisted
            )
        }
        operation.ownerGeneration += 1
        operation.ownerToken = nil
        operation.claimExpiresAt = nil
        operation.state = .interrupted
        operation.transitionSequence += 1
        operation.updatedAt = now
        try saveOrRollback()
        return StopReceipt(operationID: operationID, state: .interrupted, committed: false)
    }

    func resolveReview(_ command: ReviewCommand, now: Date = .now) throws -> ReviewReceipt {
        let actionID = command.actionID
        if let replay = try modelContext.fetch(
            FetchDescriptor<SmsUserFeedbackEvent>(
                predicate: #Predicate {
                    $0.actionID == actionID
                })
        ).first {
            return ReviewReceipt(
                actionID: actionID,
                reviewCaseID: replay.reviewCaseID,
                resultingRevision: replay.resultingReviewRevision,
                replayed: true
            )
        }
        let reviewID = command.reviewCaseID
        guard
            let review = try modelContext.fetch(
                FetchDescriptor<SmsReviewCase>(predicate: #Predicate { $0.id == reviewID })
            ).first
        else {
            throw SmsProcessingStoreError.reviewCaseNotFound
        }
        guard review.revision == command.expectedRevision else {
            throw SmsProcessingStoreError.revisionConflict
        }
        guard validate(command) else { throw SmsProcessingStoreError.invalidCommand }
        let resultingRevision = command.expectedRevision + 1
        let previousEventHash = try latestFeedbackHash(reviewCaseID: reviewID)
        let correctionsJSON = try CanonicalJSON.string(command.corrections)
        let eventHash = try CanonicalJSON.sha256(
            FeedbackHashPayload(
                actionID: actionID.uuidString.lowercased(),
                reviewCaseID: reviewID.uuidString.lowercased(),
                operationID: review.currentOperationID.uuidString.lowercased(),
                expectedRevision: command.expectedRevision,
                resultingRevision: resultingRevision,
                action: command.kind.rawValue,
                correctionsJSON: correctionsJSON,
                retryConfiguration: command.retryConfiguration,
                previousEventHash: previousEventHash
            )
        )
        let feedback = SmsUserFeedbackEvent(
            actionID: actionID,
            reviewCaseID: reviewID,
            operationID: review.currentOperationID,
            transactionRevisionID: nil,
            expectedReviewRevision: command.expectedRevision,
            resultingReviewRevision: resultingRevision,
            action: command.kind.rawValue,
            actorClass: "user",
            correctionsJSON: correctionsJSON,
            retryConfiguration: command.retryConfiguration,
            previousEventHash: previousEventHash,
            eventHash: eventHash,
            createdAt: now
        )
        modelContext.insert(feedback)
        review.revision = resultingRevision
        review.updatedAt = now
        review.state =
            switch command.kind {
            case .confirm, .resolveMultipleEvents: .confirmed
            case .correct: .corrected
            case .reject: .rejected
            case .saveDraft: .draft
            case .retry: .waitingRetry
            }
        if command.kind == .saveDraft || command.kind == .correct {
            review.draftJSON = correctionsJSON
        }
        try saveOrRollback()
        return ReviewReceipt(
            actionID: actionID,
            reviewCaseID: reviewID,
            resultingRevision: resultingRevision,
            replayed: false
        )
    }

    private func requireOwned(
        _ claim: SmsOperationClaim,
        now: Date
    ) throws -> SmsProcessingOperation {
        guard let operation = try operation(id: claim.operationID) else {
            throw SmsProcessingStoreError.operationNotFound
        }
        guard operation.ownerToken == claim.ownerToken,
            operation.ownerGeneration == claim.generation,
            operation.claimExpiresAt.map({ $0 >= now }) == true,
            operation.settledAt == nil
        else {
            throw SmsProcessingStoreError.lostOwnership
        }
        return operation
    }

    private func latestFeedbackHash(reviewCaseID: UUID) throws -> String? {
        let targetID = reviewCaseID
        return try modelContext.fetch(
            FetchDescriptor<SmsUserFeedbackEvent>(
                predicate: #Predicate { $0.reviewCaseID == targetID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).first?.eventHash
    }

    private func validate(_ command: ReviewCommand) -> Bool {
        switch command.kind {
        case .correct:
            !command.corrections.isEmpty && command.retryConfiguration == nil
        case .saveDraft, .resolveMultipleEvents:
            command.retryConfiguration == nil
        case .retry:
            command.corrections.isEmpty
                && ["original", "current"].contains(command.retryConfiguration)
        case .confirm, .reject:
            command.corrections.isEmpty && command.retryConfiguration == nil
        }
    }

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw SmsProcessingStoreError.saveFailed
        }
    }
}

nonisolated private struct TraceHashPayload: Codable {
    let sequence: Int
    let eventID: String
    let occurredAtEpochMilliseconds: Int64
    let stage: String
    let status: String
    let reasonCodes: [String]
    let detailJSON: String?
    let previousEventHash: String?
}

nonisolated private struct ReviewSettlement: Codable {
    let reviewCaseID: UUID
    let reasons: [String]
}

nonisolated private struct FeedbackHashPayload: Codable {
    let actionID: String
    let reviewCaseID: String
    let operationID: String
    let expectedRevision: Int
    let resultingRevision: Int
    let action: String
    let correctionsJSON: String
    let retryConfiguration: String?
    let previousEventHash: String?
}
