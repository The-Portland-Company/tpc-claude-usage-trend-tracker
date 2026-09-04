import Foundation

/// Decides which notifications to send for a new snapshot, given what was
/// already sent in this window. Pure, so it is unit-tested without UNUserNotificationCenter.
enum NotificationPlanner {

    struct Bucket: Equatable {
        let kind: String
        let title: String
        let percent: Double
        let resetsAt: Date?
    }

    struct Pending: Equatable {
        let key: String      // stable id, also used for arming
        let title: String
        let body: String
    }

    struct Settings: Equatable {
        var notifyResetForWeekly = true
        var notifyResetForSession = false
        var thresholds: [Double] = [75, 90]
    }

    /// - armed: keys already fired in the current window (per bucket).
    /// - previous: last snapshot's buckets, used to detect resets.
    /// Returns notifications to send and the new armed set.
    static func plan(now: Date,
                     buckets: [Bucket],
                     previous: [Bucket],
                     armed: Set<String>,
                     settings: Settings = Settings()) -> (send: [Pending], armed: Set<String>) {
        var out: [Pending] = []
        var armed = armed
        let resetFmt = DateFormatter()
        resetFmt.dateFormat = "EEE h:mm a"

        for b in buckets {
            guard let resetsAt = b.resetsAt else { continue }
            let window = "\(b.kind)|\(Int(resetsAt.timeIntervalSince1970))"

            // Reset detection: same kind, new resets_at later than before.
            if let prev = previous.first(where: { $0.kind == b.kind }),
               let prevReset = prev.resetsAt, resetsAt > prevReset.addingTimeInterval(60) {
                let wants = b.kind == "session" ? settings.notifyResetForSession : settings.notifyResetForWeekly
                let key = "\(window)|reset"
                if wants, !armed.contains(key) {
                    out.append(Pending(key: key, title: "\(b.title) reset", body: "Back to \(Int(b.percent))%. Next reset \(resetFmt.string(from: resetsAt))."))
                    armed.insert(key)
                }
                // A new window drops the old window's arming naturally because keys embed resets_at.
            }

            // Threshold crossings.
            for t in settings.thresholds where b.percent >= t {
                let key = "\(window)|\(Int(t))"
                if !armed.contains(key) {
                    out.append(Pending(key: key, title: "\(b.title) at \(Int(b.percent))%", body: "Resets \(resetFmt.string(from: resetsAt))."))
                    armed.insert(key)
                }
            }

            // Pace: fire once per window when projection crosses 100; re-arm if it drops back under.
            if let p = PaceMath.project(percent: b.percent, kind: b.kind, resetsAt: resetsAt, now: now) {
                let key = "\(window)|pace"
                if p.overPace, b.percent >= 10 {
                    if !armed.contains(key) {
                        let when = p.hits100At.map { resetFmt.string(from: $0) } ?? "before reset"
                        out.append(Pending(key: key, title: "\(b.title) is over pace",
                                           body: "At this rate you hit 100% \(when), before the \(resetFmt.string(from: resetsAt)) reset."))
                        armed.insert(key)
                    }
                } else {
                    armed.remove(key)
                }
            }
        }
        // Prune keys from windows that no longer exist.
        let live = Set(buckets.compactMap { b -> String? in
            guard let r = b.resetsAt else { return nil }
            return "\(b.kind)|\(Int(r.timeIntervalSince1970))"
        })
        armed = armed.filter { key in live.contains(where: { key.hasPrefix($0 + "|") }) }
        return (out, armed)
    }
}
