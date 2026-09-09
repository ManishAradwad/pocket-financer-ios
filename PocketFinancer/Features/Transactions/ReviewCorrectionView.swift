import SwiftData
import SwiftUI

struct ReviewCorrectionView: View {
    let reviewCase: SmsReviewCase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var amount = ""
    @State private var merchant = ""
    @State private var currency = PrimaryCurrencySettings.currentCode
    @State private var direction = TransactionDirection.debit
    @State private var accountID: UUID?
    @State private var occurredAt = Date.now
    @State private var errorMessage: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section("Review state") {
                LabeledContent(
                    "Status", value: reviewCase.stateRawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                LabeledContent("Revision", value: "\(reviewCase.revision)")
                ForEach(reviewCase.reasonCodesRawValue.split(separator: "\n"), id: \.self) {
                    Text(String($0)).font(.caption.monospaced())
                }
            }
            Section("Correction draft") {
                TextField("Exact amount in minor units", text: $amount)
                    .keyboardType(.numberPad)
                Picker("Currency", selection: $currency) {
                    ForEach(PrimaryCurrencySettings.supportedCodes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Direction", selection: $direction) {
                    ForEach(TransactionDirection.allCases) { value in
                        Text(value.rawValue.capitalized).tag(value)
                    }
                }
                TextField("Merchant or counterparty", text: $merchant)
                Picker("Owned account", selection: $accountID) {
                    Text("Select an account").tag(UUID?.none)
                    ForEach(accounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                DatePicker("Transaction time", selection: $occurredAt)
                Text("Values entered here are explicitly marked as user-supplied, not model-grounded evidence.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Save draft") { resolve(.saveDraft) }
                    .disabled(saving)
                Button("Apply correction and add transaction") { resolve(.correct) }
                    .disabled(
                        saving || amount.isEmpty || merchant.isEmpty || accountID == nil
                            || Int64(amount).map { $0 <= 0 } != false
                    )
            }
            Section("Actions") {
                Button("Confirm grounded proposal") { resolve(.confirm) }
                Button("Retry with original settings") { resolve(.retry, retry: "original") }
                Button("Retry with current settings") { resolve(.retry, retry: "current") }
                Button("Reject alert", role: .destructive) { resolve(.reject) }
            }
        }
        .navigationTitle("Review alert")
        .onAppear(perform: loadDraft)
        .alert("Could not save review", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func resolve(_ kind: ReviewCommandKind, retry: String? = nil) {
        saving = true
        var corrections: [SmsFieldCorrection] = [
            amount.isEmpty
                ? nil
                : SmsFieldCorrection(
                    field: "amount_minor_units",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil, candidateID: nil, evidence: nil, newValue: amount
                ),
            merchant.isEmpty
                ? nil
                : SmsFieldCorrection(
                    field: "counterparty",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil, candidateID: nil, evidence: nil, newValue: merchant
                ),
        ].compactMap { $0 }
        if kind != .correct && kind != .saveDraft {
            corrections = []
        }
        if kind == .correct || kind == .saveDraft {
            corrections.append(contentsOf: [
                SmsFieldCorrection(
                    field: "currency", classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil, candidateID: nil, evidence: nil, newValue: currency
                ),
                SmsFieldCorrection(
                    field: "direction", classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil, candidateID: nil, evidence: nil,
                    newValue: direction.rawValue
                ),
                SmsFieldCorrection(
                    field: "occurred_at_epoch_ms", classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil, candidateID: nil, evidence: nil,
                    newValue: String(Int64(occurredAt.timeIntervalSince1970 * 1_000))
                ),
            ])
            if let accountID {
                corrections.append(
                    SmsFieldCorrection(
                        field: "account_id", classification: .suppliedManualUngroundedValue,
                        previousRevisionID: nil, candidateID: nil, evidence: nil,
                        newValue: accountID.uuidString.lowercased()
                    ))
            }
        }
        let command = ReviewCommand(
            actionID: UUID(), reviewCaseID: reviewCase.id,
            expectedRevision: reviewCase.revision, kind: kind,
            corrections: corrections, retryConfiguration: retry
        )
        Task {
            do {
                let store = SmsProcessingStore(modelContainer: modelContext.container)
                _ = try await store.resolveReview(command)
                if kind == .retry, let retry {
                    _ = try await AlertIngestionService(context: modelContext).retry(
                        alertID: reviewCase.sourceAlertID,
                        parentOperationID: reviewCase.currentOperationID,
                        configurationMode: retry
                    )
                }
                dismiss()
            } catch {
                errorMessage = "The review changed or storage was unavailable. Reload and try again."
            }
            saving = false
        }
    }

    private func loadDraft() {
        guard
            let draftJSON = reviewCase.draftJSON,
            let corrections = try? JSONDecoder().decode(
                [SmsFieldCorrection].self,
                from: Data(draftJSON.utf8)
            )
        else { return }
        for correction in corrections {
            switch correction.field {
            case "amount_minor_units":
                amount = correction.newValue
            case "counterparty":
                merchant = correction.newValue
            case "currency":
                if PrimaryCurrencySettings.supportedCodes.contains(correction.newValue) {
                    currency = correction.newValue
                }
            case "direction":
                if let parsed = TransactionDirection(rawValue: correction.newValue) {
                    direction = parsed
                }
            case "account_id":
                accountID = UUID(uuidString: correction.newValue)
            case "occurred_at_epoch_ms":
                if let milliseconds = Int64(correction.newValue) {
                    occurredAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
                }
            default:
                break
            }
        }
    }
}
