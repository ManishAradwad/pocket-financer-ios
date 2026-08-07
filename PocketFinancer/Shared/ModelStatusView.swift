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

                VStack(alignment: .leading, spacing: 3) {
                    Text("Read-only locale comparison")
                        .fontWeight(.semibold)
                    ForEach(diagnostic.localeSupportProbes) { probe in
                        Text(
                            "\(probe.label) [\(probe.localeIdentifier)]: \(probe.isSupported ? "Supported" : "Unsupported")"
                        )
                        .accessibilityLabel(probe.label)
                        .accessibilityValue(probe.isSupported ? "Supported" : "Unsupported")
                    }
                    Text(
                        "Model-reported canonical language identifiers: \(diagnostic.supportedLanguageSummary)"
                    )
                    Text("The comparison checks do not change which locale the parser uses.")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
