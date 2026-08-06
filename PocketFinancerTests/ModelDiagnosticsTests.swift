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
}
