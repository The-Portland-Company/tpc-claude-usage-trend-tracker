import Foundation
import AuthenticationServices
import CryptoKit
import AppKit

/// "Sign in with Claude" — Authorization Code + PKCE against Claude Code's
/// public OAuth client. macOS port of ios/Sources/OAuthController.swift; see
/// docs/auth-and-pairing-spec.md §1. The token this returns is the app's OWN
/// token set (separate from any Claude Code install), so refreshing it later is
/// safe and it works inside the App Store sandbox (stored in our own Keychain).
@MainActor
final class OAuthController: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var isPresenting = false
    @Published var errorMessage: String?
    /// Set true when the system browser session couldn't complete (denied,
    /// cancelled, or the client rejected our redirect) so the UI can offer
    /// the manual "paste CODE#STATE" fallback from the spec.
    @Published var needsManualFallback = false

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "claudetracker://oauth-callback"
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let scope = "user:profile user:inference"

    private var session: ASWebAuthenticationSession?
    /// A menu-bar (LSUIElement) app often has no visible window when the user
    /// triggers sign-in, and `ASWebAuthenticationSession` needs a real anchor.
    /// Hold a tiny off-screen window as a guaranteed anchor.
    private var anchorWindow: NSWindow?
    private var codeVerifier: String?
    private var state: String?
    private var timeoutTask: Task<Void, Never>?
    private var userCancelled = false
    private var timedOut = false

    static let signInTimeout: TimeInterval = 90

    struct TokenResult {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    /// Aborts an in-flight sign-in (user tapped Cancel, or the caller is
    /// tearing down). Resets straight back to idle with no error shown.
    func cancel() {
        guard isPresenting else { return }
        userCancelled = true
        session?.cancel()
    }

    /// Kicks off the browser-based flow. Calls `completion` with the
    /// exchanged tokens on success, or leaves `needsManualFallback` set so
    /// the caller can show the manual-paste field. Auto-cancels after
    /// `signInTimeout` seconds if the browser never returns.
    func startSignIn(completion: @escaping (TokenResult?) -> Void) {
        errorMessage = nil
        needsManualFallback = false
        userCancelled = false
        timedOut = false

        let verifier = Self.randomBase64URL(byteCount: 64)
        let challenge = Self.codeChallenge(for: verifier)
        let generatedState = Self.randomBase64URL(byteCount: 32)
        codeVerifier = verifier
        state = generatedState

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: generatedState),
        ]
        guard let url = components.url else {
            errorMessage = "Couldn't build the sign-in URL."
            completion(nil)
            return
        }

        isPresenting = true
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "claudetracker") { [weak self] callbackURL, error in
            guard let self else { return }
            Task { @MainActor in
                self.timeoutTask?.cancel()
                self.timeoutTask = nil
                self.isPresenting = false
                self.anchorWindow?.close()
                self.anchorWindow = nil
                if let callbackURL, error == nil {
                    let result = await self.handleCallback(callbackURL)
                    completion(result)
                } else if self.userCancelled {
                    // User explicitly cancelled: reset to idle, no error text.
                    completion(nil)
                } else if self.timedOut {
                    self.errorMessage = "Sign-in timed out — try again, or use Pair with my Mac / Advanced."
                    completion(nil)
                } else {
                    // Denied, or the client rejected our redirect. Fall back
                    // to the manual CODE#STATE paste flow.
                    self.needsManualFallback = true
                    completion(nil)
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        self.session = session
        // A menu-bar app may be inactive; ASWebAuthenticationSession needs the
        // app active to present its browser sheet.
        NSApp.activate(ignoringOtherApps: true)
        session.start()

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.signInTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.isPresenting else { return }
                self.timedOut = true
                self.session?.cancel()
            }
        }
    }

    /// Manual fallback: user pastes "CODE#STATE" copied from the authorize
    /// page. Splits, verifies state, and exchanges the same as the auto path.
    func completeManualEntry(pasted: String) async -> TokenResult? {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            errorMessage = "Expected the code in the form CODE#STATE."
            return nil
        }
        return await exchange(code: parts[0], returnedState: parts[1])
    }

    private func handleCallback(_ url: URL) async -> TokenResult? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              let returnedState = items.first(where: { $0.name == "state" })?.value else {
            errorMessage = "Sign-in didn't return a code."
            return nil
        }
        return await exchange(code: code, returnedState: returnedState)
    }

    private func exchange(code: String, returnedState: String) async -> TokenResult? {
        guard let expectedState = state, returnedState == expectedState else {
            errorMessage = "Sign-in state didn't match. Please try again."
            return nil
        }
        guard let verifier = codeVerifier else {
            errorMessage = "Missing PKCE verifier. Please try again."
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
            guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1) else {
                errorMessage = "Sign-in failed. Please try again."
                return nil
            }
            struct R: Decodable {
                let access_token: String
                let refresh_token: String?
                let expires_in: Double?
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            let expiresAt = r.expires_in.map { Date().addingTimeInterval($0) }
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

    // MARK: ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let key = NSApplication.shared.windows.first(where: { $0.isKeyWindow && $0.isVisible }) {
            return key
        }
        if let visible = NSApplication.shared.windows.first(where: { $0.isVisible }) {
            return visible
        }
        // No usable window (menu-bar app with nothing open): make one.
        if anchorWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.alphaValue = 0
            window.orderFrontRegardless()
            anchorWindow = window
        }
        return anchorWindow!
    }
}
