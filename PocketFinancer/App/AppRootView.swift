import SwiftData
import SwiftUI

struct AppRootView: View {
    @AppStorage(AppPreferenceKey.completedOnboarding) private var completedOnboarding = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Group {
                if completedOnboarding {
                    MainTabView()
                } else {
                    OnboardingView {
                        completedOnboarding = true
                    }
                }
            }

            if scenePhase != .active {
                PrivacyShieldView()
                    .zIndex(100)
            }
        }
        .task {
            await drainPendingAlerts()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, completedOnboarding else { return }
            Task { await drainPendingAlerts() }
        }
    }

    private func drainPendingAlerts() async {
        guard completedOnboarding else { return }
        let service = AlertIngestionService(context: modelContext)
        _ = await service.processPending()
    }
}

struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "indianrupeesign.circle.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Pocket Financer")
                    .font(.title2.bold())
                Label("Protected while inactive", systemImage: "lock.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pocket Financer is protected while inactive")
    }
}

struct SensitiveSceneCoverModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        ZStack {
            content
            if scenePhase != .active {
                PrivacyShieldView()
                    .zIndex(100)
            }
        }
    }
}

extension View {
    func sensitiveSceneCover() -> some View {
        modifier(SensitiveSceneCoverModifier())
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView()
            }

            Tab("Transactions", systemImage: "list.bullet.rectangle.portrait.fill") {
                TransactionsView()
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .accessibilityIdentifier("main-tab-view")
    }
}
