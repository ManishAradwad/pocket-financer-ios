import SwiftData
import SwiftUI

struct AlertProcessingDetailView: View {
    @Bindable var alert: InboxAlert
    var transaction: Transaction?

    @Environment(\.modelContext) private var modelContext
    @State private var fetchedTransaction: Transaction?
    @State private var extractionRuns: [ExtractionRun] = []
    @State private var retrying = false
    @State private var resultMessage: String?

    private var acceptedTransaction: Transaction? {
        transaction ?? fetchedTransaction
    }

    private var latestRun: ExtractionRun? {
        extractionRuns.first
    }

    private var filterTrace: AlertFilterTrace? {
        guard !alert.rawBody.isEmpty else { return nil }
        return AlertFilter().trace(sender: alert.sender, body: alert.rawBody)
    }

    private var canRetry: Bool {
        !alert.rawBody.isEmpty && (alert.status == .pending || alert.status == .needsReview)
    }

    var body: some View {
        List {
            processingStateSection
            deterministicFilterSection
            modelRunSection
            extractionAttemptHistorySection
            modelContractSection
            acceptedOutputSection
            localInputSection
            appleTransparencyLimitsSection

            if canRetry {
                Section {
                    Button {
                        Task { await retry() }
                    } label: {
                        Label(retrying ? "Retrying locally…" : "Retry Local Processing", systemImage: "arrow.clockwise")
                    }
                    .disabled(retrying)
                    .accessibilityIdentifier("retry-alert-processing")
                } footer: {
                    Text(
                        "Retrying uses the same visible instructions, prompt format, validation, and local-only pipeline shown above."
                    )
                }
            }
        }
        .navigationTitle("Processing Details")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadLinkedTransaction()
            loadExtractionRuns()
        }
        .alert(
            "Pocket Financer",
            isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var processingStateSection: some View {
        Section("Processing record") {
            Label(
                AlertProcessingDiagnostics.statusTitle(alert.status),
                systemImage: statusIcon
            )
            .foregroundStyle(statusColor)

            LabeledContent("Origin", value: AlertProcessingDiagnostics.originTitle(alert.origin))
            LabeledContent("Source authenticity", value: "Unverified")
            Text(
                "Pocket Financer receives text supplied by Shortcuts or manual entry. iOS does not provide this action cryptographic proof of the original sender or source app."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            LabeledContent("Record ID") {
                Text(alert.id.uuidString.lowercased())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Supplied / local receipt") {
                Text(alert.receivedAt, format: .dateTime.day().month().year().hour().minute().second())
            }
            Text(
                "When Shortcuts does not supply an original message date, Pocket Financer records the local ingestion time here."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            LabeledContent("Saved") {
                Text(alert.createdAt, format: .dateTime.day().month().year().hour().minute().second())
            }
            LabeledContent("Last updated") {
                Text(alert.updatedAt, format: .dateTime.day().month().year().hour().minute().second())
            }
            LabeledContent("Model attempts", value: alert.attemptCount.formatted())

            if let lastAttemptAt = alert.lastAttemptAt {
                LabeledContent("Latest attempt started") {
                    Text(lastAttemptAt, format: .dateTime.day().month().year().hour().minute().second())
                }
            }

            if let latestRun, let duration = latestRun.totalDuration {
                LabeledContent(
                    "Latest attempt duration",
                    value: AlertProcessingDiagnostics.durationText(duration)
                )
            } else if latestRun != nil || alert.status == .processing {
                LabeledContent("Latest attempt duration", value: "In progress or interrupted")
            } else if let duration = AlertProcessingDiagnostics.attemptDuration(
                lastAttemptAt: alert.lastAttemptAt,
                updatedAt: alert.updatedAt,
                status: alert.status
            ) {
                LabeledContent(
                    "Approx. latest duration",
                    value: AlertProcessingDiagnostics.durationText(duration)
                )
            }

            codeRows
        }
    }

    @ViewBuilder
    private var codeRows: some View {
        if let rejectionCode = alert.rejectionCode {
            diagnosticCodeRow(label: "Rejection code", code: rejectionCode)
        }
        if let errorCode = alert.lastErrorCode {
            diagnosticCodeRow(label: "Last result code", code: errorCode)
        }
        if alert.rejectionCode == nil && alert.lastErrorCode == nil {
            LabeledContent("Error or rejection", value: "None")
        }
    }

    private func diagnosticCodeRow(label: String, code: String) -> some View {
        let presentation = AlertProcessingDiagnostics.presentation(for: code)
        return VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Text(presentation.title)
                .font(.subheadline.weight(.semibold))
            Text(presentation.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var deterministicFilterSection: some View {
        Section {
            Label("Sender is not used", systemImage: "person.crop.circle.badge.xmark")
                .font(.subheadline.weight(.semibold))
            Text(
                "Bank sender labels vary by carrier and format. Eligibility is determined only from the alert body; sender never changes a filter outcome."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let filterTrace {
                ForEach(filterTrace.stages, id: \.id) { stage in
                    FilterStageRow(stage: stage)
                }
            } else {
                ContentUnavailableView(
                    "Filter trace unavailable",
                    systemImage: "eraser.fill",
                    description: Text(
                        "The alert body was erased after a deterministic rejection or duplicate decision, so its checks cannot be reconstructed."
                    )
                )
            }
        } header: {
            Text("Deterministic filter")
        } footer: {
            Text("Every stage runs locally before Apple Foundation Models is allowed to inspect an eligible alert.")
        }
    }

    private var modelRunSection: some View {
        let diagnostic = ModelDiagnostics.current()
        return Section("Model run") {
            LabeledContent("Parser", value: alert.parserName ?? "Not invoked")
            LabeledContent("System model", value: "SystemLanguageModel.default")
            LabeledContent("Current app locale", value: diagnostic.localeIdentifier)
            LabeledContent(
                "Current locale supported",
                value: diagnostic.localeWasSupported ? "Yes" : "No"
            )
            VStack(alignment: .leading, spacing: 5) {
                Text("Model language identifiers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(diagnostic.supportedLanguageSummary)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Cancellation threshold", value: FoundationModelExtractionContract.timeoutDescription)
            LabeledContent("Guardrails", value: FoundationModelExtractionContract.guardrailsDescription)
            LabeledContent("Scheduling", value: FoundationModelExtractionContract.requestSchedulingDescription)
        }
    }

    private var extractionAttemptHistorySection: some View {
        Section {
            if extractionRuns.isEmpty {
                ContentUnavailableView(
                    "No persisted model attempt",
                    systemImage: "archivebox",
                    description: Text(
                        "This alert was filtered without the model, predates the audit schema, or has not reached parsing yet."
                    )
                )
            } else {
                ForEach(extractionRuns) { run in
                    ExtractionRunDisclosure(
                        run: run,
                        initiallyExpanded: run.id == latestRun?.id
                    )
                }
            }
        } header: {
            Text("Persistent attempt history")
        } footer: {
            Text(
                "Each attempt is a protected local snapshot. Its exact request, mapped parser draft, validation result, and disposition are never written to logs."
            )
        }
    }

    private var modelContractSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Current contract instructions")
                    .font(.subheadline.weight(.semibold))
                Text(FoundationModelExtractionContract.instructions)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .padding(.vertical, 3)

            if !alert.rawBody.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current request preview")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        FoundationModelExtractionContract.requestPrompt(
                            body: alert.rawBody,
                            receivedAt: alert.receivedAt
                        )
                    )
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    Text("The sender label is deliberately absent from this request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            } else {
                Text("The exact request cannot be reconstructed because sensitive evidence was erased.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Current model request contract")
        } footer: {
            Text(
                "This is a preview for the current app version. The persistent attempt history above is the source of truth for the exact contract and request used by each historical run."
            )
        }
    }

    @ViewBuilder
    private var acceptedOutputSection: some View {
        Section {
            if let transaction = acceptedTransaction {
                LabeledContent("Current classification", value: "Transaction")
                LabeledContent("Current direction", value: transaction.direction.rawValue)
                LabeledContent(
                    "Current amount",
                    value: CurrencyFormatter.string(
                        minorUnits: transaction.amountMinorUnits,
                        currencyCode: transaction.currencyCode
                    )
                )
                LabeledContent("Currency", value: transaction.currencyCode)
                LabeledContent("Merchant", value: transaction.merchant)
                LabeledContent("Account", value: transaction.accountLabel ?? "Unknown")
                LabeledContent("Occurred") {
                    Text(transaction.occurredAt, format: .dateTime.day().month().year().hour().minute())
                }
                LabeledContent("Review state", value: transaction.reviewState.rawValue)
                LabeledContent("Edited by owner", value: transaction.isEdited ? "Yes" : "No")

                VStack(alignment: .leading, spacing: 5) {
                    Text("Current grounded amount evidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transaction.amountEvidenceText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                if let dateEvidenceText = transaction.dateEvidenceText {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Current grounded date evidence")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(dateEvidenceText)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No output accepted",
                    systemImage: "checkmark.shield.fill",
                    description: Text(
                        "No structured transaction passed evidence validation for this alert."
                    )
                )
            }
        } header: {
            Text("Current saved transaction")
        } footer: {
            if acceptedTransaction?.isEdited == true {
                Text(
                    "This is the owner's edited ledger state. It is intentionally separate from the original parser draft and validation snapshot in the attempt history."
                )
            } else {
                Text(
                    "This is the current evidence-validated ledger state. The attempt history separately preserves the parser draft that produced it."
                )
            }
        }
    }

    private var localInputSection: some View {
        Section {
            Label("Source authenticity is not verified", systemImage: "exclamationmark.shield.fill")
                .font(.subheadline.weight(.semibold))
            Text(
                "This text enters through a user-controlled Shortcuts automation. Pocket Financer cannot authenticate the bank, carrier, or sender label; validation only checks that extracted fields are present in the supplied text."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if !alert.rawBody.isEmpty {
                LabeledContent("Source app", value: alert.sourceApplication ?? "Not provided")
                LabeledContent("Sender", value: alert.sender.isEmpty ? "Not provided" : alert.sender)
                Text(alert.rawBody)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            } else {
                Label("Sensitive evidence erased", systemImage: "eraser.fill")
                Text(
                    "Pocket Financer clears deterministic rejections and duplicates instead of retaining their body or sender."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Local input evidence")
        } footer: {
            Text(
                "Sensitive values on this screen are visible only inside the local app UI. Do not include them in screenshots or issue reports."
            )
        }
    }

    private var appleTransparencyLimitsSection: some View {
        Section("What Apple's API does not expose") {
            TransparencyLimitRow(
                title: "Exact model version",
                detail:
                    "Foundation Models identifies the system model, but does not provide Pocket Financer an owner-readable model version or build number."
            )
            TransparencyLimitRow(
                title: "Token count",
                detail: "The API does not expose a per-request input or output token count used by this app."
            )
            TransparencyLimitRow(
                title: "Tokens per second",
                detail: "The API does not expose generation throughput for a request."
            )
            TransparencyLimitRow(
                title: "Numeric context-window size",
                detail:
                    "The iOS 26 API can report that a request exceeded its context window, but it does not expose the window's numeric capacity."
            )
            TransparencyLimitRow(
                title: "KV-cache details",
                detail: "The API does not expose cache allocation, reuse, hit rate, or memory measurements."
            )
            TransparencyLimitRow(
                title: "Confidence score",
                detail:
                    "No numeric model confidence is provided. Pocket Financer relies on exact evidence validation instead."
            )
            TransparencyLimitRow(
                title: "Hidden reasoning",
                detail:
                    "Private model reasoning is neither requested nor exposed. Only the structured response is inspected."
            )
        }
    }

    private var statusIcon: String {
        switch alert.status {
        case .pending:
            "clock.fill"
        case .processing:
            "apple.intelligence"
        case .imported:
            "checkmark.circle.fill"
        case .needsReview:
            "exclamationmark.triangle.fill"
        case .rejected:
            "xmark.shield.fill"
        case .duplicate:
            "doc.on.doc.fill"
        }
    }

    private var statusColor: Color {
        switch alert.status {
        case .pending, .processing:
            .blue
        case .imported:
            .green
        case .needsReview:
            .orange
        case .rejected, .duplicate:
            .secondary
        }
    }

    private func loadLinkedTransaction() {
        guard transaction == nil, let transactionID = alert.transactionID else { return }
        let transactions = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        fetchedTransaction = transactions.first { $0.id == transactionID }
    }

    private func loadExtractionRuns() {
        let descriptor = FetchDescriptor<ExtractionRun>(
            sortBy: [SortDescriptor(\ExtractionRun.attemptIndex, order: .reverse)]
        )
        extractionRuns = ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.alertID == alert.id }
    }

    private func retry() async {
        retrying = true
        defer { retrying = false }

        do {
            let service = AlertIngestionService(context: modelContext)
            let receipt = try await service.retry(alertID: alert.id)
            loadLinkedTransaction()
            loadExtractionRuns()
            resultMessage = receipt.safeDialog
        } catch {
            resultMessage = "The retry could not be saved locally. The retained alert is unchanged."
        }
    }
}

private struct ExtractionRunDisclosure: View {
    let run: ExtractionRun
    @State private var isExpanded: Bool

    init(run: ExtractionRun, initiallyExpanded: Bool) {
        self.run = run
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                identityAndTiming
                Divider()
                requestSnapshot
                Divider()
                responseMapping
                Divider()
                parserDraftSnapshot
                Divider()
                validationSnapshot
                Divider()
                acceptedTransactionSnapshot
            }
            .padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Attempt \(run.attemptIndex)")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var identityAndTiming: some View {
        VStack(alignment: .leading, spacing: 7) {
            auditHeading("Identity and timing")
            auditValue("Run ID", run.id.uuidString.lowercased())
            auditValue("Parser", run.parserName)
            auditValue("Contract version", run.contractVersion)
            auditValue("Extraction profile version", run.profileVersion)
            auditValue("Checked locale", run.localeIdentifier)
            auditValue(
                "Locale supported at request start",
                run.localeWasSupported.map { $0 ? "Yes" : "No" } ?? "Not recorded"
            )
            auditValue(
                "Model language identifiers",
                run.supportedLanguageIdentifiers.isEmpty
                    ? "Not recorded" : run.supportedLanguageIdentifiers.joined(separator: ", ")
            )
            auditDate("Attempt record created", run.startedAt)
            if let responseReceivedAt = run.responseReceivedAt {
                auditDate("Parser response received", responseReceivedAt)
            } else {
                auditValue("Parser response received", "No mapped response persisted")
            }
            if let completedAt = run.completedAt {
                auditDate("Completed", completedAt)
            } else {
                auditValue("Completed", "No terminal save recorded")
            }
            if let parserDuration = run.parserDuration {
                auditValue(
                    "Elapsed to mapped response",
                    "\(AlertProcessingDiagnostics.durationText(parserDuration)) (includes local queue time)"
                )
            }
            if let totalDuration = run.totalDuration {
                auditValue("Total attempt duration", AlertProcessingDiagnostics.durationText(totalDuration))
            }
        }
    }

    private var requestSnapshot: some View {
        VStack(alignment: .leading, spacing: 8) {
            auditHeading("Exact constructed request")
            Text(
                "This request was constructed before availability checks and local scheduling. A failed attempt may end before Apple accepts it for generation."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Instructions")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(run.exactInstructions)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Request")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(run.exactRequest)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private var responseMapping: some View {
        VStack(alignment: .leading, spacing: 6) {
            auditHeading("Declared structured-response mapping")
            ForEach(FoundationModelExtractionContract.structuredSchemaMapping, id: \.self) { mapping in
                Text(mapping)
                    .font(.caption.monospaced())
            }
            Text(
                "Foundation Models generates the declared structured profile directly. Pocket Financer stores the exact ParsedAlertDraft fields after this mapping. This adapter does not persist Response.rawContent or the session transcript, and Apple's API does not expose hidden reasoning."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var parserDraftSnapshot: some View {
        VStack(alignment: .leading, spacing: 7) {
            auditHeading("Persisted ParsedAlertDraft snapshot")
            if let draft = run.parserDraft {
                Text(
                    "Captured before evidence validation. This snapshot is separate from the current saved transaction and is not changed by owner edits."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                auditValue("classification", draft.classification.rawValue)
                auditValue("direction", display(draft.direction))
                auditValue("amountText", display(draft.amountText))
                auditValue("merchant", display(draft.merchant))
                auditValue("accountLabel", display(draft.accountLabel))
                auditValue("occurredAtText", display(draft.occurredAtText))
                auditValue("currencyCode", display(draft.currencyCode))
            } else {
                Text("No ParsedAlertDraft was returned and persisted for this attempt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var validationSnapshot: some View {
        VStack(alignment: .leading, spacing: 7) {
            auditHeading("Validation and disposition")
            auditValue("Overall validation", validationTitle)
            ForEach(EvidenceValidationStage.allCases, id: \.self) { stage in
                auditValue(
                    "\(stage.rawValue.capitalized) stage",
                    validationStageTitle(run.validationState(for: stage))
                )
            }
            auditValue("Safe result code", run.safeResultCode ?? "No terminal result recorded")
            auditValue("Terminal disposition", dispositionTitle)
        }
    }

    @ViewBuilder
    private var acceptedTransactionSnapshot: some View {
        VStack(alignment: .leading, spacing: 7) {
            auditHeading("Accepted transaction snapshot")
            if let transactionID = run.acceptedTransactionID,
                let amountMinorUnits = run.acceptedAmountMinorUnits,
                let currencyCode = run.acceptedCurrencyCode,
                let direction = run.acceptedDirection,
                let merchant = run.acceptedMerchant,
                let occurredAt = run.acceptedOccurredAt,
                let reviewState = run.acceptedReviewState,
                let amountEvidenceText = run.acceptedAmountEvidenceText
            {
                Text(
                    "Captured when this attempt wrote the ledger. This historical snapshot is not changed by later retries or owner edits."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                auditValue("Transaction ID", transactionID.uuidString.lowercased())
                auditValue(
                    "Amount",
                    CurrencyFormatter.string(minorUnits: amountMinorUnits, currencyCode: currencyCode)
                )
                auditValue("Currency", currencyCode)
                auditValue("Direction", direction.rawValue)
                auditValue("Merchant", merchant)
                auditValue("Account", run.acceptedAccountLabel ?? "Unknown")
                auditDate("Occurred", occurredAt)
                auditValue("Review state", reviewState.rawValue)
                auditValue("Amount evidence", amountEvidenceText)
                auditValue("Date evidence", run.acceptedDateEvidenceText ?? "No explicit date evidence")
            } else {
                Text("This attempt did not write an evidence-validated transaction snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let duration = run.totalDuration.map(AlertProcessingDiagnostics.durationText) ?? "unfinished"
        return "\(dispositionTitle) • \(duration)"
    }

    private var validationTitle: String {
        switch run.validationOutcome {
        case .notPerformed:
            "Not performed"
        case .passed:
            "Passed"
        case .failed:
            "Failed"
        case nil:
            "No terminal validation recorded"
        }
    }

    private var dispositionTitle: String {
        switch run.terminalDisposition {
        case .imported:
            "Imported"
        case .queued:
            "Queued for retry"
        case .needsReview:
            "Needs review"
        case nil:
            "In progress or interrupted"
        }
    }

    private func validationStageTitle(_ state: EvidenceValidationStageState?) -> String {
        switch state {
        case .passed:
            "Passed"
        case .failed:
            "Failed"
        case .notRun:
            "Not run"
        case nil:
            "No stage result recorded"
        }
    }

    private func auditHeading(_ value: String) -> some View {
        Text(value)
            .font(.subheadline.weight(.semibold))
    }

    private func auditValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func auditDate(_ label: String, _ value: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value, format: .dateTime.day().month().year().hour().minute().second())
                .font(.caption.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private func display(_ value: String) -> String {
        value.isEmpty ? "<empty string>" : value
    }
}

private struct FilterStageRow: View {
    let stage: AlertFilterStageOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(stage.title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch stage.state {
        case .passed:
            "checkmark.circle.fill"
        case .failed:
            "xmark.circle.fill"
        case .notRun:
            "minus.circle.fill"
        }
    }

    private var color: Color {
        switch stage.state {
        case .passed:
            .green
        case .failed:
            .red
        case .notRun:
            .secondary
        }
    }

    private var detail: String {
        stage.state == .notRun ? "Not run because an earlier deterministic stage stopped processing." : stage.detail
    }
}

private struct TransparencyLimitRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
