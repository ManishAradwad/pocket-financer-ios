import Foundation
import SwiftData

struct StorageDiagnostic: Equatable, Sendable {
    let pending: Int
    let needsReview: Int
    let imported: Int
    let rejected: Int
    let duplicates: Int
}

@MainActor
struct LocalDataService {
    let context: ModelContext

    func diagnostics() -> StorageDiagnostic {
        let alerts = (try? context.fetch(FetchDescriptor<InboxAlert>())) ?? []
        return StorageDiagnostic(
            pending: alerts.count { $0.status == .pending || $0.status == .processing },
            needsReview: alerts.count { $0.status == .needsReview },
            imported: alerts.count { $0.status == .imported },
            rejected: alerts.count { $0.status == .rejected },
            duplicates: alerts.count { $0.status == .duplicate }
        )
    }

    func eraseAll() throws {
        // Prevent suspended parser work from writing ledger rows after the owner has
        // completed an erase. Existing model work may finish in memory, but it no
        // longer owns permission to mutate the protected store.
        AlertIngestionService.invalidateAllProcessingClaims()

        do {
            for run in try context.fetch(FetchDescriptor<ExtractionRun>()) {
                context.delete(run)
            }
            for transaction in try context.fetch(FetchDescriptor<Transaction>()) {
                context.delete(transaction)
            }
            for account in try context.fetch(FetchDescriptor<Account>()) {
                context.delete(account)
            }
            for alert in try context.fetch(FetchDescriptor<InboxAlert>()) {
                context.delete(alert)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
