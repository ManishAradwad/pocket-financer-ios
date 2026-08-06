import SwiftUI

@main
struct PocketFinancerApp: App {
    var body: some Scene {
        WindowGroup {
            StoreBootstrapView()
        }
    }
}

enum AppPreferenceKey {
    static let completedOnboarding = "onboarding.completed.v1"
}
