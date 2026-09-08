import Foundation

/// 7-day ring buffer of `(timestamp, bucketID, percent)` samples, one per
/// poll per bucket, keyed per account. Backs the trend calculation.
/// Non-secret, so it lives in ordinary UserDefaults (never the token itself).
final class HistoryStore {
    struct Sample: Codable {
        let timestamp: Date
        let bucketID: String
        let percent: Double
    }

    private let defaults: UserDefaults
    private let maxAge: TimeInterval = 7 * 24 * 3600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for accountID: String) -> String { "history.\(accountID)" }

    func samples(for accountID: String) -> [Sample] {
        guard let data = defaults.data(forKey: key(for: accountID)),
              let list = try? JSONDecoder().decode([Sample].self, from: data) else { return [] }
        return list
    }

    /// Records one sample per bucket in the snapshot, pruning anything older
    /// than 7 days.
    func record(_ snapshot: UsageSnapshot, accountID: String) {
        var list = samples(for: accountID)
        let cutoff = snapshot.fetchedAt.addingTimeInterval(-maxAge)
        list.removeAll { $0.timestamp < cutoff }
        for limit in snapshot.limits {
            list.append(Sample(timestamp: snapshot.fetchedAt, bucketID: BucketPresentation.id(for: limit), percent: limit.percent))
        }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key(for: accountID))
        }
    }

    /// `(Date, Double)` pairs for one bucket, the shape `PaceMath.trend` wants.
    func points(bucketID: String, accountID: String) -> [(Date, Double)] {
        samples(for: accountID).filter { $0.bucketID == bucketID }.map { ($0.timestamp, $0.percent) }
    }

    /// Last ~48 samples for one bucket, oldest first, for a sparkline.
    func sparkline(bucketID: String, accountID: String, limit: Int = 48) -> [Double] {
        samples(for: accountID)
            .filter { $0.bucketID == bucketID }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(limit)
            .map { $0.percent }
    }
}
