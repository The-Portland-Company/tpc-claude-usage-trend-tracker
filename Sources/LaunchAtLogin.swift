import Foundation
import ServiceManagement

/// Start-at-login, backed by a launch agent bundled at
/// `Contents/Library/LaunchAgents/com.theportlandcompany.ClaudeMeter.Relauncher.plist`.
///
/// This used to register `SMAppService.mainApp`. A login item only ever starts the
/// app at login, so when macOS killed us mid-session to reclaim our container cache
/// (see `ResidentAgent`) the icon stayed gone until the next login — which is exactly
/// how this read to the user: "it disappears every day."
///
/// A launch agent is owned by launchd, which notices the process died and starts it
/// again within a second. `KeepAlive/SuccessfulExit = false` scopes that to *abnormal*
/// exits only: a SIGKILL from cache_delete, a jetsam kill, or a crash all come back,
/// while choosing Quit exits 0 and stays quit.
enum LaunchAtLogin {
    private static let plistName = "com.theportlandcompany.ClaudeMeter.Relauncher.plist"

    private static var service: SMAppService { .agent(plistName: plistName) }

    static var isEnabled: Bool {
        service.status == .enabled
    }

    /// Returns an error message on failure, nil on success.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // Registering an already-registered agent throws; treat that as success.
                guard service.status != .enabled else { return nil }
                try service.register()
            } else {
                guard service.status == .enabled else { return nil }
                try service.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static let autoRegisteredKey = "relauncherAutoRegistered"

    /// True when *this* process is the copy launchd started from the bundled agent.
    ///
    /// launchd puts the job's label in `XPC_SERVICE_NAME`; a copy opened from Finder,
    /// the Dock or LaunchServices has no such variable. This is what tells the app
    /// whether the resident role is already filled or still has to be handed over.
    static var isLaunchdCopy: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == plistName.replacingOccurrences(of: ".plist", with: "")
    }

    /// Re-points launchd at the bundle that is on disk right now.
    ///
    /// `register()` is a no-op once the service is enabled — it does *not* refresh the
    /// executable path launchd recorded the first time. So after the app is replaced
    /// (a TestFlight or App Store update, or a move to a different folder) launchd keeps
    /// the old path, fails to spawn with `EX_CONFIG`, and the agent silently stops
    /// protecting the app while `status` still reads `.enabled`. Unregistering first
    /// forces launchd to record the current bundle.
    @discardableResult
    static func refreshRegistration() -> Bool {
        if service.status == .enabled {
            try? service.unregister()
        }
        do {
            try service.register()
            return true
        } catch {
            return false
        }
    }

    /// Whether this launch should register the agent and step aside for launchd.
    ///
    /// Reached only when no other copy holds the single-instance lock, so this is
    /// exactly the case where launchd is *not* running the app and something has to
    /// put that right. The one exception is a user who turned the toggle off: they
    /// have been auto-registered once already and chose to disable it, so the app
    /// stays a plain foreground copy.
    static var shouldHandOverToLaunchd: Bool {
        if isLaunchdCopy { return false }
        if UserDefaults.standard.bool(forKey: autoRegisteredKey) {
            return service.status == .enabled
        }
        return true
    }

    /// Hands the resident role to launchd. Returns whether the agent is now registered
    /// against the current bundle; the caller exits on success so launchd's `RunAtLoad`
    /// copy is the only one left.
    @discardableResult
    static func handOverToLaunchd() -> Bool {
        UserDefaults.standard.set(true, forKey: autoRegisteredKey)
        return refreshRegistration()
    }

    /// One-time move off the old login-item registration. Without this, a user who
    /// upgrades keeps the `mainApp` login item *and* gains the agent, and both fire at
    /// login — two copies of the app, two menu bar icons.
    ///
    /// Carries the old setting across: if the login item was on, the agent goes on.
    static func migrateFromLoginItem() {
        let hadLoginItem = SMAppService.mainApp.status == .enabled
        if hadLoginItem {
            try? SMAppService.mainApp.unregister()
        }
        if hadLoginItem && service.status != .enabled {
            set(true)
        }
    }
}
