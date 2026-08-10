import Foundation
import XCTest

@testable import PocketFinancer

private actor ModelExecutionProbe {
    private var active = 0
    private(set) var maximumActive = 0

    func run() async {
        active += 1
        maximumActive = max(maximumActive, active)
        try? await Task.sleep(for: .milliseconds(20))
        active -= 1
    }
}

private actor AsyncTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

final class FoundationModelExecutionGateTests: XCTestCase {
    func testSerializesConcurrentOperations() async throws {
        let gate = FoundationModelExecutionGate()
        let probe = ModelExecutionProbe()

        async let first: Void = gate.withPermit { await probe.run() }
        async let second: Void = gate.withPermit { await probe.run() }
        async let third: Void = gate.withPermit { await probe.run() }

        _ = try await (first, second, third)
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(maximumActive, 1)
    }

    func testCancelledWaiterDoesNotBlockFollowingOperation() async throws {
        let gate = FoundationModelExecutionGate()
        let firstAcquired = AsyncTestLatch()
        let releaseFirst = AsyncTestLatch()

        let first = Task {
            try await gate.withPermit {
                await firstAcquired.open()
                await releaseFirst.wait()
                return 1
            }
        }
        await firstAcquired.wait()

        let cancelled = Task {
            try await gate.withPermit { 2 }
        }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()

        let following = Task {
            try await gate.withPermit { 3 }
        }
        await releaseFirst.open()

        let firstValue = try await first.value
        XCTAssertEqual(firstValue, 1)
        do {
            _ = try await cancelled.value
            XCTFail("Expected the queued operation to be cancelled")
        } catch is CancellationError {
            // Expected. The following waiter must still receive the permit.
        }
        let followingValue = try await following.value
        XCTAssertEqual(followingValue, 3)
    }
}
