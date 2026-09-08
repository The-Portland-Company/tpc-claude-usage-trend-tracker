import Foundation
import Combine

/// Drives the iOS app off the shared `UsageClient`/`PaceMath`/`AccountStore`,
/// mirroring the responsibilities of the macOS `UsageModel` minus AppKit.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var buckets: [BucketDisplay] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeAccountID: String

    let client = UsageClient()
    let store = AccountStore()
    let history = HistoryStore()

    private var timer: Timer?
    private let pollInterval: TimeInterval = 300

    init() {
        activeAccountID = AccountStore().activeAccountID
        accounts = store.accounts()
    }

    /// True once we've established there is no usable account yet and the
    /// user should be shown the paste-token onboarding flow.
    var needsOnboarding: Bool {
        snapshot == nil && accounts.count <= 1 && errorMessage != nil
    }

    var weeklyAll: BucketDisplay? { buckets.first { $0.limit.kind == "weekly_all" } }
    var verdictText: String { Verdict.text(for: weeklyAll) }

    func start() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func switchAccount(_ id: String) {
        guard store.account(id: id) != nil else { return }
        activeAccountID = id
        store.activeAccountID = id
        snapshot = nil
        buckets = []
        Task { await refresh() }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let token = try await store.resolveToken(for: activeAccountID)
            let snap = try await client.fetch(token: token)
            snapshot = snap
            errorMessage = nil
            history.record(snap, accountID: activeAccountID)
            rebuildBuckets(from: snap)
        } catch AccountStore.TokenError.primaryUnavailable {
            errorMessage = "No Claude Code sign-in was found on this device. Add an account below."
        } catch AccountStore.TokenError.signInExpired, AccountStore.TokenError.noToken {
            errorMessage = "Sign-in expired. Re-add this account with a fresh token."
        } catch UsageClient.Error.unauthorized {
            errorMessage = "Sign-in expired."
        } catch {
            errorMessage = "Couldn't refresh usage. Will retry automatically."
        }
    }

    private func rebuildBuckets(from snapshot: UsageSnapshot) {
        let now = Date()
        buckets = snapshot.limits.map { limit in
            let id = BucketPresentation.id(for: limit)
            let samples = history.points(bucketID: id, accountID: activeAccountID)
            return BucketDisplay(limit: limit, samples: samples, now: now)
        }
    }

    /// Validates a pasted token against the live API, then persists it via
    /// `AccountStore`. Returns false (with `errorMessage` set) on failure.
    func addAccount(label: String, accessToken: String, refreshToken: String?) async -> Bool {
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return false }
        do {
            _ = try await client.fetch(token: trimmedToken)
        } catch {
            errorMessage = "That token couldn't be verified. Double-check it and try again."
            return false
        }
        let email = await client.fetchAccount(token: trimmedToken)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = store.add(
            label: trimmedLabel.isEmpty ? (email ?? "Claude account") : trimmedLabel,
            accessToken: trimmedToken,
            refreshToken: refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            expiresAt: nil,
            email: email)
        accounts = store.accounts()
        switchAccount(account.id)
        return true
    }

    func removeAccount(_ id: String) {
        store.remove(id: id)
        accounts = store.accounts()
        if activeAccountID == id {
            activeAccountID = store.activeAccountID
            snapshot = nil
            buckets = []
            Task { await refresh() }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
