import SwiftUI

@main
struct ClaudeUsageTrendTrackerApp: App {
    @State private var model = UsageModel()
    @State private var started = false

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
                .task {
                    if !started { started = true; model.start() }
                }
        } label: {
            let tint = Color.menuBarTint(model.menuSeverity)
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(model.menuTitle)
            }
            .foregroundStyle(tint)
        }
        .menuBarExtraStyle(.window)
    }
}
