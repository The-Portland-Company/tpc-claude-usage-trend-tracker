import Foundation

// MARK: - Credentials

/// The subset of Claude Code's Keychain blob that we read.
struct ClaudeCredentials: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
        let refreshToken: String?
        /// Milliseconds since the Unix epoch.
        let expiresAt: Double
        let scopes: [String]?
    }
    let claudeAiOauth: OAuth
}

/// Read-only access to the Keychain item Claude Code maintains.
/// The app never writes or refreshes the token: refreshing from a second
/// client can invalidate the token Claude Code itself is using.
enum CredentialStore {
    enum Error: Swift.Error, Equatable {
        case notFound
        case accessDenied(OSStatus)
        case malformed
    }

    static let service = "Claude Code-credentials"

    static func readAccessToken() throws -> (token: String, expiresAt: Date) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw Error.notFound
        default:
            throw Error.accessDenied(status)
        }

        guard let data = item as? Data else { throw Error.malformed }
        return try decodeCredentials(data)
    }

    /// Exposed for tests: turns the raw Keychain blob into a token + expiry.
    static func decodeCredentials(_ data: Data) throws -> (token: String, expiresAt: Date) {
        let full = try decodeFullCredentials(data)
        return (full.token, full.expiresAt)
    }

    /// The full OAuth record (token, refresh token, expiry, scopes), used only
    /// for building the pairing QR payload. Never persisted.
    static func readFullCredentials() throws -> (token: String, refreshToken: String?, expiresAt: Date, scopes: [String]?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw Error.notFound
        default: throw Error.accessDenied(status)
        }
        guard let data = item as? Data else { throw Error.malformed }
        return try decodeFullCredentials(data)
    }

    private static func decodeFullCredentials(_ data: Data) throws -> (token: String, refreshToken: String?, expiresAt: Date, scopes: [String]?) {
        guard let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) else {
            throw Error.malformed
        }
        let oauth = creds.claudeAiOauth
        guard !oauth.accessToken.isEmpty else { throw Error.malformed }
        return (oauth.accessToken, oauth.refreshToken, Date(timeIntervalSince1970: oauth.expiresAt / 1000), oauth.scopes)
    }
}

// MARK: - Snapshot model

struct UsageLimit: Codable, Equatable {
    /// Kept verbatim so unknown kinds still render generically.
    var kind: String
    var group: String?
    var percent: Double
    var severity: String?
    var resetsAt: Date?
    /// `scope.model.display_name`, ex. "Fable".
    var scopeDisplayName: String?
    var isActive: Bool?
}

struct ExtraUsage: Codable, Equatable {
    let isEnabled: Bool
    let usedCredits: Double
    let monthlyLimit: Double
    let utilization: Double
}

struct UsageSnapshot: Codable, Equatable {
    let fetchedAt: Date
    let limits: [UsageLimit]
    let extraUsage: ExtraUsage?
}

// MARK: - Wire format

/// Mirrors `GET /api/oauth/usage`. Unknown top-level keys are simply not
/// declared here, so they are ignored.
private struct UsageResponse: Decodable {
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let display_name: String?
            }
            let model: Model?
        }
        let kind: String
        let group: String?
        let percent: Double
        let severity: String?
        let resets_at: Date?
        let scope: Scope?
        let is_active: Bool?

        // Tolerant decode: accounts without a Claude Code subscription can
        // return limits with a null/absent `kind` or `percent`. Fall back to
        // sensible defaults rather than throwing "data couldn't be read".
        enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity, resets_at, scope, is_active
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "unknown"
            group = try? c.decodeIfPresent(String.self, forKey: .group)
            percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? 0
            severity = try? c.decodeIfPresent(String.self, forKey: .severity)
            resets_at = try? c.decodeIfPresent(Date.self, forKey: .resets_at)
            scope = try? c.decodeIfPresent(Scope.self, forKey: .scope)
            is_active = try? c.decodeIfPresent(Bool.self, forKey: .is_active)
        }
    }

    struct Extra: Decodable {
        let is_enabled: Bool
        let used_credits: Double
        let monthly_limit: Double
        let utilization: Double

        enum CodingKeys: String, CodingKey {
            case is_enabled, used_credits, monthly_limit, utilization
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            is_enabled = (try? c.decodeIfPresent(Bool.self, forKey: .is_enabled)) ?? false
            used_credits = (try? c.decodeIfPresent(Double.self, forKey: .used_credits)) ?? 0
            monthly_limit = (try? c.decodeIfPresent(Double.self, forKey: .monthly_limit)) ?? 0
            utilization = (try? c.decodeIfPresent(Double.self, forKey: .utilization)) ?? 0
        }
    }

    let limits: [Limit]
    let extra_usage: Extra?

    enum CodingKeys: String, CodingKey { case limits, extra_usage }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limits = (try? c.decodeIfPresent([Limit].self, forKey: .limits)) ?? []
        extra_usage = try? c.decodeIfPresent(Extra.self, forKey: .extra_usage)
    }
}

// MARK: - Client

final class UsageClient {
    enum Error: Swift.Error {
        case unauthorized
        case http(Int)
        case transport(Swift.Error)
    }

    private let session: URLSession
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let userAgent = "ClaudeUsageTrendTracker/1.0"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch() async throws -> UsageSnapshot {
        let (token, _) = try CredentialStore.readAccessToken()
        return try await fetch(token: token)
    }

    /// Fetch usage for an explicit access token (multi-account).
    func fetch(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Error.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 { throw Error.unauthorized }
        guard (200..<300).contains(code) else { throw Error.http(code) }

        return try Self.decode(data, fetchedAt: Date())
    }

    static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// Best-effort account email from /oauth/profile. Never throws.
    func fetchAccount() async -> String? {
        guard let (token, _) = try? CredentialStore.readAccessToken() else { return nil }
        return await fetchAccount(token: token)
    }

    /// Best-effort account email for an explicit token. Never throws.
    func fetchAccount(token: String) async -> String? {
        await fetchProfile(token: token)?.email
    }

    /// The subset of `/oauth/profile` the app uses.
    struct Profile {
        let email: String?
        /// When the Stripe subscription began; the billing cycle anchors to this
        /// day of the month.
        let subscriptionCreatedAt: Date?
    }

    /// Best-effort profile (email + subscription anchor). Never throws.
    func fetchProfile(token: String) async -> Profile? {
        var request = URLRequest(url: Self.profileEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: request),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? -1) else { return nil }
        struct P: Decodable {
            struct A: Decodable { let email: String? }
            struct O: Decodable { let subscription_created_at: String? }
            let account: A?
            let organization: O?
        }
        guard let p = try? JSONDecoder().decode(P.self, from: data) else { return nil }
        let anchor = p.organization?.subscription_created_at.flatMap(Self.isoDate)
        return Profile(email: p.account?.email, subscriptionCreatedAt: anchor)
    }

    /// Network-free decode, so tests can run against a fixture.
    static func decode(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = isoDate(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unparseable date: \(raw)")
            }
            return date
        }

        let wire = try decoder.decode(UsageResponse.self, from: data)
        let limits = wire.limits.map {
            UsageLimit(
                kind: $0.kind,
                group: $0.group,
                percent: $0.percent,
                severity: $0.severity,
                resetsAt: $0.resets_at,
                scopeDisplayName: $0.scope?.model?.display_name,
                isActive: $0.is_active)
        }
        let extra = wire.extra_usage.map {
            ExtraUsage(
                isEnabled: $0.is_enabled,
                usedCredits: $0.used_credits,
                monthlyLimit: $0.monthly_limit,
                utilization: $0.utilization)
        }
        return UsageSnapshot(fetchedAt: fetchedAt, limits: limits, extraUsage: extra)
    }

    /// `resets_at` carries fractional seconds and an offset; some fields may
    /// arrive without fractional seconds, so try both.
    static func isoDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// Compatibility aliases for the flat names.
typealias CredentialError = CredentialStore.Error
typealias UsageClientError = UsageClient.Error
