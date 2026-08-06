import SwiftData
import XCTest

@testable import PocketFinancer

final class PocketFinancerSchemaMigrationTests: XCTestCase {
    /// Production retains its shared container for the app process lifetime. Mirror that
    /// lifetime here because SwiftData can still be delivering a post-migration Core Data
    /// notification when `ModelContainer` returns. Releasing the migrated container inside
    /// an `autoreleasepool` races that notification on the iOS 26 simulator and aborts in
    /// `ModelContainer` teardown after every migration assertion has already passed.
    @MainActor private static var retainedMigratedStores: [(AppDatabase, URL)] = []

    @MainActor
    func testLightweightMigrationFromV1PreservesExistingModelsAndAddsExtractionRuns() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerMigration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var alertID: UUID?
        try autoreleasepool {
            let schema = Schema(versionedSchema: PocketFinancerSchemaV1.self)
            let configuration = ModelConfiguration(
                "PocketFinancerV1MigrationTest",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = container.mainContext
            let alert = InboxAlert(
                sourceIdentity: "migration-source",
                contentDigest: "migration-digest",
                origin: .manual,
                sourceApplication: "Messages",
                sender: "legacy-sender",
                rawBody: TestFixtures.validBody,
                receivedAt: TestFixtures.receivedAt
            )
            alertID = alert.id
            context.insert(alert)
            try context.save()
        }

        try autoreleasepool {
            let migratedDatabase = try AppDatabase(storeURL: storeURL)
            Self.retainedMigratedStores.append((migratedDatabase, directoryURL))
            let context = migratedDatabase.container.mainContext
            let alerts = try context.fetch(FetchDescriptor<InboxAlert>())

            XCTAssertEqual(alerts.count, 1)
            XCTAssertEqual(alerts.first?.id, alertID)
            XCTAssertEqual(alerts.first?.rawBody, TestFixtures.validBody)
            XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)
        }
    }
}
