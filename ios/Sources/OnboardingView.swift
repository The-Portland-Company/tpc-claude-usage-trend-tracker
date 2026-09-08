import SwiftUI

/// iOS can't read the macOS Claude Code Keychain item, so the user pastes a
/// token here — same flow as macOS "added accounts" (§4, iOS notes).
struct OnboardingView: View {
    @EnvironmentObject private var model: UsageModel

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
                    Text("Paste an access token to track your 5-hour and weekly Claude usage.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("How to get a token").font(.headline)
                    Text("On a machine signed in to Claude Code, read the accessToken field from the “Claude Code-credentials” Keychain item (key claudeAiOauth). The refresh token is optional but keeps the account signed in longer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 12) {
                    labeledField("Label (optional)", text: $label, prompt: "Work account")
                    labeledField("Access token", text: $accessToken, prompt: "sk-ant-oat...", secure: true)
                    labeledField("Refresh token (optional)", text: $refreshToken, prompt: "sk-ant-ort...", secure: true)
                }

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
            .padding()
        }
        .navigationTitle("Welcome")
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
