import SwiftUI

@main
struct ClaudeMeterApp: App {
    @StateObject private var model = UsageModel()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
        }
    }
}
