import SwiftData

enum PocketFinancerSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [InboxAlert.self, Transaction.self, Account.self]
    }
}

enum PocketFinancerSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [InboxAlert.self, Transaction.self, Account.self, ExtractionRun.self]
    }
}

enum PocketFinancerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PocketFinancerSchemaV1.self, PocketFinancerSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: PocketFinancerSchemaV1.self,
                toVersion: PocketFinancerSchemaV2.self
            )
        ]
    }
}
