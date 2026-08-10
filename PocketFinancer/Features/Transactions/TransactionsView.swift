import SwiftData
import SwiftUI

struct TransactionsView: View {
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \InboxAlert.createdAt, order: .reverse) private var alerts: [InboxAlert]
    @State private var searchText = ""
    @State private var showingManualImport = false

    private var filteredTransactions: [Transaction] {
        guard !searchText.isEmpty else { return transactions }
        return transactions.filter {
            $0.merchant.localizedCaseInsensitiveContains(searchText)
                || ($0.accountLabel?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var attentionAlerts: [InboxAlert] {
        alerts.filter { $0.status == .pending || $0.status == .processing || $0.status == .needsReview }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredTransactions.isEmpty && attentionAlerts.isEmpty {
                    EmptyStateView(
                        systemImage: "text.document",
                        title: searchText.isEmpty ? "No transactions" : "No matches",
                        detail: searchText.isEmpty
                            ? "Use the plus button to try a synthetic transaction alert."
                            : "Try a different merchant or account."
                    )
                } else {
                    List {
                        if !attentionAlerts.isEmpty && searchText.isEmpty {
                            Section("Inbox") {
                                ForEach(attentionAlerts) { alert in
                                    NavigationLink {
                                        AlertProcessingDetailView(alert: alert)
                                    } label: {
                                        AlertQueueRow(alert: alert)
                                    }
                                }
                            }
                        }

                        Section("Transactions") {
                            ForEach(filteredTransactions) { transaction in
                                NavigationLink {
                                    TransactionDetailView(transaction: transaction)
                                } label: {
                                    TransactionRow(transaction: transaction)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Transactions")
            .searchable(text: $searchText, prompt: "Merchant or account")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingManualImport = true
                    } label: {
                        Label("Import Alert", systemImage: "plus")
                    }
                    .accessibilityIdentifier("import-alert-button")
                }
            }
            .sheet(isPresented: $showingManualImport) {
                ManualAlertImportView()
            }
        }
    }
}

private struct AlertQueueRow: View {
    let alert: InboxAlert

    private var title: String {
        switch alert.status {
        case .pending:
            "Saved for local retry"
        case .processing:
            "Processing on this iPhone"
        case .needsReview:
            "Needs review"
        default:
            "Saved alert"
        }
    }

    private var detail: String {
        switch alert.lastErrorCode {
        case "model_appleIntelligenceNotEnabled":
            "Enable Apple Intelligence, then retry"
        case "model_modelNotReady":
            "Apple's model is still preparing"
        case "model_assets_unavailable":
            "Apple's local model assets are not ready"
        case "model_deviceNotEligible":
            "This device cannot run the local model"
        case "model_timed_out":
            "The local model timed out"
        case "model_cancelled":
            "Local processing was interrupted"
        case "model_rate_limited", "model_concurrent_requests":
            "The local model is temporarily busy"
        case "model_unsupported_language":
            "The alert language is not supported locally"
        case "model_guardrail_violation", "model_refused":
            "Apple's local model declined this alert"
        case "model_unsupported_guide", "model_decoding_failed":
            "The installed model could not use the extraction schema"
        case "model_context_window_exceeded":
            "The alert exceeded the local model context"
        case "model_generation_failed":
            "No safe extraction was produced"
        case EvidenceValidationIssue.modelRejected.rawValue:
            "The model was uncertain; evidence was retained"
        default:
            "Evidence is retained locally"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alert.status == .needsReview ? "exclamationmark.bubble.fill" : "clock.fill")
                .foregroundStyle(alert.status == .needsReview ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
