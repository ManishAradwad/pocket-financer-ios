import SwiftUI
import XCTest

@testable import PocketFinancer

final class AppRootViewTests: XCTestCase {
    @MainActor
    func testPendingDrainRequiresCompletedOnboardingAndActiveScene() {
        XCTAssertTrue(
            PendingAlertDrainPolicy.mayDrain(
                completedOnboarding: true,
                scenePhase: .active
            )
        )

        for phase in [ScenePhase.inactive, .background] {
            XCTAssertFalse(
                PendingAlertDrainPolicy.mayDrain(
                    completedOnboarding: true,
                    scenePhase: phase
                )
            )
        }

        XCTAssertFalse(
            PendingAlertDrainPolicy.mayDrain(
                completedOnboarding: false,
                scenePhase: .active
            )
        )
    }
}
