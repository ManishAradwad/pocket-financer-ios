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
    private let parser: any TransactionParsing
    private let filter: AlertFilter
    private let validator: EvidenceValidator
    private let parserTimeout: Duration
    private let contextSaver: @MainActor (ModelContext) throws -> Void

    /// Main-actor reentrancy permits another service instance to enter while a parser
    /// request is suspended. A process-wide token prevents a second attempt for the same
    /// durable alert. The map intentionally starts empty after a process restart so a
    /// persisted `.processing` alert can be recovered.
    private static var processingClaims: [UUID: UUID] = [:]

    init(
        context: ModelContext,
        parser: any TransactionParsing = FoundationModelTransactionParser(),
        filter: AlertFilter = AlertFilter(),
        validator: EvidenceValidator = EvidenceValidator(),
        parserTimeout: Duration = FoundationModelExtractionContract.timeout,
        contextSaver: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.parser = parser
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
        openDatabase: () throws -> AppDatabase = { try AppDatabase.openShared() }
    ) throws -> IngestionReceipt {
        let database: AppDatabase
        do {
            database = try openDatabase()
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
        openDatabase: () throws -> AppDatabase = { try AppDatabase.openShared() }
    ) async throws -> IngestionReceipt {
        let database: AppDatabase
        do {
            database = try openDatabase()
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
        let descriptor = FetchDescriptor<InboxAlert>(sortBy: [SortDescriptor(\InboxAlert.createdAt)])
        guard let alerts = try? context.fetch(descriptor) else { return 0 }

        let eligible = alerts.filter { alert in
            let retryable =
                alert.status == .pending || alert.status == .processing
                || (includeNeedsReview && alert.status == .needsReview)
            return retryable && !alert.rawBody.isEmpty
        }.prefix(limit)

        var completed = 0
        for alert in eligible {
            guard !Task.isCancelled else { break }
            do {
                if try await classifyAndProcessIfClaimed(
                    alert,
                    allowBeyondAutomaticAttemptLimit: includeNeedsReview
                ) != nil {
                    completed += 1
                }
            } catch {
                alert.status = .pending
                alert.lastErrorCode = "persistence_failed"
                alert.updatedAt = .now
                try? save()
            }
        }
        return completed
    }

    private func classifyAndProcessIfClaimed(
        _ alert: InboxAlert,
        allowBeyondAutomaticAttemptLimit: Bool
    ) async throws -> IngestionReceipt? {
        guard !Task.isCancelled, let claimToken = Self.acquireClaim(for: alert.id) else { return nil }
        defer { Self.releaseClaim(for: alert.id, token: claimToken) }

        if !allowBeyondAutomaticAttemptLimit, alert.attemptCount >= Self.automaticAttemptLimit {
            alert.status = .needsReview
            alert.lastErrorCode = "automatic_retry_limit_reached"
            alert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .needsReview)
        }

        let filterResult = filter.evaluate(sender: alert.sender, body: alert.rawBody)
        switch filterResult.decision {
        case .eligible:
            return try await process(alert, claimToken: claimToken)
        case .rejectAndErase:
            reject(
                alert,
                code: filterResult.rejectionCode?.rawValue ?? AlertRejectionCode.emptyBody.rawValue
            )
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .rejected)
        case .needsReview:
            alert.status = .needsReview
            alert.rejectionCode = nil
            alert.lastErrorCode =
                filterResult.rejectionCode?.rawValue ?? AlertRejectionCode.missingTransactionVerb.rawValue
            alert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .needsReview)
        }
    }

    private func process(_ alert: InboxAlert, claimToken: UUID) async throws -> IngestionReceipt {
        if let existing = try findTransaction(for: alert), existing.isEdited {
            alert.status = .imported
            alert.lastErrorCode = nil
            alert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .imported)
        }

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
        context.insert(extractionRun)
        try save()

        let draft: ParsedAlertDraft
        do {
            draft = try await parseWithDeadline(
                body: alert.rawBody,
                sender: alert.sender,
                receivedAt: alert.receivedAt
            )
        } catch let error as TransactionParserError {
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
        } catch {
            let completedAt = Date.now
            alert.status = .pending
            alert.lastErrorCode = "parser_failed"
            alert.updatedAt = completedAt
            extractionRun.recordValidationNotPerformed()
            extractionRun.complete(
                safeResultCode: "parser_failed",
                disposition: .queued,
                at: completedAt
            )
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .queued)
        }

        // Only the process-wide claim owner may apply a response after this suspension.
        guard Self.ownsClaim(for: alert.id, token: claimToken) else {
            return IngestionReceipt(alertID: alert.id, disposition: .queued)
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

    private func parseWithDeadline(
        body: String,
        sender: String,
        receivedAt: Date
    ) async throws -> ParsedAlertDraft {
        try await withThrowingTaskGroup(of: ParsedAlertDraft.self) { group in
            group.addTask { [self] in
                try await self.parser.parse(body: body, sender: sender, receivedAt: receivedAt)
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

    private func findDuplicate(contentDigest: String, receivedAt: Date) throws -> InboxAlert? {
        let descriptor = FetchDescriptor<InboxAlert>(sortBy: [SortDescriptor(\InboxAlert.receivedAt, order: .reverse)])
        return try context.fetch(descriptor).first { candidate in
            candidate.contentDigest == contentDigest
                && candidate.status != .duplicate
                && abs(candidate.receivedAt.timeIntervalSince(receivedAt)) <= Self.duplicateWindow
        }
    }

    private func findAlert(id: UUID) throws -> InboxAlert? {
        let descriptor = FetchDescriptor<InboxAlert>()
        return try context.fetch(descriptor).first { $0.id == id }
    }

    private func findTransaction(for alert: InboxAlert) throws -> Transaction? {
        guard let transactionID = alert.transactionID else { return nil }
        return try context.fetch(FetchDescriptor<Transaction>()).first { $0.id == transactionID }
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

    private static func acquireClaim(for alertID: UUID) -> UUID? {
        guard processingClaims[alertID] == nil else { return nil }
        let token = UUID()
        processingClaims[alertID] = token
        return token
    }

    private static func ownsClaim(for alertID: UUID, token: UUID) -> Bool {
        processingClaims[alertID] == token
    }

    private static func releaseClaim(for alertID: UUID, token: UUID) {
        guard ownsClaim(for: alertID, token: token) else { return }
        processingClaims[alertID] = nil
    }
}
