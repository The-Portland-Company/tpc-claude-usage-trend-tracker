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

    /// True on the one launch per install where the agent still has to be registered.
    static var needsFirstLaunchRegistration: Bool {
        !UserDefaults.standard.bool(forKey: autoRegisteredKey) && service.status != .enabled
    }

    /// Registers the relaunch agent once per install, without waiting for the user
    /// to find the "Launch at login" toggle.
    ///
    /// The agent is the only thing that brings the app back after macOS kills it to
    /// reclaim container cache, so leaving it off by default meant the default install
    /// had no protection at all — the exact failure this was built to end. Because the
    /// agent carries `RunAtLoad`, enabling it also starts the app at login; for a menu
    /// bar app whose job is to always be present that is the intended behaviour, and
    /// the toggle still turns both off together.
    ///
    /// Runs exactly once: the flag is written before registering, so a user who turns
    /// the toggle back off is not overridden on the next launch. Returns whether the
    /// agent is registered afterwards.
    @discardableResult
    static func enableOnFirstLaunch() -> Bool {
        guard needsFirstLaunchRegistration else { return false }
        UserDefaults.standard.set(true, forKey: autoRegisteredKey)
        return set(true) == nil
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
