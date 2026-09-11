import SwiftUI

/// The "Sign in with Claude" control: opens the browser, then takes the code
/// the sign-in page shows and pastes it back (Claude's client doesn't accept a
/// custom-scheme redirect, so this is the manual copy-paste flow). Shared by the
/// popover empty state and Settings.
struct ClaudeSignInView: View {
    let model: UsageModel
    /// Compact styling for the menu-bar popover; roomier in Settings.
    var compact: Bool = false

    @StateObject private var oauth = OAuthController()
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !oauth.isAwaitingCode {
                Button {
                    oauth.beginBrowserSignIn()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.plus")
                        Text("Sign in with Claude")
                    }
                    .font(.system(size: compact ? 12 : 13))
                }
            } else {
                Text("Approve in your browser, then paste the code it shows here:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("code#state", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11).monospaced())
                    .onSubmit { complete() }
                HStack(spacing: 8) {
                    Button {
                        complete()
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Complete sign-in") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { oauth.cancel(); code = "" }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .font(.system(size: 11))
            }
            if let e = oauth.errorMessage {
                Text(e).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func complete() {
        let pasted = code
        busy = true
        Task {
            if let result = await oauth.completeManualEntry(pasted: pasted) {
                await model.finishOAuthSignIn(result)
            }
            await MainActor.run { busy = false; code = "" }
        }
    }
}
