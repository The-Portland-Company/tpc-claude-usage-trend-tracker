import SwiftUI

/// Keeps the menu-bar agent resident. Without this, macOS treats an idle
/// `LSUIElement` app with no open windows as eligible for sudden/automatic
/// termination and quietly kills it after a while — no crash report, the icon
/// just vanishes. We opt out of both and hold a background activity assertion
/// so App Nap can't suspend the poll timer into oblivion.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Move an existing login-item registration onto the bundled launch agent,
        // which relaunches us if macOS kills the app mid-session. One-time, no-ops after.
        LaunchAtLogin.migrateFromLoginItem()
        // Reaching here as a hand-opened copy means launchd is not running the app:
        // the single-instance lock was free, so either the agent was never registered
        // or the job it registered can no longer spawn — which is what happens after
        // an update replaces the bundle launchd recorded. Either way, re-register
        // against the bundle on disk and step aside so launchd's RunAtLoad copy is the
        // one that stays. Drop the lock first, or that copy finds it held and exits.
        if LaunchAtLogin.shouldHandOverToLaunchd {
            ResidentAgent.releaseInstanceLock()
            if LaunchAtLogin.handOverToLaunchd() {
                exit(0)
            }
            ResidentAgent.reacquireInstanceLock()   // registration failed; stay resident
        }
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar agent must stay resident to track usage")
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.background, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Continuous Claude usage polling")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ClaudeUsageTrendTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: UsageModel
    @State private var started = false

    init() {
        // Must run before anything touches `URLSession.shared` — it snapshots
        // `URLCache.shared` on first use, and UsageModel builds a UsageClient off it.
        ResidentAgent.exitIfAlreadyRunning()
        ResidentAgent.disableURLCache()
        _model = State(initialValue: UsageModel())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
                .task {
                    if !started { started = true; model.start() }
                }
        } label: {
            MenuBarLabelView(items: model.menuBarItems, style: model.menuBarStyle)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
