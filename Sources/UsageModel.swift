import Foundation
import AppKit
import Observation

/// One row in the popover. Built from a `UsageLimit` plus history.
struct BucketView: Identifiable, Equatable {
    let id: String            // kind + scope
    let kind: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let projection: PaceMath.Projection?
    let trend: PaceMath.Trend
    let severity: PaceMath.Severity
    let samples: [Double]     // recent percents for the sparkline, oldest first
    let isPrimary: Bool       // shown in the menu bar title
}

@Observable
final class UsageModel {
    // MARK: Public state
    private(set) var buckets: [BucketView] = []
    private(set) var extraUsage: ExtraUsage?
    private(set) var lastGoodAt: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    /// True when we could not fetch and are showing the last good snapshot.
    var isStale: Bool { lastError != nil && lastGoodAt != nil }
    var menuTitle: String {
        guard let p = buckets.first(where: { $0.isPrimary }) ?? buckets.first else { return "–" }
        return "\(Int(p.percent.rounded()))% \(p.trend.rawValue)"
    }
    var menuSeverity: PaceMath.Severity { buckets.map(\.severity).max() ?? .normal }
    var verdict: String {
        guard let w = buckets.first(where: { $0.kind == "weekly_all" }), let r = w.resetsAt else {
            return lastError ?? "Waiting for first reading…"
        }
        let f = DateFormatter(); f.dateFormat = "EEE h a"
        guard let p = w.projection else { return "Week resets \(f.string(from: r))." }
        if p.overPace, let h = p.hits100At {
            return "Over pace: week hits 100% ~\(f.string(from: h)). Overage credits absorb the rest."
        }
        return "On pace: ~\(Int(p.projectedAtReset.rounded()))% by the \(f.string(from: r)) reset."
    }

    // MARK: Settings (UserDefaults-backed)
    var notifyWeeklyReset: Bool {
        get { defaults.object(forKey: "notifyWeeklyReset") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifyWeeklyReset") }
    }
    var notifySessionReset: Bool {
        get { defaults.bool(forKey: "notifySessionReset") }
        set { defaults.set(newValue, forKey: "notifySessionReset") }
    }

    // MARK: Internals
    private let client: UsageClient
    private let notifier: Notifying
    private let history: HistoryStore
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var lastSnapshot: UsageSnapshot?
    private var staleNotified = false
    private let pollInterval: TimeInterval = 5 * 60
    private let paceScale: Double = Double(ProcessInfo.processInfo.environment["CLAUDE_METER_PACE_SCALE"] ?? "") ?? 1

    init(client: UsageClient = UsageClient(), notifier: Notifying = Notifier(), history: HistoryStore = HistoryStore()) {
        self.client = client
        self.notifier = notifier
        self.history = history
        if let cached = defaults.data(forKey: "lastSnapshot"),
           let snap = try? JSONDecoder.usage.decode(UsageSnapshot.self, from: cached) {
            lastSnapshot = snap
            lastGoodAt = snap.fetchedAt
            rebuild(from: snap, now: Date())
        }
    }

    func start() {
        notifier.requestPermission()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    @MainActor
    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let now = Date()
        do {
            var snap = try await client.fetch()
            if paceScale != 1 {
                snap = UsageSnapshot(fetchedAt: snap.fetchedAt,
                                     limits: snap.limits.map { l in
                                        var m = l; m.percent = min(100, l.percent * paceScale); return m },
                                     extraUsage: snap.extraUsage)
            }
            lastError = nil
            staleNotified = false
            lastGoodAt = now
            if let data = try? JSONEncoder.usage.encode(snap) { defaults.set(data, forKey: "lastSnapshot") }
            history.append(snapshot: snap)
            planNotifications(new: snap, previous: lastSnapshot, now: now)
            lastSnapshot = snap
            rebuild(from: snap, now: now)
        } catch {
            lastError = Self.describe(error)
            if let good = lastGoodAt, now.timeIntervalSince(good) > 2 * 3600, !staleNotified {
                staleNotified = true
                notifier.post(id: "stale", title: "Claude Meter data is stale",
                              body: "Open Claude Code once so it refreshes your sign-in, then Claude Meter will catch up.")
            }
            if let snap = lastSnapshot { rebuild(from: snap, now: now) }
        }
    }

    private func rebuild(from snap: UsageSnapshot, now: Date) {
        buckets = snap.limits.map { l in
            let id = l.scopeDisplayName.map { "\(l.kind)|\($0)" } ?? l.kind
            let proj = PaceMath.project(percent: l.percent, kind: l.kind, resetsAt: l.resetsAt, now: now)
            let samples = history.samples(for: id)
            return BucketView(id: id, kind: l.kind, title: Self.title(for: l), percent: l.percent, resetsAt: l.resetsAt,
                              projection: proj,
                              trend: PaceMath.trend(samples: samples, kind: l.kind, now: now),
                              severity: PaceMath.severity(percent: l.percent, projection: proj),
                              samples: samples.sorted { $0.0 < $1.0 }.suffix(48).map(\.1),
                              isPrimary: l.kind == "weekly_all")
        }
        extraUsage = snap.extraUsage
    }

    private func planNotifications(new: UsageSnapshot, previous: UsageSnapshot?, now: Date) {
        func toBuckets(_ s: UsageSnapshot) -> [NotificationPlanner.Bucket] {
            s.limits.map { .init(kind: $0.kind, title: Self.title(for: $0), percent: $0.percent, resetsAt: $0.resetsAt) }
        }
        let armed = Set(defaults.stringArray(forKey: "armedNotifications") ?? [])
        var settings = NotificationPlanner.Settings()
        settings.notifyResetForWeekly = notifyWeeklyReset
        settings.notifyResetForSession = notifySessionReset
        let result = NotificationPlanner.plan(now: now, buckets: toBuckets(new),
                                              previous: previous.map(toBuckets) ?? [],
                                              armed: armed, settings: settings)
        for n in result.send { notifier.post(id: n.key, title: n.title, body: n.body) }
        defaults.set(Array(result.armed), forKey: "armedNotifications")
    }

    static func title(for l: UsageLimit) -> String {
        switch l.kind {
        case "session": return "5-hour session"
        case "weekly_all": return "Week · all models"
        case "weekly_scoped": return "Week · \(l.scopeDisplayName ?? "scoped")"
        default: return l.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? CredentialStore.Error {
            switch e {
            case .notFound: return "Claude Code sign-in not found in Keychain."
            case .accessDenied: return "Keychain access denied. Click Retry and choose Always Allow."
            case .malformed: return "Claude Code credential could not be read."
            }
        }
        if let e = error as? UsageClient.Error {
            switch e {
            case .unauthorized: return "Sign-in expired. Open Claude Code to refresh it."
            case .http(let code): return "Anthropic returned HTTP \(code)."
            case .transport: return "No network."
            }
        }
        return error.localizedDescription
    }
}

/// 7-day ring buffer of (date, bucketId, percent) in Application Support.
final class HistoryStore {
    struct Sample: Codable { let t: Date; let id: String; let p: Double }
    private var samples: [Sample] = []
    private let url: URL
    private let keep: TimeInterval = 7 * 24 * 3600

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Meter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder.usage.decode([Sample].self, from: d) { samples = s }
    }

    func append(snapshot: UsageSnapshot) {
        let cutoff = snapshot.fetchedAt.addingTimeInterval(-keep)
        samples.removeAll { $0.t < cutoff }
        for l in snapshot.limits {
            let id = l.scopeDisplayName.map { "\(l.kind)|\($0)" } ?? l.kind
            samples.append(Sample(t: snapshot.fetchedAt, id: id, p: l.percent))
        }
        if let d = try? JSONEncoder.usage.encode(samples) { try? d.write(to: url, options: .atomic) }
    }

    func samples(for id: String) -> [(Date, Double)] {
        samples.filter { $0.id == id }.map { ($0.t, $0.p) }
    }
}

extension JSONDecoder {
    static var usage: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
extension JSONEncoder {
    static var usage: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
