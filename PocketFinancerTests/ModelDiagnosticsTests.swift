import Foundation
import XCTest

@testable import PocketFinancer

final class ModelDiagnosticsTests: XCTestCase {
    @MainActor
    func testSupportedLocaleDiagnosticPreservesExactLocaleAndSortedLanguages() {
        let diagnostic = ModelDiagnostics.makeDiagnostic(
            availability: .available,
            localeIdentifier: "en-US",
            localeWasSupported: true,
            localeSupportProbes: localeSupportProbes(currentSupported: true),
            supportedLanguageIdentifiers: ["hi", "en", "en"]
        )

        XCTAssertTrue(diagnostic.isReady)
        XCTAssertEqual(diagnostic.localeIdentifier, "en-US")
        XCTAssertTrue(diagnostic.localeWasSupported)
        XCTAssertEqual(diagnostic.formattingLocaleIdentifier, "en_IN")
        XCTAssertEqual(diagnostic.supportedLanguageIdentifiers, ["en", "hi"])
        XCTAssertEqual(diagnostic.supportedLanguageSummary, "en, hi")
    }

    @MainActor
    func testUnsupportedModelLocaleExplainsLanguageAlignmentAndKeepsIndiaRegion() {
        let diagnostic = ModelDiagnostics.makeDiagnostic(
            availability: .available,
            localeIdentifier: "zz_IN",
            localeWasSupported: false,
            localeSupportProbes: localeSupportProbes(currentSupported: false),
            supportedLanguageIdentifiers: ["en", "hi"]
        )

        XCTAssertFalse(diagnostic.isReady)
        XCTAssertEqual(diagnostic.title, "Model processing language unsupported")
        XCTAssertTrue(diagnostic.detail.contains("iPhone and Siri languages"))
        XCTAssertTrue(diagnostic.detail.contains("region can remain India"))
    }

    @MainActor
    func testModelNotReadyDoesNotClaimPrivateDownloadReason() {
        let diagnostic = ModelDiagnostics.makeDiagnostic(
            availability: .modelNotReady,
            localeIdentifier: "en-US",
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
    func testLocaleSupportProbesSeparateModelLanguageFromPhoneFormatting() {
        let probes = ModelDiagnostics.makeLocaleSupportProbes(
            modelLocale: Locale(identifier: "en-US"),
            modelLocaleWasSupported: true,
            formattingLocale: Locale(identifier: "en_IN")
        )

        XCTAssertEqual(
            probes,
            [
                ModelLocaleSupportProbe(
                    label: "Model processing locale",
                    localeIdentifier: "en-US",
                    isSupported: true
                ),
                ModelLocaleSupportProbe(
                    label: "Phone formatting locale",
                    localeIdentifier: "en_IN",
                    isSupported: nil
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
            processingLocale: Locale(identifier: "en-US"),
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
                label: "Model processing locale",
                localeIdentifier: "en-US",
                isSupported: currentSupported
            ),
            ModelLocaleSupportProbe(
                label: "Phone formatting locale",
                localeIdentifier: "en_IN",
                isSupported: nil
            ),
        ]
    }
}
