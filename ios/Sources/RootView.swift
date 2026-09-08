import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: UsageModel

    var body: some View {
        NavigationStack {
            Group {
                if model.needsOnboarding {
                    OnboardingView()
                } else {
                    MainView()
                }
            }
        }
        .task { model.start() }
    }
}
