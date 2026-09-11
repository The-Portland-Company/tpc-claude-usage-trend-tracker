import Foundation
import CryptoKit
import AppKit

/// "Sign in with Claude" — Authorization Code + PKCE against Claude Code's
/// public OAuth client, using the **manual copy-paste** flow.
///
/// The public client does NOT accept a custom `claudetracker://` redirect (the
/// authorize page rejects it: "Redirect URI … is not supported by client"), so
/// we use the same redirect Claude Code's CLI uses for headless sign-in:
/// `https://console.anthropic.com/oauth/code/callback`, which displays the
/// authorization code for the user to copy. We open the authorize URL in the
/// user's browser, they approve and copy the shown `code#state`, and paste it
/// back. No `ASWebAuthenticationSession` (which needs a custom scheme or an
/// associated domain) is involved. See docs/auth-and-pairing-spec.md §1(b).
///
/// The token this produces is the app's OWN token set (separate from any Claude
/// Code install), so refreshing it later is safe and it works inside the App
/// Store sandbox (stored in our own Keychain).
@MainActor
final class OAuthController: ObservableObject {
    /// True after the browser has been opened and we're waiting for the user to
    /// paste the code. Drives the paste field in the UI.
    @Published var isAwaitingCode = false
    @Published var errorMessage: String?

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let scope = "user:profile user:inference"

    private var codeVerifier: String?
    private var state: String?

    struct TokenResult {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    /// Opens the Claude sign-in page in the default browser and switches the UI
    /// into "paste the code" mode. Returns an error string if the URL couldn't
    /// be built/opened, else nil.
    @discardableResult
    func beginBrowserSignIn() -> String? {
        errorMessage = nil

        let verifier = Self.randomBase64URL(byteCount: 64)
        let challenge = Self.codeChallenge(for: verifier)
        let generatedState = Self.randomBase64URL(byteCount: 32)
        codeVerifier = verifier
        state = generatedState

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: generatedState),
        ]
        guard let url = components.url else {
            let msg = "Couldn't build the sign-in URL."
            errorMessage = msg
            return msg
        }
        NSWorkspace.shared.open(url)
        isAwaitingCode = true
        return nil
    }

    func cancel() {
        isAwaitingCode = false
        errorMessage = nil
        codeVerifier = nil
        state = nil
    }

    /// The user pastes the code shown on the sign-in page. Accepts either
    /// `CODE#STATE` (Claude shows both, separated by `#`) or a bare `CODE`
    /// (we then trust the state we generated). Exchanges for tokens.
    func completeManualEntry(pasted: String) async -> TokenResult? {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Paste the code from the sign-in page first."
            return nil
        }
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts[0]
        let returnedState = parts.count == 2 ? parts[1] : (state ?? "")
        return await exchange(code: code, returnedState: returnedState)
    }

    private func exchange(code: String, returnedState: String) async -> TokenResult? {
        guard let expectedState = state, returnedState == expectedState else {
            errorMessage = "Sign-in code didn't match this session. Start sign-in again."
            return nil
        }
        guard let verifier = codeVerifier else {
            errorMessage = "Missing PKCE verifier. Start sign-in again."
            return nil
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
            "state": returnedState,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            errorMessage = "Couldn't build the token request."
            return nil
        }
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                errorMessage = "Sign-in failed (the code may have expired). Try again."
                return nil
            }
            struct R: Decodable {
                let access_token: String
                let refresh_token: String?
                let expires_in: Double?
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            let expiresAt = r.expires_in.map { Date().addingTimeInterval($0) }
            isAwaitingCode = false
            return TokenResult(accessToken: r.access_token, refreshToken: r.refresh_token, expiresAt: expiresAt)
        } catch {
            errorMessage = "Sign-in failed. Please try again."
            return nil
        }
    }

    // MARK: PKCE helpers

    static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
