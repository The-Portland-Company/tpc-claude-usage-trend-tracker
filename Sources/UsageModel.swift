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
    /// Last known weekly-all percent. A poll that momentarily lacks the weekly
    /// bucket must never make the menu bar jump to a different window (that was
    /// the "6% vs 24%" flip between the weekly and 5-hour limits).
    private(set) var lastWeeklyPercent: Double?
    var menuTitle: String {
        if let w = buckets.first(where: { $0.kind == "weekly_all" }) {
            return "\(Int(w.percent.rounded()))% \(w.trend.rawValue)"
        }
        if let p = lastWeeklyPercent { return "\(Int(p.rounded()))%" }
        return "–"
    }
    /// The Claude account whose usage is being read (from /oauth/profile).
    private(set) var account: String?
    var menuSeverity: PaceMath.Severity { buckets.map(\.severity).max() ?? .normal }

    // MARK: Accounts (multi-account)
    private(set) var accounts: [Account] = []
    private(set) var activeAccountID: String = Account.primaryID
    var activeAccount: Account { accounts.first { $0.id == activeAccountID } ?? .primary }

    /// The prominent top-of-popover verdict. Computed from the active account's
    /// weekly_all bucket.
    var verdict: String {
        guard let w = buckets.first(where: { $0.kind == "weekly_all" }) else {
            return lastError ?? "Waiting for first reading…"
        }
        if let p = w.projection, p.overPace, let h = p.hits100At {
            let f = DateFormatter(); f.dateFormat = "EEEE, MMM d 'at' h:mm a"
            return "You're going to run out by \(f.string(from: h))."
        }
        return "You will not run out."
    }
    /// Severity that colors the verdict line (from the weekly_all bucket).
    var verdictSeverity: PaceMath.Severity {
        buckets.first(where: { $0.kind == "weekly_all" })?.severity ?? .normal
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
    private let accountStore: AccountStore
    private var histories: [String: HistoryStore] = [:]
    private var snapshots: [String: UsageSnapshot] = [:]
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var staleNotified = false
    private let pollInterval: TimeInterval = 5 * 60
    private let paceScale: Double = Double(ProcessInfo.processInfo.environment["CLAUDE_USAGE_TREND_TRACKER_PACE_SCALE"] ?? "") ?? 1

    private func cacheKey(_ id: String) -> String { "lastSnapshot.\(id)" }

    private func history(for id: String) -> HistoryStore {
        if let h = histories[id] { return h }
        let h = HistoryStore(filename: id == Account.primaryID ? "history.json" : "history-\(id).json")
        histories[id] = h
        return h
    }

    init(client: UsageClient = UsageClient(), notifier: Notifying = Notifier(),
         history: HistoryStore = HistoryStore(), accountStore: AccountStore = AccountStore()) {
        self.client = client
        self.notifier = notifier
        self.accountStore = accountStore
        self.histories[Account.primaryID] = history
        // Migrate the legacy single-account snapshot cache onto the primary key.
        if defaults.data(forKey: cacheKey(Account.primaryID)) == nil,
           let legacy = defaults.data(forKey: "lastSnapshot") {
            defaults.set(legacy, forKey: cacheKey(Account.primaryID))
        }
        reloadAccounts()
        loadActiveFromCache(now: Date())
    }

    private func reloadAccounts() {
        accounts = accountStore.accounts()
        activeAccountID = accountStore.activeAccountID
    }

    /// Rebuild the visible state from the active account's cached snapshot.
    private func loadActiveFromCache(now: Date) {
        let id = activeAccountID
        account = accountStore.email(for: id)
        lastError = nil
        if let snap = snapshots[id]
            ?? (defaults.data(forKey: cacheKey(id)).flatMap { try? JSONDecoder.usage.decode(UsageSnapshot.self, from: $0) }) {
            snapshots[id] = snap
            lastGoodAt = snap.fetchedAt
            rebuild(from: snap, now: now)
        } else {
            lastGoodAt = nil
            lastWeeklyPercent = nil
            buckets = []
            extraUsage = nil
        }
    }

    // MARK: Account actions

    func setActiveAccount(_ id: String) {
        guard accountStore.account(id: id) != nil else { return }
        accountStore.activeAccountID = id
        activeAccountID = id
        staleNotified = false
        loadActiveFromCache(now: Date())
        Task { await refresh() }
    }

    func email(for id: String) -> String? { accountStore.email(for: id) }

    func removeAccount(id: String) {
        accountStore.remove(id: id)
        histories.removeValue(forKey: id)
        snapshots.removeValue(forKey: id)
        defaults.removeObject(forKey: cacheKey(id))
        reloadAccounts()
        loadActiveFromCache(now: Date())
        Task { await refresh() }
    }

    /// Validate a pasted token against the usage API and, if it works, store it
    /// as a new account. Returns nil on success or a human error string.
    func validateAndAdd(label: String, accessToken: String, refreshToken: String?) async -> String? {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "Paste an access token first." }
        do {
            _ = try await client.fetch(token: token)
        } catch {
            return "That token didn't work: \(Self.describe(error))"
        }
        let email = await client.fetchAccount(token: token)
        let rt = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = cleanLabel.isEmpty ? (email ?? "Added account") : cleanLabel
        accountStore.add(label: finalLabel, accessToken: token,
                         refreshToken: (rt?.isEmpty ?? true) ? nil : rt,
                         expiresAt: nil, email: email)
        reloadAccounts()
        return nil
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
        let id = activeAccountID
        if account == nil {
            if let token = try? await accountStore.resolveToken(for: id),
               let a = await client.fetchAccount(token: token) {
                account = a; accountStore.setEmail(a, for: id)
            }
        }
        let now = Date()
        do {
            let token = try await accountStore.resolveToken(for: id)
            var snap = try await client.fetch(token: token)
            // Guard against a stale switch: only apply if still the active account.
            guard id == activeAccountID else { return }
            if paceScale != 1 {
                snap = UsageSnapshot(fetchedAt: snap.fetchedAt,
                                     limits: snap.limits.map { l in
                                        var m = l; m.percent = min(100, l.percent * paceScale); return m },
                                     extraUsage: snap.extraUsage)
            }
            lastError = nil
            staleNotified = false
            lastGoodAt = now
            if let data = try? JSONEncoder.usage.encode(snap) { defaults.set(data, forKey: cacheKey(id)) }
            history(for: id).append(snapshot: snap)
            planNotifications(new: snap, previous: snapshots[id], now: now)
            snapshots[id] = snap
            rebuild(from: snap, now: now)
        } catch {
            guard id == activeAccountID else { return }
            lastError = Self.describe(error)
            if let good = lastGoodAt, now.timeIntervalSince(good) > 2 * 3600, !staleNotified {
                staleNotified = true
                notifier.post(id: "stale", title: "Claude Usage Trend Tracker data is stale",
                              body: "Open Claude Code once so it refreshes your sign-in, then Claude Usage Trend Tracker will catch up.")
            }
            if let snap = snapshots[id] { rebuild(from: snap, now: now) }
        }
    }

    private func rebuild(from snap: UsageSnapshot, now: Date) {
        let store = history(for: activeAccountID)
        buckets = snap.limits.map { l in
            let id = l.scopeDisplayName.map { "\(l.kind)|\($0)" } ?? l.kind
            let proj = PaceMath.project(percent: l.percent, kind: l.kind, resetsAt: l.resetsAt, now: now)
            let samples = store.samples(for: id)
            return BucketView(id: id, kind: l.kind, title: Self.title(for: l), percent: l.percent, resetsAt: l.resetsAt,
                              projection: proj,
                              trend: PaceMath.trend(samples: samples, kind: l.kind, now: now),
                              severity: PaceMath.severity(percent: l.percent, projection: proj),
                              samples: samples.sorted { $0.0 < $1.0 }.suffix(48).map(\.1),
                              isPrimary: l.kind == "weekly_all")
        }
        extraUsage = snap.extraUsage
        if let w = buckets.first(where: { $0.kind == "weekly_all" }) { lastWeeklyPercent = w.percent }
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
        if let e = error as? AccountStore.TokenError {
            switch e {
            case .primaryUnavailable: return "Claude Code sign-in not found in Keychain."
            case .noToken, .signInExpired: return "Sign-in expired — update token in Settings."
            }
        }
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

    init(directory: URL? = nil, filename: String = "history.json") {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Usage Trend Tracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(filename)
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
