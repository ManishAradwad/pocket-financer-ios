import Foundation
import XCTest

@testable import PocketFinancer

final class ModelDiagnosticsTests: XCTestCase {
    @MainActor
    func testSupportedLocaleDiagnosticPreservesExactLocaleAndSortedLanguages() {
        let diagnostic = ModelDiagnostics.makeDiagnostic(
            availability: .available,
            localeIdentifier: "en_IN",
            localeWasSupported: true,
            localeSupportProbes: localeSupportProbes(currentSupported: true),
            supportedLanguageIdentifiers: ["hi", "en", "en"]
        )

        XCTAssertTrue(diagnostic.isReady)
        XCTAssertEqual(diagnostic.localeIdentifier, "en_IN")
        XCTAssertTrue(diagnostic.localeWasSupported)
        XCTAssertEqual(diagnostic.supportedLanguageIdentifiers, ["en", "hi"])
        XCTAssertEqual(diagnostic.supportedLanguageSummary, "en, hi")
    }

    @MainActor
    func testUnsupportedLocaleExplainsLanguageAlignmentWithoutInventingCause() {
        let diagnostic = ModelDiagnostics.makeDiagnostic(
            availability: .available,
            localeIdentifier: "zz_IN",
            localeWasSupported: false,
            localeSupportProbes: localeSupportProbes(currentSupported: false),
            supportedLanguageIdentifiers: ["en", "hi"]
        )

        XCTAssertFalse(diagnostic.isReady)
        XCTAssertEqual(diagnostic.title, "Current app locale unsupported")
        XCTAssertTrue(diagnostic.detail.contains("iPhone language and Siri language"))
        XCTAssertTrue(diagnostic.detail.contains("does not identify"))
    }

    @MainActor
    func testModelNotReadyDoesNotClaimPrivateDownloadReason() {
        let diagnostic = ModelDiagnostics.makeDiagnostic(
            availability: .modelNotReady,
            localeIdentifier: "en_IN",
            localeWasSupported: true,
            localeSupportProbes: localeSupportProbes(currentSupported: true),
            supportedLanguageIdentifiers: []
        )

        XCTAssertFalse(diagnostic.isReady)
        XCTAssertTrue(diagnostic.detail.contains("does not provide download progress"))
        XCTAssertEqual(
            diagnostic.supportedLanguageSummary,
            "Not reported by the system model right now"
        )
    }

    @MainActor
    func testLanguageIdentifiersUseStableMinimalIdentifiers() {
        let identifiers = ModelDiagnostics.languageIdentifiers([
            Locale.Language(identifier: "en_US"),
            Locale.Language(identifier: "hi_Deva_IN"),
            Locale.Language(identifier: "en_GB"),
        ])

        XCTAssertEqual(identifiers, identifiers.sorted())
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(identifiers.contains("en"))
        XCTAssertTrue(identifiers.contains("hi"))
    }

    @MainActor
    func testLocaleSupportProbesCompareCurrentIndiaAndUSWithoutChangingCurrentResult() {
        let probes = ModelDiagnostics.makeLocaleSupportProbes(
            currentLocale: Locale(identifier: "en_IN"),
            currentLocaleWasSupported: false,
            supportsLocale: { $0.region?.identifier == "US" }
        )

        XCTAssertEqual(
            probes,
            [
                ModelLocaleSupportProbe(
                    label: "Current app locale (primary)",
                    localeIdentifier: "en_IN",
                    isSupported: false
                ),
                ModelLocaleSupportProbe(
                    label: "English (India) diagnostic",
                    localeIdentifier: "en-IN",
                    isSupported: false
                ),
                ModelLocaleSupportProbe(
                    label: "English (US) control",
                    localeIdentifier: "en-US",
                    isSupported: true
                ),
            ]
        )
    }

    @MainActor
    func testLoadCurrentUsesInjectedProbeOnce() async {
        let expectedDiagnostic = ModelDiagnostics.makeDiagnostic(
            availability: .available,
            localeIdentifier: "background",
            localeWasSupported: true,
            localeSupportProbes: [],
            supportedLanguageIdentifiers: ["en"]
        )
        let calls = CallRecorder()

        let diagnostic = await ModelDiagnostics.loadCurrent(
            locale: Locale(identifier: "en_IN"),
            using: { _ in
                calls.record()
                return expectedDiagnostic
            }
        )

        XCTAssertEqual(diagnostic, expectedDiagnostic)
        XCTAssertEqual(calls.count, 1)
    }

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedCount = 0

        var count: Int {
            lock.withLock { recordedCount }
        }

        func record() {
            lock.withLock {
                recordedCount += 1
            }
        }
    }

    private func localeSupportProbes(currentSupported: Bool) -> [ModelLocaleSupportProbe] {
        [
            ModelLocaleSupportProbe(
                label: "Current app locale (primary)",
                localeIdentifier: "en_IN",
                isSupported: currentSupported
            ),
            ModelLocaleSupportProbe(
                label: "English (India) diagnostic",
                localeIdentifier: "en-IN",
                isSupported: currentSupported
            ),
            ModelLocaleSupportProbe(
                label: "English (US) control",
                localeIdentifier: "en-US",
                isSupported: true
            ),
        ]
    }
}
