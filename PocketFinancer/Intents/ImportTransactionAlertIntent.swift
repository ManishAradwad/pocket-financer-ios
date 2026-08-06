import AppIntents
import Foundation

enum ImportTransactionAlertIntentError: Error, LocalizedError, Sendable {
    case localStoreUnavailable
    case notSaved

    var errorDescription: String? {
        switch self {
        case .localStoreUnavailable:
            "Pocket Financer could not access its protected local store. This alert was not saved. Open Pocket Financer, retry local storage, then run this action again."
        case .notSaved:
            "Pocket Financer could not commit this alert to local storage. This alert was not saved. Open Pocket Financer, then run this action again."
        }
    }
}

struct ImportTransactionAlertIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Transaction Alert"
    static let description = IntentDescription(
        "Saves a transaction alert locally for Pocket Financer to process later on this iPhone."
    )
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(
        title: "Message Body",
        description: "The complete text of the incoming alert",
        inputOptions: .init(multiline: true),
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var body: String

    @Parameter(title: "Sender")
    var sender: String?

    @Parameter(title: "Received At")
    var receivedAt: Date?

    @Parameter(title: "Source Application")
    var sourceApplication: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Import transaction alert from \(\.$body)")
    }

    init() {}

    init(body: String, sender: String? = nil, receivedAt: Date? = nil, sourceApplication: String? = nil) {
        self.body = body
        self.sender = sender
        self.receivedAt = receivedAt
        self.sourceApplication = sourceApplication
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let receipt = try await AlertIngestionService.enqueueLive(
                body: body,
                sender: sender,
                receivedAt: receivedAt,
                sourceApplication: sourceApplication,
                origin: .shortcut
            )
            return .result(
                value: receipt.disposition.rawValue,
                dialog: IntentDialog(stringLiteral: receipt.safeDialog)
            )
        } catch AlertIngestionError.storeUnavailable {
            throw ImportTransactionAlertIntentError.localStoreUnavailable
        } catch {
            throw ImportTransactionAlertIntentError.notSaved
        }
    }
}
