import Foundation

/// Pure functions that turn a usage bucket into "where is this heading".
/// Everything here is deterministic and unit-tested; no I/O.
enum PaceMath {

    /// Length of a bucket's window, derived from its `kind`.
    /// Anthropic does not send the window length, only `resets_at`.
    static func windowLength(forKind kind: String) -> TimeInterval? {
        if kind == "session" || kind == "five_hour" { return 5 * 3600 }
        if kind.hasPrefix("weekly") || kind.hasPrefix("seven_day") { return 7 * 24 * 3600 }
        return nil
    }

    struct Projection: Equatable {
        /// 0...1, how much of the window has elapsed at `now`.
        let elapsedFraction: Double
        /// Straight-line projection of percent at `resetsAt`. May exceed 100.
        let projectedAtReset: Double
        /// When the bucket reaches 100% at the current pace, if before reset.
        let hits100At: Date?
        /// Percent per hour actually observed over the whole window so far.
        let ratePerHour: Double
        /// Percent per hour that would land exactly on 100% at reset.
        let sustainableRatePerHour: Double

        var overPace: Bool { projectedAtReset > 100 }
    }

    /// Straight-line projection from window start to reset.
    /// Returns nil when the kind has no known window length or `resetsAt` is missing.
    static func project(percent: Double, kind: String, resetsAt: Date?, now: Date) -> Projection? {
        guard let length = windowLength(forKind: kind), let resetsAt else { return nil }
        let start = resetsAt.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(start)
        // Clamp: right after a reset the fraction is ~0 and a tiny percent would project to infinity.
        let fraction = min(max(elapsed / length, 0.02), 1.0)
        let projected = percent / fraction
        let hours = length / 3600
        let rate = percent / (fraction * hours)
        let sustainable = 100 / hours
        var hits100: Date? = nil
        if percent > 0, rate > 0, projected > 100 {
            let hoursTo100 = (100 - percent) / rate
            hits100 = now.addingTimeInterval(hoursTo100 * 3600)
        }
        return Projection(elapsedFraction: fraction,
                          projectedAtReset: projected,
                          hits100At: hits100,
                          ratePerHour: rate,
                          sustainableRatePerHour: sustainable)
    }

    enum Trend: String, Equatable {
        case rising = "↗"
        case steady = "→"
        case falling = "↘"
        case unknown = "·"
    }

    /// Compare the slope over the recent samples with the sustainable slope.
    /// `samples` are (date, percent) for one bucket, any order.
    static func trend(samples: [(Date, Double)], kind: String, now: Date, lookback: TimeInterval = 3600) -> Trend {
        guard let length = windowLength(forKind: kind) else { return .unknown }
        let recent = samples.filter { now.timeIntervalSince($0.0) <= lookback }.sorted { $0.0 < $1.0 }
        guard let first = recent.first, let last = recent.last,
              last.0.timeIntervalSince(first.0) >= 600 else { return .unknown }
        let hours = last.0.timeIntervalSince(first.0) / 3600
        let slope = (last.1 - first.1) / hours           // percent per hour, negative after a reset
        let sustainable = 100 / (length / 3600)
        if slope < 0 { return .falling }                 // a reset happened inside the window
        if slope > sustainable * 1.25 { return .rising }
        if slope < sustainable * 0.75 { return .falling }
        return .steady
    }

    enum Severity: String, Equatable, Comparable {
        case normal, warning, critical
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
        private var rank: Int { switch self { case .normal: 0; case .warning: 1; case .critical: 2 } }
    }

    /// Local severity, independent of Anthropic's `severity` string, so the
    /// menu bar can go amber before the server does.
    static func severity(percent: Double, projection: Projection?) -> Severity {
        if percent >= 90 { return .critical }
        if let p = projection, p.overPace, percent >= 50 { return .critical }
        if percent >= 75 { return .warning }
        if let p = projection, p.overPace { return .warning }
        return .normal
    }

    /// "in 2d 4h", "in 3h 12m", "in 40m", "now".
    static func countdown(to date: Date, from now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        if s == 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }
}
