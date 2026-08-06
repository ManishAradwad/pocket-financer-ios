import Foundation

/// The owner-visible contract for every Apple Foundation Models extraction request.
///
/// Keep request construction here so the parser and the transparency UI can never
/// silently drift apart. The exact strings may be persisted only in a protected local
/// `ExtractionRun` audit record. They must never enter logs, telemetry, exports, or reports.
enum FoundationModelExtractionContract {
    static let parserName = "Apple Foundation Models"
    static let contractVersion = "foundation-transaction-extraction.v1"
    static let extractionProfileVersion = "1"
    static let timeout: Duration = .seconds(60)
    static let timeoutDescription = "Cancellation requested after 60 seconds"
    static let guardrailsDescription = "Apple default guardrails"
    static let requestSchedulingDescription = "Serialized — one model request at a time"

    static var currentLocaleIdentifier: String {
        Locale.current.identifier
    }

    static let structuredSchemaMapping = [
        "kind → classification and debit/credit direction",
        "amountText → amountText",
        "merchantText → merchant",
        "accountText → accountLabel",
        "dateText → occurredAtText",
        "currencyCode → currencyCode",
    ]

    static let instructions = """
        You extract one completed financial transaction from an Indian bank alert.
        Copy evidence exactly from the supplied alert. Never invent, normalize, calculate,
        translate, or infer a missing amount, date, merchant, or account. Classify OTPs,
        payment or collect requests, mandates, offers, due notices, balance-only alerts,
        and unsuccessful transactions as nonFinancial. A refund or reversal is a credit.
        You MUST respond in U.S. English while preserving evidence text verbatim.
        """

    /// Sender labels vary across banks and carriers, so they are deliberately excluded.
    static func requestPrompt(body: String, receivedAt: Date) -> String {
        """
        Supplied or local receipt time: \(receivedAt.formatted(.iso8601))
        Alert body follows between markers.
        <alert>
        \(body)
        </alert>
        """
    }
}
