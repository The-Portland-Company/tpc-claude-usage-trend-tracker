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

    /// Held for the lifetime of the process — releasing it would let a second copy in.
    nonisolated(unsafe) private static var instanceLock: Int32 = -1

    /// Guards against two menu bar icons.
    ///
    /// The relaunch agent starts the executable through launchd, which bypasses the
    /// single-instance behaviour LaunchServices gives a normal `.app` double-click. The
    /// window is real: registering the agent makes launchd honour `RunAtLoad`
    /// immediately, so the copy that just registered it gets a twin seconds later.
    ///
    /// This used to ask `NSRunningApplication`, which is not dependable this early —
    /// a launchd-exec'd process has no complete LaunchServices record yet, so the check
    /// read as "nobody else is running" and both copies stayed up. An advisory file lock
    /// answers correctly regardless of AppKit state, and the kernel drops it however the
    /// holder dies, including the SIGKILL this whole fix exists to survive.
    ///
    /// The newcomer exits 0 — a clean exit, so launchd does not count it as a failure
    /// and try again.
    static func exitIfAlreadyRunning() {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let lock = support.appendingPathComponent(".single-instance.lock")

        let fd = open(lock.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }          // Can't lock: let the app start rather than fail closed.
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { // EWOULDBLOCK: someone else holds it.
            close(fd)
            exit(0)
        }
        instanceLock = fd
    }
}
