import Foundation

// MARK: - Credentials

/// The subset of Claude Code's Keychain blob that we read.
struct ClaudeCredentials: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
        /// Milliseconds since the Unix epoch.
        let expiresAt: Double
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
        guard let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) else {
            throw Error.malformed
        }
        let oauth = creds.claudeAiOauth
        guard !oauth.accessToken.isEmpty else { throw Error.malformed }
        return (oauth.accessToken, Date(timeIntervalSince1970: oauth.expiresAt / 1000))
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
    }

    struct Extra: Decodable {
        let is_enabled: Bool
        let used_credits: Double
        let monthly_limit: Double
        let utilization: Double
    }

    let limits: [Limit]
    let extra_usage: Extra?
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
        var request = URLRequest(url: Self.profileEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: request),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? -1) else { return nil }
        struct P: Decodable { struct A: Decodable { let email: String? }; let account: A? }
        return (try? JSONDecoder().decode(P.self, from: data))?.account?.email
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
