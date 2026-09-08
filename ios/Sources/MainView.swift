import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: UsageModel
    @State private var showAddAccount = false

    var body: some View {
        List {
            Section {
                Text(model.verdictText)
                    .font(.headline)
            }

            if !model.buckets.isEmpty {
                Section("Usage") {
                    ForEach(model.buckets) { bucket in
                        BucketRow(bucket: bucket)
                    }
                }
            }

            if let extra = model.snapshot?.extraUsage, extra.isEnabled {
                Section("Overage credits") {
                    OverageRow(extra: extra)
                }
            }

            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .refreshable { await model.refresh() }
        .navigationTitle("Claude Usage")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                accountMenu
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink { SettingsView() } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showAddAccount) {
            NavigationStack { OnboardingView() }
        }
    }

    private var accountMenu: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    model.switchAccount(account.id)
                } label: {
                    if account.id == model.activeAccountID {
                        Label(account.label, systemImage: "checkmark")
                    } else {
                        Text(account.label)
                    }
                }
            }
            Divider()
            Button {
                showAddAccount = true
            } label: {
                Label("Add Account…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                Text(model.accounts.first { $0.id == model.activeAccountID }?.label ?? "Account")
                    .lineLimit(1)
            }
        }
    }
}

private struct BucketRow: View {
    let bucket: BucketDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bucket.title).font(.body.weight(.medium))
                Spacer()
                Text(bucket.trend.rawValue).foregroundStyle(.secondary)
                Text("\(Int(bucket.limit.percent))%")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color(severity: bucket.severity))
            }

            ProgressView(value: min(bucket.limit.percent, 100), total: 100)
                .tint(Color(severity: bucket.severity))

            HStack {
                if let countdown = bucket.resetCountdown {
                    Text("Resets \(countdown)")
                }
                Spacer()
                if let projection = bucket.projection, projection.overPace {
                    Text("Over pace").foregroundStyle(Color(severity: .warning))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct OverageRow: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Overage credits")
                Spacer()
                Text("\(Int(extra.utilization))%").font(.body.monospacedDigit())
            }
            Text("$\(extra.usedCredits / 100, specifier: "%.2f") of $\(extra.monthlyLimit / 100, specifier: "%.2f") this month")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
