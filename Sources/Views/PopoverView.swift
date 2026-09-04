import SwiftUI
import AppKit

struct PopoverView: View {
    let model: UsageModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var now = Date()
    @State private var notifyWeekly = true
    @State private var notifySession = false
    @State private var launchAtLogin = false
    @State private var launchError: String?

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error = model.lastError { banner(error) }
            rows
            Divider()
            Text(model.verdict)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        HStack {
            Text("Claude Meter").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(updatedText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            refreshButton
        }
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
            HStack {
                Button("Open Claude Code") { openTerminalApp() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.system(size: 11))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 11))
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
