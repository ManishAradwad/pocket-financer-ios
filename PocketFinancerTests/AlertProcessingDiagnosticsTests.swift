import XCTest

@testable import PocketFinancer

final class AlertProcessingDiagnosticsTests: XCTestCase {
    @MainActor
    func testFoundationModelContractBuildsSenderIndependentPrompt() {
        let body = "Rs.500.00 debited from a/c XX0000"
        let prompt = FoundationModelExtractionContract.requestPrompt(
            body: body,
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertTrue(prompt.contains(body))
        XCTAssertTrue(prompt.contains("<alert>"))
        XCTAssertTrue(prompt.contains("</alert>"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("sender"))
        XCTAssertEqual(
            FoundationModelExtractionContract.currentLocaleIdentifier,
            Locale.current.identifier
        )
        XCTAssertEqual(
            FoundationModelExtractionContract.timeoutDescription,
            "Cancellation requested after 60 seconds"
        )
    }

    @MainActor
    func testFilterTraceMakesSenderIndependenceAndEveryPassedStageVisible() {
        let first = AlertFilter().trace(
            sender: "AX-HDFCBK",
            body: TestFixtures.validBody
        )
        let second = AlertFilter().trace(
            sender: "+919999999999",
            body: TestFixtures.validBody
        )

        XCTAssertFalse(first.senderWasUsed)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.result.isEligible)
        XCTAssertEqual(first.stages.map(\.state), Array(repeating: .passed, count: 8))
    }

    @MainActor
    func testFilterTraceShowsFailureAndSkippedStagesInPipelineOrder() {
        let trace = AlertFilter().trace(
            sender: "anything",
            body: "Offer on Card XX1234: get Rs.100 cashback"
        )

        XCTAssertEqual(trace.result.rejectionCode, .promotion)
        XCTAssertEqual(
            trace.stages.map(\.state),
            [.passed, .passed, .passed, .passed, .failed, .notRun, .notRun, .notRun]
        )
    }

    @MainActor
    func testSafeCodePresentationAndDurationFormatting() {
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "model_timed_out"),
            ProcessingCodePresentation(
                title: "Attempt timed out",
                detail:
                    "Pocket Financer requested cancellation after 60 seconds. Apple's model may take additional time to release the local request."
            )
        )
        XCTAssertEqual(AlertProcessingDiagnostics.durationText(0.4), "Under 1 second")
        XCTAssertEqual(AlertProcessingDiagnostics.durationText(12.34), "12.3 seconds")
        XCTAssertEqual(AlertProcessingDiagnostics.durationText(65), "1m 5s")
    }

    @MainActor
    func testAttemptDurationIsUnavailableWhileProcessingAndNeverNegative() {
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertNil(
            AlertProcessingDiagnostics.attemptDuration(
                lastAttemptAt: start,
                updatedAt: start.addingTimeInterval(2),
                status: .processing
            )
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.attemptDuration(
                lastAttemptAt: start,
                updatedAt: start.addingTimeInterval(-2),
                status: .needsReview
            ),
            0
        )
    }
}
