import Foundation

/// Titles and stable identity for a usage bucket, shared by every screen so
/// the wording matches the parity manifest verbatim.
enum BucketPresentation {

    static func title(for limit: UsageLimit) -> String {
        switch limit.kind {
        case "session":
            return "5-hour session"
        case "weekly_all":
            return "Week · all models"
        case "weekly_scoped":
            return "Week · \(limit.scopeDisplayName ?? "Model")"
        default:
            let spaced = limit.kind.replacingOccurrences(of: "_", with: " ")
            return spaced.capitalized
        }
    }

    /// Stable id for history/notifications/settings: `kind` alone, except
    /// `weekly_scoped`, which is disambiguated by its model scope.
    static func id(for limit: UsageLimit) -> String {
        limit.kind == "weekly_scoped" ? "\(limit.kind)|\(limit.scopeDisplayName ?? "")" : limit.kind
    }
}

/// A bucket plus everything derived from `PaceMath`, ready for display.
struct BucketDisplay: Identifiable, Equatable {
    let id: String
    let title: String
    let limit: UsageLimit
    let projection: PaceMath.Projection?
    let severity: PaceMath.Severity
    let trend: PaceMath.Trend

    static func == (a: BucketDisplay, b: BucketDisplay) -> Bool { a.id == b.id && a.limit == b.limit }

    init(limit: UsageLimit, samples: [(Date, Double)], now: Date) {
        self.id = BucketPresentation.id(for: limit)
        self.title = BucketPresentation.title(for: limit)
        self.limit = limit
        self.projection = PaceMath.project(percent: limit.percent, kind: limit.kind, resetsAt: limit.resetsAt, now: now)
        self.severity = PaceMath.severity(percent: limit.percent, projection: projection)
        self.trend = PaceMath.trend(samples: samples, kind: limit.kind, now: now)
    }

    var resetCountdown: String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        return PaceMath.countdown(to: resetsAt, from: Date())
    }
}

/// Top-of-screen verdict, driven by the `weekly_all` bucket only.
enum Verdict {
    static func text(for weeklyAll: BucketDisplay?) -> String {
        guard let bucket = weeklyAll else { return "Waiting for usage data…" }
        guard let projection = bucket.projection, projection.overPace, let hits100At = projection.hits100At else {
            return "You will not run out."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d 'at' h:mm a"
        return "You're going to run out by \(formatter.string(from: hits100At))."
    }
}
