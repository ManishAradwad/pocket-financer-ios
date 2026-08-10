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

enum PocketFinancerSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            InboxAlert.self,
            Transaction.self,
            Account.self,
            ExtractionRun.self,
            StructuredGenerationSnapshot.self,
        ]
    }
}

enum PocketFinancerSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            InboxAlert.self,
            Transaction.self,
            Account.self,
            ExtractionRun.self,
            StructuredGenerationSnapshot.self,
            DeterministicFilterRun.self,
        ]
    }
}

enum PocketFinancerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            PocketFinancerSchemaV1.self,
            PocketFinancerSchemaV2.self,
            PocketFinancerSchemaV3.self,
            PocketFinancerSchemaV4.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: PocketFinancerSchemaV1.self,
                toVersion: PocketFinancerSchemaV2.self
            ),
            .lightweight(
                fromVersion: PocketFinancerSchemaV2.self,
                toVersion: PocketFinancerSchemaV3.self
            ),
            .lightweight(
                fromVersion: PocketFinancerSchemaV3.self,
                toVersion: PocketFinancerSchemaV4.self
            ),
        ]
    }
}
