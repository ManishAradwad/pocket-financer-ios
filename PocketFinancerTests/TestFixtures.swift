import Foundation

@testable import PocketFinancer

enum TestFixtures {
    static let receivedAt = Date(timeIntervalSince1970: 1_785_955_200)
    static let parserRequestMetadata = TransactionParserRequestMetadata(
        localeIdentifier: "en-US",
        localeWasSupported: true,
        supportedLanguageIdentifiers: ["en", "hi"]
    )

    static let validBody = "HDFC Bank: Rs.500.00 debited from a/c XXXXXX0000 on 05-08-2026 at Demo Store."

    static let validDraft = ParsedAlertDraft(
        classification: .transaction,
        direction: "debit",
        amountText: "Rs.500.00",
        merchant: "Demo Store",
        accountLabel: "a/c XXXXXX0000",
        occurredAtText: "05-08-2026",
        currencyCode: "INR"
    )

    static let reviewDraft = ParsedAlertDraft(
        classification: .transaction,
        direction: "debit",
        amountText: "Rs.500.00",
        merchant: "",
        accountLabel: "a/c XXXXXX0000",
        occurredAtText: "",
        currencyCode: "INR"
    )
}

@MainActor
struct FakeTransactionParser: TransactionParsing {
    let parserName: String
    let requestMetadata: TransactionParserRequestMetadata
    let result: Result<ParsedAlertDraft, TransactionParserError>

    init(
        parserName: String = "Deterministic Test Parser",
        requestMetadata: TransactionParserRequestMetadata = TestFixtures.parserRequestMetadata,
        result: Result<ParsedAlertDraft, TransactionParserError>
    ) {
        self.parserName = parserName
        self.requestMetadata = requestMetadata
        self.result = result
    }

    func parse(body: String, sender: String, receivedAt: Date) async throws -> ParsedAlertDraft {
        try result.get()
    }
}

@MainActor
struct SlowTransactionParser: TransactionParsing {
    let parserName = "Slow Test Parser"
    let requestMetadata = TestFixtures.parserRequestMetadata

    func parse(body: String, sender: String, receivedAt: Date) async throws -> ParsedAlertDraft {
        try await Task.sleep(for: .seconds(5))
        return TestFixtures.validDraft
    }
}

@MainActor
struct InspectingTransactionParser: TransactionParsing {
    let parserName = "Inspecting Test Parser"
    let requestMetadata = TestFixtures.parserRequestMetadata
    let inspectBeforeResponse: @MainActor @Sendable () throws -> Void

    func parse(body: String, sender: String, receivedAt: Date) async throws -> ParsedAlertDraft {
        try inspectBeforeResponse()
        return TestFixtures.validDraft
    }
}

@MainActor
struct StreamingTransactionParser: TransactionParsing {
    let parserName = "Streaming Test Parser"
    let requestMetadata = TestFixtures.parserRequestMetadata
    let snapshots: [TransactionParserGenerationSnapshot]
    let draft: ParsedAlertDraft

    func parse(body: String, sender: String, receivedAt: Date) async throws -> ParsedAlertDraft {
        draft
    }

    func parse(
        body: String,
        sender: String,
        receivedAt: Date,
        progress: @escaping TransactionParserProgressHandler
    ) async throws -> ParsedAlertDraft {
        try await progress(.requestQueued(at: receivedAt))
        try await progress(.generationStarted(at: receivedAt))
        for snapshot in snapshots {
            try await progress(.generationSnapshot(snapshot))
        }
        try await progress(.generationCompleted(at: snapshots.last?.capturedAt ?? receivedAt))
        return draft
    }
}

@MainActor
struct ErasingStreamingTransactionParser: TransactionParsing {
    let parserName = "Erasing Streaming Test Parser"
    let requestMetadata = TestFixtures.parserRequestMetadata
    let snapshots: [TransactionParserGenerationSnapshot]
    let draft: ParsedAlertDraft
    let eraseDuringGeneration: @MainActor @Sendable () throws -> Void

    func parse(body: String, sender: String, receivedAt: Date) async throws -> ParsedAlertDraft {
        try eraseDuringGeneration()
        return draft
    }

    func parse(
        body: String,
        sender: String,
        receivedAt: Date,
        progress: @escaping TransactionParserProgressHandler
    ) async throws -> ParsedAlertDraft {
        try await progress(.requestQueued(at: receivedAt))
        try await progress(.generationStarted(at: receivedAt))
        if let first = snapshots.first {
            try await progress(.generationSnapshot(first))
        }
        try eraseDuringGeneration()
        for snapshot in snapshots.dropFirst() {
            try await progress(.generationSnapshot(snapshot))
        }
        try await progress(.generationCompleted(at: snapshots.last?.capturedAt ?? receivedAt))
        return draft
    }
}
