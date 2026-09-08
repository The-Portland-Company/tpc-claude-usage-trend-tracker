import SwiftUI

/// "Set up on your phone" — shows a QR code encoding the active account's
/// token so the iOS/Android app can pair without hand-copying it. Generated
/// on demand, never persisted, and auto-hides after 60s.
struct PairingQRSheet: View {
    let model: UsageModel
    @Environment(\.dismiss) private var dismiss

    @State private var image: NSImage?
    @State private var backupCode: String?
    @State private var errorText: String?
    @State private var secondsLeft = 60
    @State private var timer: Timer?

    private let ttl = 60

    var body: some View {
        VStack(spacing: 14) {
            Text("Set up on your phone")
                .font(.system(size: 15, weight: .semibold))

            Text("Only scan this on a device you own — it transfers your Claude sign-in.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            if let errorText {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(errorText).font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 240, height: 240)
            } else if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                if let backupCode {
                    Text("Backup code: \(backupCode)")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("Hides automatically in \(secondsLeft)s")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 240, height: 240)
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { generate() }
        .onDisappear { stopTimer() }
    }

    private func generate() {
        stopTimer()
        errorText = nil
        image = nil
        backupCode = nil

        let result = model.buildPairing()
        if let error = result.errorText {
            errorText = error
            return
        }
        guard let payload = result.payload, let img = PairingQR.image(for: payload) else {
            errorText = "Couldn't render the QR code."
            return
        }
        image = img
        backupCode = result.backupCode
        secondsLeft = ttl
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                secondsLeft -= 1
                if secondsLeft <= 0 { dismiss() }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
