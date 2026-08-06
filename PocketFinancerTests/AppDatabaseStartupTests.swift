import SwiftData
import XCTest

@testable import PocketFinancer

final class AppDatabaseStartupTests: XCTestCase {
    /// Production keeps its database alive for the process lifetime. Keep a successfully
    /// opened compatibility fixture alive too, because iOS 26 SwiftData can abort if a
    /// freshly opened `ModelContainer` is released while its startup notifications drain.
    @MainActor private static var retainedCompatibleStores: [(AppDatabase, URL)] = []

    func testObservedUnknownModelErrorUsesSafeDiagnosticWithoutUnderlyingDetails() {
        let sensitiveDescription = "Store at /private/example contained a sensitive alert body"
        let modelError = NSError(
            domain: NSCocoaErrorDomain,
            code: 134_504,
            userInfo: [NSLocalizedDescriptionKey: sensitiveDescription]
        )
        let outerError = NSError(
            domain: NSCocoaErrorDomain,
            code: 134_080,
            userInfo: [NSUnderlyingErrorKey: modelError]
        )

        let failure = AppDatabaseStartupFailure(classifying: outerError, phase: .openingStore)

        XCTAssertEqual(failure.kind, .unrecognizedStoreModel)
        XCTAssertEqual(failure.safeCode, "store_model_unrecognized")
        XCTAssertEqual(failure.diagnosticCode, "NSCocoaErrorDomain/134504")
        XCTAssertFalse(failure.diagnosticCode.contains(sensitiveDescription))
        XCTAssertFalse(String(describing: failure).contains(sensitiveDescription))
    }

    func testUnknownErrorDomainIsNotExposedToTheUser() {
        let error = NSError(
            domain: "private.store.path.and.vendor.details",
            code: 91,
            userInfo: [NSLocalizedDescriptionKey: "private message body"]
        )

        let failure = AppDatabaseStartupFailure(classifying: error, phase: .openingStore)

        XCTAssertEqual(failure.kind, .storeOpenFailed)
        XCTAssertEqual(failure.diagnosticCode, "StoreInitializationError/91")
        XCTAssertFalse(failure.diagnosticCode.contains(error.domain))
        XCTAssertFalse(String(describing: failure).contains("private message body"))
    }

    @MainActor
    func testLiveIngestionFailsInsteadOfClaimingAnUnavailableStoreQueuedTheAlert() async throws {
        do {
            _ = try await AlertIngestionService.ingestLive(
                body: TestFixtures.validBody,
                sender: "SYNTHETIC-SENDER",
                receivedAt: TestFixtures.receivedAt,
                sourceApplication: "Messages",
                origin: .shortcut,
                openDatabase: {
                    throw AppDatabaseStartupFailure(
                        kind: .storeOpenFailed,
                        diagnosticCode: "StoreInitializationError/91"
                    )
                }
            )
            XCTFail("An unavailable store must not produce a successful ingestion receipt")
        } catch let error as AlertIngestionError {
            XCTAssertEqual(error, .storeUnavailable)
        }
    }

    func testIntentStoreFailureExplicitlySaysTheAlertWasNotSaved() {
        let message = ImportTransactionAlertIntentError.localStoreUnavailable.errorDescription ?? ""

        XCTAssertTrue(message.contains("This alert was not saved"))
        XCTAssertTrue(message.contains("Open Pocket Financer"))
        XCTAssertFalse(message.contains(TestFixtures.validBody))
        XCTAssertFalse(message.contains("SYNTHETIC-SENDER"))
    }

    @MainActor
    func testPreBaselineUnversionedStorePreservesEvidenceWhetherOpenedOrRejected() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerPreBaseline-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        var retainedForProcessLifetime = false
        defer {
            if !retainedForProcessLifetime {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let legacySchema = Schema([InboxAlert.self, Transaction.self, Account.self])
        let expectedID = UUID()

        try autoreleasepool {
            let configuration = ModelConfiguration(
                "PocketFinancerPreBaselineWriter",
                schema: legacySchema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: legacySchema, configurations: configuration)
            let context = container.mainContext
            context.insert(
                InboxAlert(
                    id: expectedID,
                    sourceIdentity: "synthetic-pre-baseline-source",
                    contentDigest: "synthetic-pre-baseline-digest",
                    origin: .manual,
                    sourceApplication: "Messages",
                    sender: "SYNTHETIC-SENDER",
                    rawBody: TestFixtures.validBody,
                    receivedAt: TestFixtures.receivedAt
                )
            )
            try context.save()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        do {
            let database = try AppDatabase(storeURL: storeURL)
            Self.retainedCompatibleStores.append((database, directoryURL))
            retainedForProcessLifetime = true
            let alerts = try database.container.mainContext.fetch(FetchDescriptor<InboxAlert>())
            XCTAssertEqual(alerts.count, 1)
            XCTAssertEqual(alerts.first?.id, expectedID)
            XCTAssertEqual(alerts.first?.rawBody, TestFixtures.validBody)
        } catch {
            guard let failure = error as? AppDatabaseStartupFailure else {
                return XCTFail("Expected a sanitized AppDatabaseStartupFailure")
            }
            XCTAssertEqual(failure.kind, .unrecognizedStoreModel)

            try autoreleasepool {
                let configuration = ModelConfiguration(
                    "PocketFinancerPreBaselineReader",
                    schema: legacySchema,
                    url: storeURL,
                    allowsSave: true,
                    cloudKitDatabase: .none
                )
                let container = try ModelContainer(for: legacySchema, configurations: configuration)
                let alerts = try container.mainContext.fetch(FetchDescriptor<InboxAlert>())

                XCTAssertEqual(alerts.count, 1)
                XCTAssertEqual(alerts.first?.id, expectedID)
                XCTAssertEqual(alerts.first?.rawBody, TestFixtures.validBody)
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }
}
