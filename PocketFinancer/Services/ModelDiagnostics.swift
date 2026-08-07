import Foundation
import FoundationModels

struct ModelLocaleSupportProbe: Equatable, Identifiable, Sendable {
    let label: String
    let localeIdentifier: String
    let isSupported: Bool

    var id: String { label }
}

struct ModelDiagnostic: Equatable, Sendable {
    let isReady: Bool
    let title: String
    let detail: String
    let localeIdentifier: String
    let localeWasSupported: Bool
    let localeSupportProbes: [ModelLocaleSupportProbe]
    let supportedLanguageIdentifiers: [String]

    var supportedLanguageSummary: String {
        supportedLanguageIdentifiers.isEmpty
            ? "Not reported by the system model right now"
            : supportedLanguageIdentifiers.joined(separator: ", ")
    }
}

enum ModelAvailabilityDiagnosticState: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknownUnavailable
}

enum ModelDiagnostics {
    static func current(locale: Locale = .current) -> ModelDiagnostic {
        let model = SystemLanguageModel.default
        let localeWasSupported = model.supportsLocale(locale)
        return makeDiagnostic(
            availability: availabilityState(model.availability),
            localeIdentifier: locale.identifier,
            localeWasSupported: localeWasSupported,
            localeSupportProbes: makeLocaleSupportProbes(
                currentLocale: locale,
                currentLocaleWasSupported: localeWasSupported,
                supportsLocale: { model.supportsLocale($0) }
            ),
            supportedLanguageIdentifiers: languageIdentifiers(model.supportedLanguages)
        )
    }

    static func makeLocaleSupportProbes(
        currentLocale: Locale,
        currentLocaleWasSupported: Bool,
        supportsLocale: (Locale) -> Bool
    ) -> [ModelLocaleSupportProbe] {
        let englishIndiaIdentifier = "en-IN"
        let englishUSIdentifier = "en-US"
        let englishIndia = Locale(identifier: englishIndiaIdentifier)
        let englishUS = Locale(identifier: englishUSIdentifier)

        return [
            ModelLocaleSupportProbe(
                label: "Current app locale (primary)",
                localeIdentifier: currentLocale.identifier,
                isSupported: currentLocaleWasSupported
            ),
            ModelLocaleSupportProbe(
                label: "English (India) diagnostic",
                localeIdentifier: englishIndiaIdentifier,
                isSupported: supportsLocale(englishIndia)
            ),
            ModelLocaleSupportProbe(
                label: "English (US) control",
                localeIdentifier: englishUSIdentifier,
                isSupported: supportsLocale(englishUS)
            ),
        ]
    }

    static func languageIdentifiers(
        _ languages: Set<Locale.Language>
    ) -> [String] {
        Array(Set(languages.map(\.minimalIdentifier))).sorted()
    }

    static func makeDiagnostic(
        availability: ModelAvailabilityDiagnosticState,
        localeIdentifier: String,
        localeWasSupported: Bool,
        localeSupportProbes: [ModelLocaleSupportProbe],
        supportedLanguageIdentifiers: [String]
    ) -> ModelDiagnostic {
        let normalizedLanguages = Array(Set(supportedLanguageIdentifiers)).sorted()

        switch availability {
        case .available where localeWasSupported:
            return ModelDiagnostic(
                isReady: true,
                title: "On-device model available",
                detail:
                    "Apple's public locale check passed for the current app locale. Run the synthetic test to verify structured extraction on this OS and device.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: true,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .available:
            return ModelDiagnostic(
                isReady: false,
                title: "Current app locale unsupported",
                detail:
                    "Apple reports this locale as unsupported. Confirm that the iPhone language and Siri language use the same model-supported language, then reopen Pocket Financer. The public API does not identify which system setting caused a mismatch.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: false,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .deviceNotEligible:
            return ModelDiagnostic(
                isReady: false,
                title: "Device not eligible",
                detail:
                    "This iPhone cannot use Apple's on-device Foundation Model. Alerts remain available for review.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: localeWasSupported,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .appleIntelligenceNotEnabled:
            return ModelDiagnostic(
                isReady: false,
                title: "Apple Intelligence is off",
                detail:
                    "Enable Apple Intelligence in Settings. Also confirm that the iPhone language and Siri language use the same supported language before retrying.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: localeWasSupported,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .modelNotReady:
            return ModelDiagnostic(
                isReady: false,
                title: "Model not ready",
                detail:
                    "Apple reports only that the model is not ready; the public API does not provide download progress or a more specific cause. Keep the iPhone on power and Wi-Fi, then try again later.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: localeWasSupported,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .unknownUnavailable:
            return ModelDiagnostic(
                isReady: false,
                title: "Model unavailable",
                detail:
                    "Apple reported an availability state this app does not recognize. Eligible alerts stay on this device until local parsing is available.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: localeWasSupported,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        }
    }

    private static func availabilityState(
        _ availability: SystemLanguageModel.Availability
    ) -> ModelAvailabilityDiagnosticState {
        switch availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            .modelNotReady
        case .unavailable:
            .unknownUnavailable
        }
    }
}
