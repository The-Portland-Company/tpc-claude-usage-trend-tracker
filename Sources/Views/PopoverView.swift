import SwiftUI
import AppKit

struct PopoverView: View {
    let model: UsageModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var now = Date()
    @State private var notifyWeekly = true
    @State private var notifySession = false
    @State private var launchAtLogin = false
    @State private var launchError: String?

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.hasNoAccounts {
                signInPrompt
            } else {
                verdictLine
                if let error = model.lastError { banner(error) }
                rows
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            now = Date()
            notifyWeekly = model.notifyWeeklyReset
            notifySession = model.notifySessionReset
            launchAtLogin = LaunchAtLogin.isEnabled
            Task { await model.refresh() }
        }
        .onReceive(tick) { now = $0 }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Claude Usage Trend Tracker").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(updatedText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                refreshButton
            }
            HStack(spacing: 6) {
                accountSwitcher
                if !model.hasNoAccounts, let billing = nextBillingText {
                    Spacer(minLength: 6)
                    HStack(spacing: 3) {
                        Image(systemName: "creditcard").font(.system(size: 10))
                        Text(billing).font(.system(size: 10)).lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .help("Next billing cycle")
                    .accessibilityLabel("Next billing cycle \(billing)")
                }
            }
        }
    }

    /// "Renews Sep 17"-style label for the active account's next billing date.
    private var nextBillingText: String? {
        guard let date = model.nextBillingDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "Renews " + f.string(from: date)
    }

    private var accountSwitcher: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    model.setActiveAccount(account.id)
                } label: {
                    if account.id == model.activeAccountID {
                        Label(accountLabel(account), systemImage: "checkmark")
                    } else {
                        Text(accountLabel(account))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "person.crop.circle").font(.system(size: 10))
                Text(accountLabel(model.activeAccount))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .opacity(model.hasNoAccounts ? 0 : 1)
        .disabled(model.hasNoAccounts)
    }

    // MARK: Sign-in empty state

    private var signInPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in to track your Claude usage")
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Connect your Claude account to see how close you are to your limits.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ClaudeSignInView(model: model, compact: true)
            Text("Or open Settings to pair with your Mac or paste a token.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Prefer the account's known email, else its label.
    private func accountLabel(_ account: Account) -> String {
        model.email(for: account.id) ?? account.label
    }

    // MARK: Verdict (prominent, top)

    private var verdictLine: some View {
        Text(model.verdict)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(severity: model.verdictSeverity))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            if model.isRefreshing {
                if reduceMotion {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(model.isRefreshing)
        .help("Refresh now")
        .accessibilityLabel("Refresh now")
    }

    private var updatedText: String {
        guard let last = model.lastGoodAt else { return "No data yet" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "Updated " + f.localizedString(for: last, relativeTo: now)
    }

    // MARK: Error banner

    private func banner(_ message: String) -> some View {
        let stale = model.isStale
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: stale ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(stale ? Color.orange : Color.red)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Retry") { Task { await model.refresh() } }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(8)
        .background((stale ? Color.orange : Color.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Rows

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.buckets) { b in
                BucketRow(title: b.title,
                          percent: b.percent,
                          severity: b.severity,
                          resetsAt: b.resetsAt,
                          projection: b.projection,
                          samples: b.samples,
                          now: now)
            }
            if let extra = model.extraUsage {
                BucketRow(title: "Overage credits",
                          percent: extra.utilization,
                          severity: PaceMath.severity(percent: extra.utilization, projection: nil),
                          resetsAt: nil,
                          projection: nil,
                          samples: [],
                          now: now)
                Text("\(Self.dollars(extra.usedCredits)) of \(Self.dollars(extra.monthlyLimit)) this month")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .offset(y: -6)
            }
            if model.buckets.isEmpty && model.extraUsage == nil {
                Text("Waiting for the first reading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Credits arrive in cents.
    static func dollars(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Notify on weekly reset", isOn: $notifyWeekly)
                .onChange(of: notifyWeekly) { _, v in model.notifyWeeklyReset = v }
            Toggle("Notify on 5-hour reset", isOn: $notifySession)
                .onChange(of: notifySession) { _, v in model.notifySessionReset = v }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in
                    launchError = LaunchAtLogin.set(v)
                    if launchError != nil { launchAtLogin = LaunchAtLogin.isEnabled }
                }
            if let launchError {
                Text(launchError).font(.system(size: 10)).foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                iconButton("terminal", help: "Open Claude Code") { openTerminalApp() }
                iconButton("gearshape", help: "Settings") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                iconButton("power", help: "Quit") { NSApplication.shared.terminate(nil) }
            }
            HStack {
                Link(destination: URL(string: "https://theportlandcompany.com/apps")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                        Text("More apps by Spencer Hill & The Portland Company")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 11))
    }

    /// A borderless SF Symbol button with a hover tooltip, matching `refreshButton`.
    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private func openTerminalApp() {
        let iTerm = URL(fileURLWithPath: "/Applications/iTerm.app")
        if FileManager.default.fileExists(atPath: iTerm.path) {
            _ = NSWorkspace.shared.open(iTerm)
        } else {
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
}
