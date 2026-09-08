import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: UsageModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showAddAccount = false

    var body: some View {
        Form {
            Section("Featured in widget") {
                if model.buckets.isEmpty {
                    Text("Refresh once to choose which buckets appear.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.buckets) { bucket in
                        Toggle(bucket.title, isOn: Binding(
                            get: { settings.featuredBucketIDs.contains(bucket.id) },
                            set: { _ in settings.toggleFeatured(bucket.id) }))
                    }
                }
            }

            Section("Style") {
                Toggle("Icon + percent (vs. colored text)", isOn: $settings.useIconStyle)
            }

            Section("Accounts") {
                ForEach(model.accounts) { account in
                    HStack {
                        Text(account.label)
                        if account.id == model.activeAccountID {
                            Spacer()
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.switchAccount(account.id) }
                    .swipeActions {
                        if !account.isPrimary {
                            Button(role: .destructive) {
                                model.removeAccount(account.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    showAddAccount = true
                } label: {
                    Label("Add Account…", systemImage: "plus")
                }
            }

            Section {
                Link(destination: URL(string: "https://theportlandcompany.com/apps")!) {
                    Text("More apps by Spencer Hill & The Portland Company")
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showAddAccount) {
            NavigationStack { OnboardingView() }
        }
    }
}
