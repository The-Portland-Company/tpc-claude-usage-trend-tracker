import AppKit
import Foundation

/// Keeps the app off macOS's list of things worth killing.
///
/// macOS reclaims disk space with `com.apple.cache_delete`, which walks sandboxed
/// apps and empties each one's container `Library/Caches`. To purge the cache of a
/// *running* app it first asks RunningBoard to terminate it, and a windowless
/// `LSUIElement` agent has the low termination resistance that request needs — the
/// menu bar icon just vanishes, with no crash report:
///
///     Received termination request from [osservice<com.apple.cache_delete(501)>]
///     explanation:CacheDeleteAppContainerCaches maxTerminationResistance:NonInteractive
///
/// An app is only worth terminating if it has a cache to reclaim. `URLSession.shared`
/// writes one (`Cache.db`, `fsCachedData`) on the first request and never stops, so we
/// replace the shared cache with a zero-capacity one before anything can touch it.
/// With nothing to purge, cache_delete walks straight past us.
enum ResidentAgent {
    /// Call before the first `URLSession.shared` use — `URLSession.shared` snapshots
    /// `URLCache.shared` when it is first created, so ordering matters.
    static func disableURLCache() {
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
    }

    /// Guards against two menu bar icons.
    ///
    /// The relaunch agent starts the executable through launchd, which bypasses the
    /// single-instance behaviour LaunchServices gives a normal `.app` double-click.
    /// If a copy is already up, the newer one hands off and exits 0 — a clean exit, so
    /// launchd does not treat it as a failure and try again.
    ///
    /// Scoped to *this same bundle on disk*. Matching on bundle identifier alone would
    /// also stand down for a separate copy that happens to share the id — a test host,
    /// or a local build sitting beside the App Store one — and refuse to launch it.
    static func exitIfAlreadyRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        guard let myURL = me.bundleURL?.resolvingSymlinksInPath().standardizedFileURL else { return }
        let twins = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
            .filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == myURL }
        // Compare launch dates so two simultaneous starts can't both stand down.
        let incumbent = twins.first { other in
            guard let theirs = other.launchDate, let mine = me.launchDate else {
                return other.processIdentifier < me.processIdentifier
            }
            return theirs < mine
        }
        guard incumbent != nil else { return }
        exit(0)
    }
}
