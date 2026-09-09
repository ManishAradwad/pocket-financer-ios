import XCTest

@testable import PocketFinancer

@MainActor
final class ModelSelfTestServiceTests: XCTestCase {
    func testGroundedSelectorPassesThroughRealShadowCoordinator() async throws {
        let receivedAt = Date(timeIntervalSince1970: 1_785_955_200.125)

        let result = await ModelSelfTestService.run(
            selector: GroundedSelfTestSelector(),
            receivedAt: receivedAt
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.contractVersion, "pocketfinancer.grounded-candidate-selector-input/1")
        XCTAssertEqual(result.generationMode, "DIRECT_NON_THINKING")
        XCTAssertEqual(result.outputCompletion, "complete")
        XCTAssertEqual(result.syntheticBody, ModelSelfTestService.syntheticBody)
        XCTAssertEqual(result.syntheticSender, ModelSelfTestService.syntheticSender)
        XCTAssertEqual(result.receivedAt, receivedAt)
        XCTAssertEqual(result.settlement, "retained_for_review")
        XCTAssertNil(result.failure)
        XCTAssertNotNil(result.analysisJSON)
        XCTAssertTrue(result.exactRequest.contains("grounded-candidate-selector-input/1"))
        XCTAssertTrue(result.exactOutput?.contains(#""decision":"posted""#) == true)
        XCTAssertGreaterThanOrEqual(result.completedAt, result.startedAt)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0)
        XCTAssertEqual(result.apiLimitations, ModelSelfTestService.apiLimitations)
        XCTAssertTrue(result.apiLimitations.contains { $0.metric.localizedCaseInsensitiveContains("token") })
        XCTAssertTrue(result.apiLimitations.contains { $0.metric.localizedCaseInsensitiveContains("reasoning") })
    }

    func testUnavailableSelectorFailsClosedAndKeepsLedgerEmpty() async {
        let result = await ModelSelfTestService.run(
            selector: FailingSelfTestSelector(),
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.settlement, "retained_for_review")
        XCTAssertEqual(result.outputCompletion, "failed")
        XCTAssertNil(result.exactOutput)
        XCTAssertEqual(result.failure?.safeCode, "runtime_unavailable")
        XCTAssertEqual(result.failure?.isRetryable, true)
        XCTAssertTrue(result.summary.localizedCaseInsensitiveContains("did not produce"))
    }

    func testForeignCandidateOutputFailsClosed() async {
        let result = await ModelSelfTestService.run(
            selector: ForeignCandidateSelfTestSelector(),
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.settlement, "retained_for_review")
        XCTAssertEqual(result.failure?.safeCode, "selector_unknown_or_cross_message_candidate")
        XCTAssertEqual(result.failure?.isRetryable, false)
    }
}

private struct GroundedSelfTestSelector: DirectCandidateSelecting {
    func select(source: String, analysis: SmsAnalysis) async throws -> DirectSelectorResponse {
        let amount = try requiredCandidate(.amount, in: analysis)
        let direction = try requiredCandidate(.direction, in: analysis)
        let account = try requiredCandidate(.account, in: analysis)
        let counterparty = try requiredCandidate(.counterparty, in: analysis)
        let rawOutput =
            #"{"account":"\#(account.id)","amount":"\#(amount.id)","counterparty":"\#(counterparty.id)","decision":"posted","direction":"\#(direction.id)"}"#
        return DirectSelectorResponse(
            rawOutput: rawOutput,
            runtimeProfileJSON: #"{"generation_mode":"DIRECT_NON_THINKING"}"#,
            requestJSON: try FoundationDirectCandidateSelector.requestJSON(
                source: source,
                analysis: analysis
            ),
            completion: "complete"
        )
    }

    private func requiredCandidate(
        _ kind: SmsCandidateKind,
        in analysis: SmsAnalysis
    ) throws -> SmsCandidate {
        guard let candidate = analysis.candidates.first(where: { $0.kind == kind }) else {
            throw SelfTestSelectorError.missingCandidate
        }
        return candidate
    }
}

private struct FailingSelfTestSelector: DirectCandidateSelecting {
    func select(source _: String, analysis _: SmsAnalysis) async throws -> DirectSelectorResponse {
        throw TransactionParserError.modelUnavailable(.modelNotReady)
    }
}

private struct ForeignCandidateSelfTestSelector: DirectCandidateSelecting {
    func select(source: String, analysis: SmsAnalysis) async throws -> DirectSelectorResponse {
        DirectSelectorResponse(
            rawOutput:
                #"{"account":"foreign","amount":"foreign","counterparty":"foreign","decision":"posted","direction":"foreign"}"#,
            runtimeProfileJSON: #"{"generation_mode":"DIRECT_NON_THINKING"}"#,
            requestJSON: try FoundationDirectCandidateSelector.requestJSON(
                source: source,
                analysis: analysis
            ),
            completion: "complete"
        )
    }
}

private enum SelfTestSelectorError: Error {
    case missingCandidate
}
