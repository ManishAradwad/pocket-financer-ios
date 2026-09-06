import Foundation
import SwiftData

@MainActor
struct SmsOperationSnapshotFactory {
    let context: ModelContext

    func create(
        sourceAlertID: UUID,
        parentOperationID: UUID? = nil,
        trigger: String,
        primaryCurrency: String,
        enabledProfiles: [String],
        selectorModelIdentifier: String,
        selectorRuntimeVersion: String,
        now: Date = .now
    ) throws -> SmsOperationSnapshot {
        let sourceID = sourceAlertID
        let descriptor = FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
        guard let alert = try context.fetch(descriptor).first else {
            throw SmsProcessingStoreError.sourceNotFound
        }
        let operationID = UUID()
        let configuration = SmsOperationConfiguration(
            operationID: operationID,
            parentOperationID: parentOperationID,
            sourceID: sourceAlertID,
            trigger: trigger,
            createdAt: now,
            primaryCurrency: primaryCurrency,
            enabledProfiles: enabledProfiles,
            sourceTimestamp: alert.receivedAt,
            sourceTimestampProvenance: "acquisition_supplied_message_time",
            admissionTimestamp: alert.createdAt,
            timezoneIdentifier: TimeZone.current.identifier,
            selectorModelIdentifier: selectorModelIdentifier,
            selectorRuntimeVersion: selectorRuntimeVersion
        )
        let configurationJSON = try configuration.canonicalJSON
        let configurationHash = try configuration.sha256
        let operation = SmsProcessingOperation(
            id: operationID,
            sourceAlertID: sourceAlertID,
            parentOperationID: parentOperationID,
            trigger: trigger,
            configurationJSON: configurationJSON,
            configurationHash: configurationHash,
            contractReleaseID: SmsOperationConfiguration.releaseID,
            state: .ready,
            createdAt: now
        )
        context.insert(operation)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw SmsProcessingStoreError.saveFailed
        }
        return SmsOperationSnapshot(
            operationID: operationID,
            parentOperationID: parentOperationID,
            stableEventID: operation.stableEventID,
            configuration: configuration,
            configurationJSON: configurationJSON,
            configurationHash: configurationHash
        )
    }
}
