import SwiftUI

/// Onboarding offers, in order: OAuth sign-in, QR pairing with the Mac app,
/// then the manual paste-token flow tucked under "Advanced" (§ Onboarding UI
/// in docs/auth-and-pairing-spec.md).
struct OnboardingView: View {
    @EnvironmentObject private var model: UsageModel
    @StateObject private var oauth = OAuthController()

    @State private var isSigningIn = false
    @State private var showManualCodeEntry = false
    @State private var manualCode = ""

    @State private var showScanner = false
    @State private var scannerError: String?

    @State private var showAdvanced = false
    @State private var label = ""
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var isSubmitting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Claude Usage Trend Tracker")
                        .font(.title2.bold())
                    Text("Sign in to track your 5-hour and weekly Claude usage.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    Button {
                        signIn()
                    } label: {
                        if isSigningIn {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Sign in with Claude").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSigningIn)

                    if isSigningIn {
                        Button("Cancel") {
                            oauth.cancel()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }

                    Button {
                        scannerError = nil
                        showScanner = true
                    } label: {
                        Text("Pair with my Mac").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if let error = oauth.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if let scannerError {
                    Text(scannerError).font(.footnote).foregroundStyle(.red)
                }

                if oauth.needsManualFallback {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Couldn't auto-capture the sign-in. Paste the code shown on the sign-in page (CODE#STATE):")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("CODE#STATE", text: $manualCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        Button("Complete sign-in") {
                            Task { await completeManualSignIn() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(manualCode.trimmingCharacters(in: .whitespaces).isEmpty || isSigningIn)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }

                DisclosureGroup("Advanced: paste a token", isExpanded: $showAdvanced) {
                    advancedForm
                        .padding(.top, 12)
                }
                .font(.subheadline.weight(.medium))
            }
            .padding()
        }
        .navigationTitle("Welcome")
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PairingScannerView { code in
                    showScanner = false
                    Task { await handleScannedCode(code) }
                }
                .ignoresSafeArea()
                .navigationTitle("Scan the QR on your Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showScanner = false }
                    }
                }
            }
        }
    }

    // MARK: OAuth

    private func signIn() {
        isSigningIn = true
        oauth.startSignIn { result in
            Task {
                if let result {
                    await finishOAuth(result)
                }
                isSigningIn = false
            }
        }
    }

    private func completeManualSignIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        if let result = await oauth.completeManualEntry(pasted: manualCode) {
            await finishOAuth(result)
        }
    }

    private func finishOAuth(_ result: OAuthController.TokenResult) async {
        _ = await model.addAccount(label: "", accessToken: result.accessToken, refreshToken: result.refreshToken)
    }

    // MARK: QR pairing

    private func handleScannedCode(_ raw: String) async {
        switch PairingDecoder.decode(raw) {
        case .success(let payload):
            _ = await model.addAccount(label: "", accessToken: payload.t, refreshToken: payload.r)
        case .failure(.stale):
            scannerError = "That QR code expired. Ask your Mac to show a fresh one."
        case .failure(.unsupportedVersion):
            scannerError = "This app doesn't support that pairing code version."
        case .failure(.malformed):
            scannerError = "Couldn't read that QR code. Try again."
        }
    }

    // MARK: Advanced (manual paste)

    @ViewBuilder
    private var advancedForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On a machine signed in to Claude Code, read the accessToken field from the “Claude Code-credentials” Keychain item (key claudeAiOauth). The refresh token is optional but keeps the account signed in longer.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            labeledField("Label (optional)", text: $label, prompt: "Work account")
            labeledField("Access token", text: $accessToken, prompt: "sk-ant-oat...", secure: true)
            labeledField("Refresh token (optional)", text: $refreshToken, prompt: "sk-ant-ort...", secure: true)

            if let error = model.errorMessage, !accessToken.isEmpty || isSubmitting {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task {
                    isSubmitting = true
                    _ = await model.addAccount(label: label, accessToken: accessToken, refreshToken: refreshToken)
                    isSubmitting = false
                }
            } label: {
                if isSubmitting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Add Account").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(accessToken.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
        }
    }

    @ViewBuilder
    private func labeledField(_ title: String, text: Binding<String>, prompt: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Group {
                if secure {
                    SecureField(prompt, text: text)
                } else {
                    TextField(prompt, text: text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
