import SwiftUI

struct CurrentModelStatusView: View {
    @State private var diagnostic: ModelDiagnostic?

    var body: some View {
        Group {
            if let diagnostic {
                ModelStatusView(diagnostic: diagnostic)
            } else {
                ModelStatusLoadingView()
            }
        }
        .task {
            guard diagnostic == nil else { return }
            let loadedDiagnostic = await ModelDiagnostics.loadCurrent()
            guard !Task.isCancelled else { return }
            diagnostic = loadedDiagnostic
        }
    }
}

struct ModelStatusLoadingView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Checking on-device model")
                    .font(.headline)
                Text("Pocket Financer remains usable while this check finishes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("model-status-loading")
    }
}

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
                    Text("Language and region")
                        .fontWeight(.semibold)
                    ForEach(diagnostic.localeSupportProbes) { probe in
                        Text(
                            "\(probe.label) [\(probe.localeIdentifier)]: \(probeStatus(probe))"
                        )
                        .accessibilityLabel(probe.label)
                        .accessibilityValue(probeStatus(probe))
                    }
                    Text(
                        "Model-reported canonical language identifiers: \(diagnostic.supportedLanguageSummary)"
                    )
                    Text("The phone formatting locale is kept separate and does not block model processing.")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func probeStatus(_ probe: ModelLocaleSupportProbe) -> String {
        guard let isSupported = probe.isSupported else {
            return "Used only for regional formatting"
        }
        return isSupported ? "Supported" : "Unsupported"
    }
}
