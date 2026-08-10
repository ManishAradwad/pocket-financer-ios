import SwiftData
import SwiftUI

struct ManualAlertImportView: View {
    static let sample = "HDFC Bank: Rs.500.00 debited from a/c XXXXXX0000 on 05-08-2026 at Demo Store."

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var sender = "AX-HDFCBK"
    @State private var alertBody = sample
    @State private var isImporting = false
    @State private var resultMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Sender (optional)", text: $sender)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("manual-sender")

                    TextEditor(text: $alertBody)
                        .frame(minHeight: 180)
                        .font(.body)
                        .accessibilityLabel("Alert body")
                        .accessibilityIdentifier("manual-body")
                } header: {
                    Text("Alert")
                } footer: {
                    Text("Use synthetic data while testing. The full alert is saved locally before parsing.")
                }

                Section("What happens") {
                    Label("Deterministic transaction check", systemImage: "checkmark.shield")
                    Label("On-device model extraction", systemImage: "apple.intelligence")
                    Label("Evidence validation before save", systemImage: "text.magnifyingglass")
                }
            }
            .navigationTitle("Import Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task { await importAlert() }
                    }
                    .disabled(alertBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                    .accessibilityIdentifier("manual-import-submit")
                }
            }
            .alert(
                "Import result",
                isPresented: Binding(
                    get: { resultMessage != nil },
                    set: { if !$0 { resultMessage = nil } }
                )
            ) {
                Button("Done") { dismiss() }
            } message: {
                Text(resultMessage ?? "")
            }
        }
        .interactiveDismissDisabled(isImporting)
        .sensitiveSceneCover()
    }

    private func importAlert() async {
        isImporting = true
        defer { isImporting = false }
        do {
            let service = AlertIngestionService(context: modelContext)
            let receipt = try await service.ingest(
                body: alertBody,
                sender: sender.isEmpty ? nil : sender,
                receivedAt: .now,
                sourceApplication: "Pocket Financer",
                origin: .manual
            )
            resultMessage = receipt.safeDialog
        } catch {
            resultMessage = "The alert could not be saved. Please try again."
        }
    }
}
