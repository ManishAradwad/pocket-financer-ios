import SwiftUI

struct ModelSelfTestReportView: View {
    @Environment(\.dismiss) private var dismiss

    let report: ModelSelfTestResult

    var body: some View {
        NavigationStack {
            List {
                outcomeSection
                runSection
                contractSection
                syntheticInputSection
                promptSection
                parserDraftSection
                validationSection
                acceptedFieldsSection
                failureSection
                apiLimitsSection
                privacySection
            }
            .navigationTitle("Synthetic Model Test")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("model-self-test-report")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sensitiveSceneCover()
    }

    private var outcomeSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: report.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(report.passed ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 5) {
                    Text(report.passed ? "Passed" : "Did not pass")
                        .font(.headline)
                    Text(report.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } footer: {
            Text("This is an in-memory synthetic diagnostic. It never creates a transaction.")
        }
    }

    private var runSection: some View {
        Section("Run") {
            LabeledContent("Started", value: timestamp(report.startedAt))
            LabeledContent("Completed", value: timestamp(report.completedAt))
            LabeledContent("Elapsed", value: elapsedText)
            LabeledContent("Parser", value: report.parserName)
        }
    }

    private var contractSection: some View {
        Section {
            LabeledContent("Contract version", value: report.contractVersion)
            LabeledContent("Profile version", value: report.profileVersion)
            LabeledContent("Checked model locale", value: report.localeIdentifier)
            LabeledContent("Locale support at start", value: localeSupportTitle)
            ReportTextField(
                label: "Model language identifiers",
                value: supportedLanguageIdentifiersText,
                monospaced: true
            )
            LabeledContent("Cancellation threshold", value: report.requestDeadline)
            ReportTextField(label: "Scheduling", value: report.scheduling)
            ReportTextField(label: "Guardrails", value: report.guardrails)
        } header: {
            Text("Extraction contract")
        } footer: {
            Text(
                "The parser checks Pocket Financer's U.S. English model-processing locale with supportsLocale before generation. The phone's regional formatting locale remains separate. Language identifiers come from supportedLanguages when Apple reports them."
            )
        }
    }

    private var syntheticInputSection: some View {
        Section {
            ReportTextField(label: "Alert body", value: report.syntheticBody, monospaced: true)
            ReportTextField(label: "Sender metadata", value: report.syntheticSender, monospaced: true)
            LabeledContent("receivedAt", value: timestamp(report.receivedAt))
            LabeledContent(
                "receivedAt epoch",
                value: String(format: "%.6f", report.receivedAt.timeIntervalSince1970)
            )
        } header: {
            Text("Synthetic input")
        } footer: {
            Text(
                "The one captured receivedAt value above was supplied to both the parser and evidence validator. Sender metadata is not included in the model request."
            )
        }
    }

    private var promptSection: some View {
        Section {
            ReportTextField(
                label: "Exact shared instructions",
                value: report.exactInstructions,
                monospaced: true
            )
            ReportTextField(
                label: "Exact request",
                value: report.exactRequest,
                monospaced: true
            )
        } header: {
            Text("Model request")
        } footer: {
            Text("These are the exact strings constructed for this run, shown from the shared extraction contract.")
        }
    }

    @ViewBuilder
    private var parserDraftSection: some View {
        Section {
            if let draft = report.parserDraft {
                ReportTextField(label: "classification", value: draft.classification.rawValue, monospaced: true)
                ReportTextField(label: "direction", value: draft.direction, monospaced: true)
                ReportTextField(label: "amountText", value: draft.amountText, monospaced: true)
                ReportTextField(label: "merchant", value: draft.merchant, monospaced: true)
                ReportTextField(label: "accountLabel", value: draft.accountLabel, monospaced: true)
                ReportTextField(label: "occurredAtText", value: draft.occurredAtText, monospaced: true)
                ReportTextField(label: "currencyCode", value: draft.currencyCode, monospaced: true)
            } else {
                Text("No ParsedAlertDraft was returned.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("ParsedAlertDraft")
        } footer: {
            Text(
                "ParsedAlertDraft is Pocket Financer's post-schema parser output. This in-memory synthetic report does not retain stream snapshots or the session transcript. Live alert processing separately persists cumulative raw structured JSON, but Apple's API does not expose hidden reasoning."
            )
        }
    }

    private var validationSection: some View {
        Section("Evidence validation") {
            LabeledContent("Outcome", value: validationOutcomeTitle)
            ReportTextField(label: "Safe code", value: report.validationSafeCode, monospaced: true)
            ReportTextField(label: "Result", value: report.validationMessage)
        }
    }

    @ViewBuilder
    private var acceptedFieldsSection: some View {
        if let draft = report.validatedDraft {
            Section {
                LabeledContent("Amount (minor units)", value: draft.amountMinorUnits.formatted())
                ReportTextField(label: "Currency", value: draft.currencyCode, monospaced: true)
                ReportTextField(label: "Direction", value: draft.direction.rawValue, monospaced: true)
                ReportTextField(label: "Merchant", value: draft.merchant, monospaced: true)
                ReportTextField(label: "Account label", value: draft.accountLabel, monospaced: true)
                LabeledContent("Occurred at", value: timestamp(draft.occurredAt))
                ReportTextField(
                    label: "Amount evidence",
                    value: draft.amountEvidenceText,
                    monospaced: true
                )
                ReportTextField(
                    label: "Date evidence",
                    value: draft.dateEvidenceText ?? "nil",
                    monospaced: true
                )
                ReportTextField(label: "Review state", value: draft.reviewState.rawValue, monospaced: true)
            } header: {
                Text("Validated fields")
            } footer: {
                Text("These synthetic fields passed evidence validation for inspection only. They were not saved.")
            }
        }
    }

    @ViewBuilder
    private var failureSection: some View {
        if let failure = report.failure {
            Section("Safe failure") {
                ReportTextField(label: "Safe code", value: failure.safeCode, monospaced: true)
                LabeledContent("Retryable", value: failure.isRetryable ? "Yes" : "No")
                ReportTextField(label: "What happened", value: failure.ownerMessage)
            }
        }
    }

    private var apiLimitsSection: some View {
        Section {
            ForEach(report.apiLimitations) { limitation in
                ReportTextField(label: limitation.metric, value: limitation.explanation)
            }
        } header: {
            Text("Apple API limits")
        } footer: {
            Text(
                "Pocket Financer reports only values it can observe. It does not estimate or fabricate unavailable model internals."
            )
        }
    }

    private var privacySection: some View {
        Section("Privacy of this report") {
            Label("Held in memory only", systemImage: "memorychip")
            Label("Not written to the local database", systemImage: "externaldrive.badge.xmark")
            Label("Not logged or sent anywhere", systemImage: "network.slash")
            Text("Dismissing this sheet releases the report from the Settings screen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var validationOutcomeTitle: String {
        switch report.validationOutcome {
        case .passed:
            "Passed"
        case .failed:
            "Failed safely"
        case .notRun:
            "Not run"
        }
    }

    private var elapsedText: String {
        String(format: "%.3f seconds", report.elapsed)
    }

    private var localeSupportTitle: String {
        switch report.localeWasSupported {
        case true:
            "Supported"
        case false:
            "Unsupported"
        case nil:
            "Not reported by this parser"
        }
    }

    private var supportedLanguageIdentifiersText: String {
        report.supportedLanguageIdentifiers.isEmpty
            ? "Not reported by this parser"
            : report.supportedLanguageIdentifiers.joined(separator: ", ")
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

private struct ReportTextField: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(displayValue)
                .font(monospaced ? .callout.monospaced() : .callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var displayValue: String {
        value.isEmpty ? "\"\" (empty string)" : value
    }
}
