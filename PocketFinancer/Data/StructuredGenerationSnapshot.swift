import Foundation
import SwiftData

/// One cumulative, owner-visible structured response emitted during a parser attempt.
///
/// `rawContentJSON` can contain sensitive financial evidence. It belongs only in the
/// protected SwiftData store and must never be written to logs or diagnostics exports.
/// Snapshots reference an `ExtractionRun` by identifier instead of a SwiftData relationship
/// so adding this entity does not change the deployed V2 `ExtractionRun` schema.
@Model
final class StructuredGenerationSnapshot {
    static let currentFormatIdentifier = "foundationmodels.generated-content-json.v1"

    @Attribute(.unique) var id: UUID
    var extractionRunID: UUID
    var sequenceIndex: Int
    var capturedAt: Date
    var rawContentJSON: String
    var isComplete: Bool
    var formatIdentifier: String

    init(
        id: UUID = UUID(),
        extractionRunID: UUID,
        sequenceIndex: Int,
        capturedAt: Date,
        rawContentJSON: String,
        isComplete: Bool,
        formatIdentifier: String = StructuredGenerationSnapshot.currentFormatIdentifier
    ) {
        self.id = id
        self.extractionRunID = extractionRunID
        self.sequenceIndex = sequenceIndex
        self.capturedAt = capturedAt
        self.rawContentJSON = rawContentJSON
        self.isComplete = isComplete
        self.formatIdentifier = formatIdentifier
    }
}
