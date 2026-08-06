import SwiftUI

struct ModelStatusView: View {
    let diagnostic: ModelDiagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: diagnostic.isReady ? "apple.intelligence" : "clock.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(diagnostic.isReady ? .green : .orange)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 3) {
                Text(diagnostic.title)
                    .font(.headline)
                Text(diagnostic.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Checked current locale: \(diagnostic.localeIdentifier)")
                    Text(
                        "Locale support reported: \(diagnostic.localeWasSupported ? "Yes" : "No")"
                    )
                    Text("Model language identifiers: \(diagnostic.supportedLanguageSummary)")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
