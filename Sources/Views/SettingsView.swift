import SwiftUI

/// Manage the accounts the tracker reads usage for: list, remove added ones,
/// and add a new account by pasting an access token from another machine.
struct SettingsView: View {
    let model: UsageModel

    @State private var label = ""
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var isValidating = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Accounts")
                .font(.system(size: 15, weight: .semibold))

            accountList

            Divider()

            addForm
        }
        .padding(18)
        .frame(width: 460, height: 420)
    }

    // MARK: Account list

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.accounts) { account in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(account.label).font(.system(size: 12, weight: .medium))
                            if account.isPrimary {
                                Text("Claude Code")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                        if let email = model.email(for: account.id) {
                            Text(email).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if account.isPrimary {
                        Text("Not removable")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Button(role: .destructive) {
                            model.removeAccount(id: account.id)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this account")
                    }
                }
                .padding(.vertical, 3)
                Divider()
            }
        }
    }

    // MARK: Add form

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add account")
                .font(.system(size: 13, weight: .semibold))

            TextField("Label (e.g. Work Mac)", text: $label)
                .textFieldStyle(.roundedBorder)
            TextField("Access token", text: $accessToken)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospaced())
            TextField("Refresh token (optional)", text: $refreshToken)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospaced())

            Text("Get the access token from the other machine's Claude Code Keychain item “Claude Code-credentials” (field claudeAiOauth.accessToken).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    validate()
                } label: {
                    if isValidating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Validate & Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isValidating || accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func validate() {
        isValidating = true
        errorText = nil
        let l = label, at = accessToken, rt = refreshToken
        Task {
            let result = await model.validateAndAdd(label: l, accessToken: at, refreshToken: rt.isEmpty ? nil : rt)
            await MainActor.run {
                isValidating = false
                if let result {
                    errorText = result
                } else {
                    label = ""; accessToken = ""; refreshToken = ""
                }
            }
        }
    }
}
