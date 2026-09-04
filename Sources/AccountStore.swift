import Foundation

/// A Claude account the tracker can read usage for. The primary account is the
/// machine's own Claude Code sign-in; added accounts carry a token pasted from
/// another machine's Claude Code Keychain item.
struct Account: Codable, Identifiable, Equatable {
    let id: String
    var label: String
    let isPrimary: Bool

    static let primaryID = "claude-code"
    static let primary = Account(id: primaryID, label: "Claude Code", isPrimary: true)
}

/// Token blob stored in the Keychain for an ADDED account only. The primary
/// account's token is never stored here — it is read live from Claude Code's
/// own Keychain item via `CredentialStore`.
struct AccountToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    /// Absolute expiry. Optional: a token pasted from another machine may not
    /// carry one, in which case we treat it as non-expiring until the API 401s.
    var expiresAt: Date?
}

/// Multi-account registry. Metadata (id/label/email) lives in UserDefaults;
/// tokens live only in the Keychain.
final class AccountStore {
    enum TokenError: Swift.Error, Equatable {
        /// The primary Claude Code sign-in could not be read.
        case primaryUnavailable
        /// No token stored for this added account.
        case noToken
        /// Added account token expired and could not be refreshed.
        case signInExpired
    }

    private let defaults: UserDefaults
    private let session: URLSession
    /// The public OAuth client id Claude Code uses.
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let refreshEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    // MARK: Account list

    /// Every account, primary always first.
    func accounts() -> [Account] {
        var result = [Account.primary]
        result.append(contentsOf: addedAccounts())
        return result
    }

    private func addedAccounts() -> [Account] {
        guard let data = defaults.data(forKey: "accounts"),
              let list = try? JSONDecoder().decode([Account].self, from: data) else { return [] }
        return list.filter { !$0.isPrimary }
    }

    private func saveAddedAccounts(_ list: [Account]) {
        if let data = try? JSONEncoder().encode(list.filter { !$0.isPrimary }) {
            defaults.set(data, forKey: "accounts")
        }
    }

    func account(id: String) -> Account? {
        accounts().first { $0.id == id }
    }

    // MARK: Active account

    var activeAccountID: String {
        get { defaults.string(forKey: "activeAccount") ?? Account.primaryID }
        set { defaults.set(newValue, forKey: "activeAccount") }
    }

    var activeAccount: Account {
        account(id: activeAccountID) ?? .primary
    }

    // MARK: Emails

    private func emailMap() -> [String: String] {
        (defaults.dictionary(forKey: "accountEmails") as? [String: String]) ?? [:]
    }

    func email(for id: String) -> String? { emailMap()[id] }

    func setEmail(_ email: String?, for id: String) {
        var map = emailMap()
        if let email { map[id] = email } else { map.removeValue(forKey: id) }
        defaults.set(map, forKey: "accountEmails")
    }

    // MARK: Add / remove

    /// Adds a validated account. Persists the token in the Keychain and the
    /// metadata in UserDefaults. Returns the new account.
    @discardableResult
    func add(label: String, accessToken: String, refreshToken: String?, expiresAt: Date?, email: String? = nil) -> Account {
        let id = "acct-\(UUID().uuidString.prefix(8).lowercased())"
        let account = Account(id: id, label: label, isPrimary: false)
        var list = addedAccounts()
        list.append(account)
        saveAddedAccounts(list)
        AccountKeychain.save(AccountToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt), for: id)
        if let email { setEmail(email, for: id) }
        return account
    }

    /// Removes an added account and its stored token. The primary account is
    /// never removable.
    func remove(id: String) {
        guard id != Account.primaryID else { return }
        saveAddedAccounts(addedAccounts().filter { $0.id != id })
        AccountKeychain.delete(for: id)
        setEmail(nil, for: id)
        if activeAccountID == id { activeAccountID = Account.primaryID }
    }

    // MARK: Token resolution

    /// The token to use for a given account. Primary reads Claude Code live;
    /// added accounts read the stored token and best-effort refresh it.
    /// Refresh failures surface as `.signInExpired`, never a crash.
    func resolveToken(for id: String) async throws -> String {
        if id == Account.primaryID {
            guard let creds = try? CredentialStore.readAccessToken() else {
                throw TokenError.primaryUnavailable
            }
            return creds.token
        }
        guard var token = AccountKeychain.load(for: id) else { throw TokenError.noToken }
        let expired = token.expiresAt.map { $0 <= Date() } ?? false
        if !expired { return token.accessToken }

        // Expired: best-effort refresh. Non-fatal.
        guard let refreshToken = token.refreshToken,
              let refreshed = await refresh(refreshToken: refreshToken) else {
            throw TokenError.signInExpired
        }
        token.accessToken = refreshed.accessToken
        if let rt = refreshed.refreshToken { token.refreshToken = rt }
        token.expiresAt = refreshed.expiresAt
        AccountKeychain.save(token, for: id)
        return token.accessToken
    }

    /// Best-effort OAuth refresh. Returns nil on any failure (network, wrong
    /// endpoint/const, non-2xx, unparseable body) so the caller degrades to
    /// "sign-in expired" rather than crashing.
    private func refresh(refreshToken: String) async -> (accessToken: String, refreshToken: String?, expiresAt: Date?)? {
        var request = URLRequest(url: Self.refreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientID,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = payload
        guard let (data, resp) = try? await session.data(for: request),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? -1) else { return nil }
        struct R: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        let expiresAt = r.expires_in.map { Date().addingTimeInterval($0) }
        return (r.access_token, r.refresh_token, expiresAt)
    }
}

/// Keychain storage for added-account tokens. Mirrors `CredentialStore`'s
/// query style; works inside the App Store sandbox because it uses the app's
/// own default keychain access group with `kSecClassGenericPassword`.
enum AccountKeychain {
    static func service(for id: String) -> String { "ClaudeUsageTrendTracker.account.\(id)" }

    static func save(_ token: AccountToken, for id: String) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(for id: String) -> AccountToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AccountToken.self, from: data)
    }

    static func delete(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
