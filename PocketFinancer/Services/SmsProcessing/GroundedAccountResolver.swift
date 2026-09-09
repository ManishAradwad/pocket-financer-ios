import Foundation
import SwiftData

enum SmsAccountResolution: Equatable, Sendable {
    case missing
    case unresolved
    case ambiguous(accountIDs: [UUID])
    case unique(accountID: UUID)
}

@MainActor
struct GroundedAccountResolver {
    let context: ModelContext

    func resolve(_ sourceGroundedIdentifier: String?) throws -> SmsAccountResolution {
        guard let sourceGroundedIdentifier else { return .missing }
        let normalized = sourceGroundedIdentifier.precomposedStringWithCompatibilityMapping
            .lowercased().split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        let aliasHash = CanonicalJSON.sha256(normalized)
        let confirmed = true
        let aliases = try context.fetch(
            FetchDescriptor<SmsAccountAlias>(
                predicate: #Predicate {
                    $0.normalizedAliasHash == aliasHash && $0.confirmedByUser == confirmed
                })
        )
        let accountIDs = Array(Set(aliases.map(\.accountID))).sorted {
            $0.uuidString < $1.uuidString
        }
        return switch accountIDs.count {
        case 0: .unresolved
        case 1: .unique(accountID: accountIDs[0])
        default: .ambiguous(accountIDs: accountIDs)
        }
    }
}
