import SwiftData
import SwiftUI

struct TransactionDetailView: View {
    @Bindable var transaction: Transaction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var sourceAlert: InboxAlert?
    @State private var showingEdit = false
    @State private var showingDelete = false
    @State private var deletionError: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(
                        systemName: transaction.direction == .debit
                            ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill"
                    )
                    .font(.system(size: 50))
                    .foregroundStyle(transaction.direction == .debit ? .orange : .green)
                    Text(
                        CurrencyFormatter.string(
                            minorUnits: transaction.amountMinorUnits,
                            currencyCode: transaction.currencyCode
                        )
                    )
                    .font(.largeTitle.bold().monospacedDigit())
                    Text(transaction.merchant)
                        .font(.title3.weight(.semibold))
                    if transaction.reviewState == .needsReview {
                        Label("Check this extraction", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            Section("Details") {
                LabeledContent("Direction", value: transaction.direction.rawValue.capitalized)
                LabeledContent("Account", value: transaction.accountLabel ?? "Unknown")
                LabeledContent("Date") {
                    Text(transaction.occurredAt, format: .dateTime.day().month().year().hour().minute())
                }
                LabeledContent("Parser", value: transaction.parserName)
                if transaction.isEdited {
                    LabeledContent("Correction", value: "Edited manually")
                }
            }

            if let sourceAlert, !sourceAlert.rawBody.isEmpty {
                Section("Local evidence") {
                    if !sourceAlert.sender.isEmpty {
                        LabeledContent("Sender", value: sourceAlert.sender)
                    }
                    Text(sourceAlert.rawBody)
                        .font(.callout)
                        .textSelection(.enabled)
                    LabeledContent(
                        transaction.isEdited ? "Original extracted amount evidence" : "Amount evidence",
                        value: transaction.amountEvidenceText
                    )
                    if let dateEvidenceText = transaction.dateEvidenceText {
                        LabeledContent(
                            transaction.isEdited ? "Original extracted date evidence" : "Date evidence",
                            value: dateEvidenceText
                        )
                    }
                }
            }

            if let sourceAlert {
                Section("Processing") {
                    NavigationLink {
                        AlertProcessingDetailView(
                            alert: sourceAlert,
                            transaction: transaction
                        )
                    } label: {
                        Label("Model & Processing Details", systemImage: "apple.intelligence")
                    }
                }
            }

            Section {
                Button("Delete Transaction", role: .destructive) {
                    showingDelete = true
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Edit") { showingEdit = true }
        }
        .sheet(isPresented: $showingEdit) {
            TransactionEditView(transaction: transaction, sourceAlert: sourceAlert)
        }
        .confirmationDialog(
            "Delete this transaction?",
            isPresented: $showingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Transaction", role: .destructive) { deleteTransaction() }
        } message: {
            Text("Its source alert remains locally available for review.")
        }
        .alert(
            "Transaction Not Deleted",
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        .task { loadSourceAlert() }
    }

    private func loadSourceAlert() {
        let alerts = (try? modelContext.fetch(FetchDescriptor<InboxAlert>())) ?? []
        sourceAlert = alerts.first { $0.id == transaction.sourceAlertID }
    }

    private func deleteTransaction() {
        sourceAlert?.transactionID = nil
        sourceAlert?.status = .needsReview
        sourceAlert?.updatedAt = .now
        modelContext.delete(transaction)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            deletionError = "The change could not be saved. Your transaction is still available."
        }
    }
}

private struct TransactionEditView: View {
    @Bindable var transaction: Transaction
    let sourceAlert: InboxAlert?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var amountText: String
    @State private var merchant: String
    @State private var direction: TransactionDirection
    @State private var occurredAt: Date
    @State private var errorMessage: String?

    init(transaction: Transaction, sourceAlert: InboxAlert?) {
        self.transaction = transaction
        self.sourceAlert = sourceAlert
        _amountText = State(initialValue: NSDecimalNumber(decimal: transaction.decimalAmount).stringValue)
        _merchant = State(initialValue: transaction.merchant)
        _direction = State(initialValue: transaction.direction)
        _occurredAt = State(initialValue: transaction.occurredAt)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
                TextField("Merchant", text: $merchant)
                Picker("Direction", selection: $direction) {
                    Text("Debit").tag(TransactionDirection.debit)
                    Text("Credit").tag(TransactionDirection.credit)
                }
                DatePicker("Date", selection: $occurredAt)
            }
            .navigationTitle("Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert(
                "Transaction Not Saved",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .sensitiveSceneCover()
    }

    private func save() {
        guard
            let minorUnits = try? AmountParser.minorUnits(
                from: "INR \(amountText)",
                currencyCode: transaction.currencyCode
            ),
            !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            errorMessage = "Enter a positive amount with no more than two decimal places and a merchant name."
            return
        }

        transaction.amountMinorUnits = minorUnits
        transaction.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        transaction.direction = direction
        transaction.occurredAt = occurredAt
        transaction.isEdited = true
        transaction.reviewState = .confirmed
        transaction.updatedAt = .now
        sourceAlert?.status = .imported
        sourceAlert?.lastErrorCode = nil
        sourceAlert?.updatedAt = .now
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = "The correction could not be saved. The previous transaction remains unchanged."
        }
    }
}
