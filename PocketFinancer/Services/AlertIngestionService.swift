import Foundation
import SwiftData

enum IngestionDisposition: String, Sendable {
    case imported
    case queued
    case alreadyProcessing = "already_processing"
    case processingIncomplete = "processing_incomplete"
    case needsReview
    case rejected
    case duplicate
}

struct IngestionReceipt: Equatable, Sendable {
    let alertID: UUID
    let disposition: IngestionDisposition

    nonisolated var safeDialog: String {
        switch disposition {
        case .imported:
            "Transaction imported locally."
        case .queued:
            "Alert saved locally for processing later."
        case .alreadyProcessing:
            "This saved alert is already being processed locally. No second model attempt was started."
        case .processingIncomplete:
            "Alert saved locally, but processing did not finish. Its evidence remains available for retry."
        case .needsReview:
            "Alert saved and marked for review."
        case .rejected:
            "Alert checked locally. No transaction was added."
        case .duplicate:
            "Alert already received. No duplicate transaction was added."
        }
    }
}

enum AlertIngestionError: Error, Equatable {
    case alertNotFound
    case inputTooLarge
    case persistenceFailed
    case storeUnavailable
}

@MainActor
final class AlertIngestionService {
    static let duplicateWindow: TimeInterval = 15
    static let automaticAttemptLimit = 3
    static let maximumBodyBytes = 16_384
    static let maximumSenderBytes = 512
    static let maximumSourceApplicationBytes = 256

    private let context: ModelContext
    private var cachedParser: (any TransactionParsing)?
    private var parserLoadTask: Task<any TransactionParsing, Never>?
    private let parserFactory: @Sendable () async -> any TransactionParsing
    private let filter: AlertFilter
    private let validator: EvidenceValidator
    private let parserTimeout: Duration
    private let contextSaver: @MainActor (ModelContext) throws -> Void

    /// Main-actor reentrancy permits another service instance to enter while a parser
    /// request is suspended. A process-wide token prevents a second attempt for the same
    /// durable alert. The epoch invalidates both active claims and queue batches captured
    /// before an owner erase. These values intentionally reset after process restart so a
    /// persisted `.processing` alert can be recovered.
    private struct ProcessingClaim: Equatable, Sendable {
        let token: UUID
        let epoch: UInt64
    }

    private struct OwnerState: Equatable {
        let alertUpdatedAt: Date
        let transactionID: UUID?
        let transactionUpdatedAt: Date?
        let transactionWasEdited: Bool?
    }

    private static var processingClaims: [UUID: ProcessingClaim] = [:]
    private static var processingEpoch: UInt64 = 0

    init(
        context: ModelContext,
        parser: (any TransactionParsing)? = nil,
        parserFactory: @escaping @Sendable () async -> any TransactionParsing = {
            await FoundationModelTransactionParser.loadDefault()
        },
        filter: AlertFilter = AlertFilter(),
        validator: EvidenceValidator = EvidenceValidator(),
        parserTimeout: Duration = FoundationModelExtractionContract.timeout,
        contextSaver: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        cachedParser = parser
        self.parserFactory = parserFactory
        self.filter = filter
        self.validator = validator
        self.parserTimeout = parserTimeout
        self.contextSaver = contextSaver
    }

    static func enqueueLive(
        body: String,
        sender: String?,
        receivedAt: Date?,
        sourceApplication: String?,
        origin: AlertOrigin,
        openDatabase: @MainActor () async throws -> AppDatabase = {
            try await AppDatabase.openShared()
        }
    ) async throws -> IngestionReceipt {
        let database: AppDatabase
        do {
            database = try await openDatabase()
            try database.refreshFileProtection()
        } catch {
            throw AlertIngestionError.storeUnavailable
        }

        let service = AlertIngestionService(context: database.container.mainContext)
        return try service.enqueue(
            body: body,
            sender: sender,
            receivedAt: receivedAt,
            sourceApplication: sourceApplication,
            origin: origin
        )
    }

    static func ingestLive(
        body: String,
        sender: String?,
        receivedAt: Date?,
        sourceApplication: String?,
        origin: AlertOrigin,
        openDatabase: @MainActor () async throws -> AppDatabase = {
            try await AppDatabase.openShared()
        }
    ) async throws -> IngestionReceipt {
        let database: AppDatabase
        do {
            database = try await openDatabase()
            try database.refreshFileProtection()
        } catch {
            throw AlertIngestionError.storeUnavailable
        }

        return try await AlertIngestionService(context: database.container.mainContext).ingest(
            body: body,
            sender: sender,
            receivedAt: receivedAt,
            sourceApplication: sourceApplication,
            origin: origin
        )
    }

    /// Durably saves or deduplicates an alert without filtering or invoking the model.
    /// This is the complete background App Intent boundary.
    func enqueue(
        body: String,
        sender: String?,
        receivedAt: Date?,
        sourceApplication: String?,
        origin: AlertOrigin
    ) throws -> IngestionReceipt {
        let resolvedSender = sender ?? ""
        let resolvedDate = receivedAt ?? .now
        guard
            body.utf8.count <= Self.maximumBodyBytes,
            resolvedSender.utf8.count <= Self.maximumSenderBytes,
            (sourceApplication?.utf8.count ?? 0) <= Self.maximumSourceApplicationBytes
        else {
            throw AlertIngestionError.inputTooLarge
        }
        let digest = AlertSourceIdentity.contentDigest(sender: resolvedSender, body: body)
        let sourceIdentity = AlertSourceIdentity.fingerprint(
            sender: resolvedSender,
            body: body,
            receivedAt: resolvedDate,
            sourceApplication: sourceApplication
        )

        let duplicate = try findDuplicate(contentDigest: digest, receivedAt: resolvedDate)
        let alert = InboxAlert(
            sourceIdentity: sourceIdentity,
            contentDigest: digest,
            origin: origin,
            sourceApplication: sourceApplication,
            sender: resolvedSender,
            rawBody: body,
            receivedAt: resolvedDate
        )
        context.insert(alert)

        if let duplicate {
            alert.status = .duplicate
            alert.duplicateOfAlertID = duplicate.id
            alert.eraseSensitiveEvidence()
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .duplicate)
        }

        // This is the crash-recovery boundary: evidence is committed before filtering
        // or model work, and a successful return always means it can be processed later.
        try save()
        return IngestionReceipt(alertID: alert.id, disposition: .queued)
    }

    func ingest(
        body: String,
        sender: String?,
        receivedAt: Date?,
        sourceApplication: String?,
        origin: AlertOrigin
    ) async throws -> IngestionReceipt {
        let queued = try enqueue(
            body: body,
            sender: sender,
            receivedAt: receivedAt,
            sourceApplication: sourceApplication,
            origin: origin
        )
        guard queued.disposition == .queued, let alert = try findAlert(id: queued.alertID) else {
            return queued
        }

        do {
            return try await classifyAndProcessIfClaimed(alert, allowBeyondAutomaticAttemptLimit: true)
                ?? queued
        } catch {
            // The enqueue save already succeeded. Never tell the foreground owner that
            // evidence was not saved merely because a later processing save failed.
            return IngestionReceipt(alertID: queued.alertID, disposition: .processingIncomplete)
        }
    }

    func retry(alertID: UUID) async throws -> IngestionReceipt {
        guard let alert = try findAlert(id: alertID) else { throw AlertIngestionError.alertNotFound }
        guard !alert.rawBody.isEmpty else {
            return IngestionReceipt(alertID: alert.id, disposition: .rejected)
        }
        do {
            return try await classifyAndProcessIfClaimed(alert, allowBeyondAutomaticAttemptLimit: true)
                ?? IngestionReceipt(alertID: alert.id, disposition: .alreadyProcessing)
        } catch {
            return IngestionReceipt(alertID: alert.id, disposition: .processingIncomplete)
        }
    }

    @discardableResult
    func processPending(limit: Int = 8, includeNeedsReview: Bool = false) async -> Int {
        guard limit > 0 else { return 0 }
        let batchEpoch = Self.processingEpoch
        let pendingStatus = AlertStatus.pending.rawValue
        let processingStatus = AlertStatus.processing.rawValue
        let predicate: Predicate<InboxAlert>
        if includeNeedsReview {
            let importedStatus = AlertStatus.imported.rawValue
            let rejectedStatus = AlertStatus.rejected.rawValue
            let duplicateStatus = AlertStatus.duplicate.rawValue
            predicate = #Predicate { alert in
                alert.statusRawValue != importedStatus
                    && alert.statusRawValue != rejectedStatus
                    && alert.statusRawValue != duplicateStatus
                    && alert.rawBody != ""
            }
        } else {
            predicate = #Predicate { alert in
                (alert.statusRawValue == pendingStatus
                    || alert.statusRawValue == processingStatus)
                    && alert.rawBody != ""
            }
        }
        var descriptor = FetchDescriptor<InboxAlert>(
            predicate: predicate,
            sortBy: [SortDescriptor(\InboxAlert.createdAt)]
        )
        descriptor.fetchLimit = limit
        guard let alerts = try? context.fetch(descriptor) else { return 0 }
        let eligibleAlertIDs = alerts.map(\.id)

        var completed = 0
        for alertID in eligibleAlertIDs {
            guard !Task.isCancelled, Self.processingEpoch == batchEpoch else { break }
            guard let alert = try? findAlert(id: alertID) else { continue }
            do {
                if try await classifyAndProcessIfClaimed(
                    alert,
                    allowBeyondAutomaticAttemptLimit: includeNeedsReview,
                    expectedProcessingEpoch: batchEpoch
                ) != nil {
                    completed += 1
                }
            } catch {
                guard
                    Self.processingEpoch == batchEpoch,
                    let durableAlert = try? findAlert(id: alertID)
                else { break }
                durableAlert.status = .pending
                durableAlert.lastErrorCode = "persistence_failed"
                durableAlert.updatedAt = .now
                try? save()
            }
        }
        return completed
    }

    private func classifyAndProcessIfClaimed(
        _ alert: InboxAlert,
        allowBeyondAutomaticAttemptLimit: Bool,
        expectedProcessingEpoch: UInt64? = nil
    ) async throws -> IngestionReceipt? {
        let alertID = alert.id
        guard
            let preflightAlert = try findAlert(id: alertID),
            !Task.isCancelled,
            Self.canProcess(
                preflightAlert,
                allowNeedsReview: allowBeyondAutomaticAttemptLimit
            )
        else { return nil }
        let ownerStateAtEntry = try ownerState(for: preflightAlert)

        var preparedParser: (any TransactionParsing)?
        let isWithinAttemptLimit =
            allowBeyondAutomaticAttemptLimit
            || preflightAlert.attemptCount < Self.automaticAttemptLimit
        if isWithinAttemptLimit,
            filter.trace(sender: preflightAlert.sender, body: preflightAlert.rawBody).result.isEligible
        {
            // Parser discovery can be slow on a physical device. Do it before acquiring
            // the per-alert claim so a cancelled scene task cannot block the replacement
            // active-scene drain from retrying this durable alert.
            preparedParser = await resolveParser()
            guard !Task.isCancelled else {
                return IngestionReceipt(alertID: alertID, disposition: .queued)
            }
        }

        guard
            let currentAlert = try findAlert(id: alertID),
            !Task.isCancelled
        else { return nil }
        guard try ownerState(for: currentAlert) == ownerStateAtEntry else {
            return IngestionReceipt(
                alertID: alertID,
                disposition: Self.currentDisposition(for: currentAlert)
            )
        }
        guard
            Self.canProcess(
                currentAlert,
                allowNeedsReview: allowBeyondAutomaticAttemptLimit
            )
        else { return nil }
        guard
            let claim = Self.acquireClaim(
                for: alertID,
                expectedProcessingEpoch: expectedProcessingEpoch
            )
        else { return nil }
        defer { Self.releaseClaim(for: alertID, claim: claim) }

        if !allowBeyondAutomaticAttemptLimit,
            currentAlert.attemptCount >= Self.automaticAttemptLimit
        {
            currentAlert.status = .needsReview
            currentAlert.lastErrorCode = "automatic_retry_limit_reached"
            currentAlert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: currentAlert.id, disposition: .needsReview)
        }

        let filterTrace = filter.trace(sender: currentAlert.sender, body: currentAlert.rawBody)
        let filterResult = filterTrace.result
        switch filterResult.decision {
        case .eligible:
            guard let preparedParser else {
                return IngestionReceipt(alertID: currentAlert.id, disposition: .queued)
            }
            let filterRun = try makeFilterRun(trace: filterTrace, alertID: currentAlert.id)
            context.insert(filterRun)
            // Commit the exact deterministic decision before model work starts.
            try save()
            return try await process(
                currentAlert,
                parser: preparedParser,
                claim: claim,
                filterRun: filterRun
            )
        case .rejectAndErase:
            let filterRun = try makeFilterRun(trace: filterTrace, alertID: currentAlert.id)
            context.insert(filterRun)
            reject(
                currentAlert,
                code: filterResult.rejectionCode?.rawValue ?? AlertRejectionCode.emptyBody.rawValue
            )
            try save()
            return IngestionReceipt(alertID: currentAlert.id, disposition: .rejected)
        case .needsReview:
            let filterRun = try makeFilterRun(trace: filterTrace, alertID: currentAlert.id)
            context.insert(filterRun)
            currentAlert.status = .needsReview
            currentAlert.rejectionCode = nil
            currentAlert.lastErrorCode =
                filterResult.rejectionCode?.rawValue ?? AlertRejectionCode.missingTransactionVerb.rawValue
            currentAlert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: currentAlert.id, disposition: .needsReview)
        }
    }

    private func process(
        _ alert: InboxAlert,
        parser: any TransactionParsing,
        claim: ProcessingClaim,
        filterRun: DeterministicFilterRun
    ) async throws -> IngestionReceipt {
        let alertID = alert.id
        let transactionAtStart = try findTransaction(for: alert)
        if let transactionAtStart, transactionAtStart.isEdited {
            alert.status = .imported
            alert.lastErrorCode = nil
            alert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .imported)
        }

        let transactionIDAtStart = transactionAtStart?.id
        let transactionUpdatedAtAtStart = transactionAtStart?.updatedAt

        let startedAt = Date.now
        alert.status = .processing
        alert.attemptCount += 1
        alert.lastAttemptAt = startedAt
        alert.updatedAt = startedAt
        alert.lastErrorCode = nil
        alert.parserName = parser.parserName
        let requestMetadata = parser.requestMetadata
        let extractionRun = ExtractionRun(
            alertID: alert.id,
            attemptIndex: alert.attemptCount,
            startedAt: startedAt,
            parserName: parser.parserName,
            contractVersion: FoundationModelExtractionContract.contractVersion,
            profileVersion: FoundationModelExtractionContract.extractionProfileVersion,
            localeIdentifier: requestMetadata.localeIdentifier,
            localeWasSupported: requestMetadata.localeWasSupported,
            supportedLanguageIdentifiers: requestMetadata.supportedLanguageIdentifiers,
            exactInstructions: FoundationModelExtractionContract.instructions,
            exactRequest: FoundationModelExtractionContract.requestPrompt(
                body: alert.rawBody,
                receivedAt: alert.receivedAt
            )
        )
        filterRun.extractionRunID = extractionRun.id
        context.insert(extractionRun)
        try save()

        let draft: ParsedAlertDraft
        do {
            draft = try await parseWithDeadline(
                parser: parser,
                body: alert.rawBody,
                sender: alert.sender,
                receivedAt: alert.receivedAt,
                extractionRunID: extractionRun.id,
                alertID: alertID,
                claim: claim
            )
            if Task.isCancelled {
                throw TransactionParserError.cancelled
            }
        } catch let error as TransactionParserError {
            guard Self.ownsClaim(for: alertID, claim: claim) else {
                return IngestionReceipt(alertID: alertID, disposition: .processingIncomplete)
            }
            if let preserved = try preserveOwnerChangeIfNeeded(
                alert: alert,
                transactionIDAtStart: transactionIDAtStart,
                transactionUpdatedAtAtStart: transactionUpdatedAtAtStart,
                extractionRun: extractionRun
            ) {
                return preserved
            }
            let completedAt = Date.now
            alert.status = error.isRetryable ? .pending : .needsReview
            alert.lastErrorCode = error.safeCode
            alert.updatedAt = completedAt
            extractionRun.recordValidationNotPerformed()
            extractionRun.complete(
                safeResultCode: error.safeCode,
                disposition: error.isRetryable ? .queued : .needsReview,
                at: completedAt
            )
            try save()
            return IngestionReceipt(
                alertID: alert.id,
                disposition: error.isRetryable ? .queued : .needsReview
            )
        } catch let error as AlertIngestionError {
            guard Self.ownsClaim(for: alertID, claim: claim) else {
                return IngestionReceipt(alertID: alertID, disposition: .processingIncomplete)
            }
            if let preserved = try preserveOwnerChangeIfNeeded(
                alert: alert,
                transactionIDAtStart: transactionIDAtStart,
                transactionUpdatedAtAtStart: transactionUpdatedAtAtStart,
                extractionRun: extractionRun
            ) {
                return preserved
            }
            // The attempt and source evidence were committed before generation. If an
            // observable model snapshot cannot be committed, stop before validation or
            // ledger mutation and leave the durable processing record recoverable.
            throw error
        } catch {
            guard Self.ownsClaim(for: alertID, claim: claim) else {
                return IngestionReceipt(alertID: alertID, disposition: .processingIncomplete)
            }
            if let preserved = try preserveOwnerChangeIfNeeded(
                alert: alert,
                transactionIDAtStart: transactionIDAtStart,
                transactionUpdatedAtAtStart: transactionUpdatedAtAtStart,
                extractionRun: extractionRun
            ) {
                return preserved
            }
            let completedAt = Date.now
            let safeCode =
                Task.isCancelled
                ? TransactionParserError.cancelled.safeCode
                : "parser_failed"
            alert.status = .pending
            alert.lastErrorCode = safeCode
            alert.updatedAt = completedAt
            extractionRun.recordValidationNotPerformed()
            extractionRun.complete(
                safeResultCode: safeCode,
                disposition: .queued,
                at: completedAt
            )
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .queued)
        }

        // Only the process-wide claim owner may apply a response after this suspension.
        guard Self.ownsClaim(for: alertID, claim: claim) else {
            return IngestionReceipt(alertID: alertID, disposition: .processingIncomplete)
        }

        extractionRun.recordParserDraft(draft, receivedAt: .now)
        // Persist the parser response before evidence validation or ledger mutation.
        try save()

        let validationReport = validator.report(
            draft,
            body: alert.rawBody,
            receivedAt: alert.receivedAt
        )
        extractionRun.recordValidation(validationReport)
        // Persist every validation stage before mutating the accepted ledger state.
        try save()

        if let preserved = try preserveOwnerChangeIfNeeded(
            alert: alert,
            transactionIDAtStart: transactionIDAtStart,
            transactionUpdatedAtAtStart: transactionUpdatedAtAtStart,
            extractionRun: extractionRun
        ) {
            return preserved
        }

        switch validationReport.result {
        case .failure(let issue):
            let completedAt = Date.now
            alert.status = .needsReview
            alert.lastErrorCode = issue.rawValue
            alert.updatedAt = completedAt
            extractionRun.complete(
                safeResultCode: issue.rawValue,
                disposition: .needsReview,
                at: completedAt
            )
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .needsReview)

        case .success(let validated):
            let account = try resolveAccount(
                label: validated.accountLabel,
                sender: alert.sender,
                body: alert.rawBody
            )
            let transaction: Transaction
            if let existing = try findTransaction(for: alert) {
                existing.amountMinorUnits = validated.amountMinorUnits
                existing.currencyCode = validated.currencyCode
                existing.merchant = validated.merchant
                existing.occurredAt = validated.occurredAt
                existing.direction = validated.direction
                existing.accountID = account.id
                existing.accountLabel = account.name
                existing.parserName = parser.parserName
                existing.reviewState = validated.reviewState
                existing.amountEvidenceText = validated.amountEvidenceText
                existing.dateEvidenceText = validated.dateEvidenceText
                existing.updatedAt = .now
                transaction = existing
            } else {
                transaction = Transaction(
                    amountMinorUnits: validated.amountMinorUnits,
                    currencyCode: validated.currencyCode,
                    merchant: validated.merchant,
                    occurredAt: validated.occurredAt,
                    direction: validated.direction,
                    accountID: account.id,
                    accountLabel: account.name,
                    parserName: parser.parserName,
                    reviewState: validated.reviewState,
                    sourceAlertID: alert.id,
                    amountEvidenceText: validated.amountEvidenceText,
                    dateEvidenceText: validated.dateEvidenceText
                )
                context.insert(transaction)
            }
            alert.transactionID = transaction.id
            alert.status = validated.reviewState == .confirmed ? .imported : .needsReview
            alert.lastErrorCode = nil
            let completedAt = Date.now
            alert.updatedAt = completedAt
            extractionRun.recordAcceptedTransaction(transaction)
            extractionRun.complete(
                safeResultCode: "validation_passed",
                disposition: validated.reviewState == .confirmed ? .imported : .needsReview,
                at: completedAt
            )
            try save()
            return IngestionReceipt(
                alertID: alert.id,
                disposition: validated.reviewState == .confirmed ? .imported : .needsReview
            )
        }
    }

    private func resolveParser() async -> any TransactionParsing {
        if let cachedParser {
            return cachedParser
        }

        let loadTask: Task<any TransactionParsing, Never>
        if let parserLoadTask {
            loadTask = parserLoadTask
        } else {
            let parserFactory = self.parserFactory
            let newLoadTask = Task { await parserFactory() }
            parserLoadTask = newLoadTask
            loadTask = newLoadTask
        }

        let parser = await loadTask.value
        cachedParser = parser
        parserLoadTask = nil
        return parser
    }

    private func parseWithDeadline(
        parser: any TransactionParsing,
        body: String,
        sender: String,
        receivedAt: Date,
        extractionRunID: UUID,
        alertID: UUID,
        claim: ProcessingClaim
    ) async throws -> ParsedAlertDraft {
        try await withThrowingTaskGroup(of: ParsedAlertDraft.self) { group in
            group.addTask { [self] in
                try await parser.parse(
                    body: body,
                    sender: sender,
                    receivedAt: receivedAt
                ) { progress in
                    try await self.persist(
                        parserProgress: progress,
                        extractionRunID: extractionRunID,
                        alertID: alertID,
                        claim: claim
                    )
                }
            }
            group.addTask { [self] in
                try await Task.sleep(for: self.parserTimeout)
                throw TransactionParserError.timedOut
            }

            guard let first = try await group.next() else {
                throw TransactionParserError.generationFailed
            }
            group.cancelAll()
            return first
        }
    }

    private func persist(
        parserProgress: TransactionParserProgress,
        extractionRunID: UUID,
        alertID: UUID,
        claim: ProcessingClaim
    ) throws {
        guard !Task.isCancelled else { throw TransactionParserError.cancelled }
        guard Self.ownsClaim(for: alertID, claim: claim) else { return }
        guard case .generationSnapshot(let snapshot) = parserProgress else { return }

        let descriptor = FetchDescriptor<StructuredGenerationSnapshot>()
        if let existing = try context.fetch(descriptor).first(where: {
            $0.extractionRunID == extractionRunID
                && $0.sequenceIndex == snapshot.sequenceIndex
        }) {
            guard
                existing.rawContentJSON == snapshot.rawContentJSON,
                existing.isComplete == snapshot.isComplete,
                existing.formatIdentifier == snapshot.formatIdentifier
            else {
                throw AlertIngestionError.persistenceFailed
            }
            return
        }

        context.insert(
            StructuredGenerationSnapshot(
                extractionRunID: extractionRunID,
                sequenceIndex: snapshot.sequenceIndex,
                capturedAt: snapshot.capturedAt,
                rawContentJSON: snapshot.rawContentJSON,
                isComplete: snapshot.isComplete,
                formatIdentifier: snapshot.formatIdentifier
            )
        )
        try save()
    }

    private func findDuplicate(contentDigest: String, receivedAt: Date) throws -> InboxAlert? {
        let descriptor = FetchDescriptor<InboxAlert>(sortBy: [SortDescriptor(\InboxAlert.receivedAt, order: .reverse)])
        return try context.fetch(descriptor).first { candidate in
            candidate.contentDigest == contentDigest
                && candidate.status != .duplicate
                && abs(candidate.receivedAt.timeIntervalSince(receivedAt)) <= Self.duplicateWindow
        }
    }

    private func makeFilterRun(
        trace: AlertFilterTrace,
        alertID: UUID
    ) throws -> DeterministicFilterRun {
        let priorRuns = try context.fetch(FetchDescriptor<DeterministicFilterRun>())
        let persistedStages = trace.stages.map(PersistedAlertFilterStage.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stageData: Data
        do {
            stageData = try encoder.encode(persistedStages)
        } catch {
            throw AlertIngestionError.persistenceFailed
        }
        guard let stagesJSON = String(data: stageData, encoding: .utf8) else {
            throw AlertIngestionError.persistenceFailed
        }

        let decisionRawValue: String
        switch trace.result.decision {
        case .eligible:
            decisionRawValue = "eligible"
        case .needsReview:
            decisionRawValue = "needs_review"
        case .rejectAndErase:
            decisionRawValue = "reject_and_erase"
        }

        return DeterministicFilterRun(
            alertID: alertID,
            evaluationIndex: priorRuns.count { $0.alertID == alertID } + 1,
            evaluatedAt: .now,
            rulesVersion: AlertFilter.rulesVersion,
            decisionRawValue: decisionRawValue,
            rejectionCodeRawValue: trace.result.rejectionCode?.rawValue,
            completedStages: trace.result.completedStages,
            senderWasUsed: trace.senderWasUsed,
            stagesJSON: stagesJSON
        )
    }

    private func findAlert(id: UUID) throws -> InboxAlert? {
        let targetID = id
        var descriptor = FetchDescriptor<InboxAlert>(
            predicate: #Predicate { alert in
                alert.id == targetID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func canProcess(
        _ alert: InboxAlert,
        allowNeedsReview: Bool
    ) -> Bool {
        switch alert.status {
        case .pending, .processing:
            true
        case .needsReview:
            allowNeedsReview
        case .imported, .rejected, .duplicate:
            false
        }
    }

    private static func currentDisposition(for alert: InboxAlert) -> IngestionDisposition {
        switch alert.status {
        case .pending, .processing:
            .queued
        case .imported:
            .imported
        case .needsReview:
            .needsReview
        case .rejected:
            .rejected
        case .duplicate:
            .duplicate
        }
    }

    private func ownerState(for alert: InboxAlert) throws -> OwnerState {
        let transaction = try findTransaction(for: alert)
        return OwnerState(
            alertUpdatedAt: alert.updatedAt,
            transactionID: alert.transactionID,
            transactionUpdatedAt: transaction?.updatedAt,
            transactionWasEdited: transaction?.isEdited
        )
    }

    private func findTransaction(for alert: InboxAlert) throws -> Transaction? {
        guard let transactionID = alert.transactionID else { return nil }
        return try findTransaction(id: transactionID)
    }

    private func findTransaction(id: UUID) throws -> Transaction? {
        try context.fetch(FetchDescriptor<Transaction>()).first { $0.id == id }
    }

    private func preserveOwnerChangeIfNeeded(
        alert: InboxAlert,
        transactionIDAtStart: UUID?,
        transactionUpdatedAtAtStart: Date?,
        extractionRun: ExtractionRun
    ) throws -> IngestionReceipt? {
        guard let transactionIDAtStart, let transactionUpdatedAtAtStart else { return nil }

        let currentTransaction = try findTransaction(id: transactionIDAtStart)
        let ownerChangedOrDeletedTransaction =
            alert.transactionID != transactionIDAtStart
            || currentTransaction == nil
            || currentTransaction?.isEdited == true
            || currentTransaction?.updatedAt != transactionUpdatedAtAtStart
        guard ownerChangedOrDeletedTransaction else { return nil }

        extractionRun.recordValidationNotPerformed()
        let disposition: IngestionDisposition
        let runDisposition: ExtractionRunDisposition
        if alert.status == .imported || currentTransaction?.reviewState == .confirmed {
            disposition = .imported
            runDisposition = .imported
        } else {
            disposition = .needsReview
            runDisposition = .needsReview
        }
        extractionRun.complete(
            safeResultCode: "owner_change_preserved",
            disposition: runDisposition,
            at: .now
        )
        try save()
        return IngestionReceipt(alertID: alert.id, disposition: disposition)
    }

    private func resolveAccount(label: String, sender: String, body: String) throws -> Account {
        let normalized = AccountNormalizer.normalize(label: label, sender: sender, body: body)
        let descriptor = FetchDescriptor<Account>()
        if let existing = try context.fetch(descriptor).first(where: { account in
            account.kind == normalized.kind
                && account.suffix == normalized.suffix
                && !account.bank.isEmpty
                && !normalized.bank.isEmpty
                && account.bank == normalized.bank
        }) {
            return existing
        }

        let account = Account(
            name: normalized.name,
            bank: normalized.bank,
            kind: normalized.kind,
            suffix: normalized.suffix
        )
        context.insert(account)
        return account
    }

    private func reject(_ alert: InboxAlert, code: String) {
        alert.status = .rejected
        alert.rejectionCode = code
        alert.lastErrorCode = nil
        alert.eraseSensitiveEvidence()
    }

    private func save() throws {
        do {
            try contextSaver(context)
        } catch {
            context.rollback()
            throw AlertIngestionError.persistenceFailed
        }
    }

    private static func acquireClaim(
        for alertID: UUID,
        expectedProcessingEpoch: UInt64?
    ) -> ProcessingClaim? {
        guard
            expectedProcessingEpoch == nil || expectedProcessingEpoch == processingEpoch,
            processingClaims[alertID] == nil
        else { return nil }
        let claim = ProcessingClaim(token: UUID(), epoch: processingEpoch)
        processingClaims[alertID] = claim
        return claim
    }

    private static func ownsClaim(for alertID: UUID, claim: ProcessingClaim) -> Bool {
        claim.epoch == processingEpoch && processingClaims[alertID] == claim
    }

    private static func releaseClaim(for alertID: UUID, claim: ProcessingClaim) {
        guard ownsClaim(for: alertID, claim: claim) else { return }
        processingClaims[alertID] = nil
    }

    static func invalidateAllProcessingClaims() {
        processingEpoch &+= 1
        processingClaims.removeAll()
    }
}
