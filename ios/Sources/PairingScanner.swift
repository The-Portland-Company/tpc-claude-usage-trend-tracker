import SwiftUI
import AVFoundation

/// "Pair with my Mac" — scans the QR the macOS app displays under
/// Settings ▸ "Set up on your phone" and decodes the token payload.
/// See docs/auth-and-pairing-spec.md §2.
struct PairingPayload: Decodable {
    let v: Int
    let t: String
    let r: String?
    let e: Double
    let s: [String]?
    let iat: Double
}

enum PairingError: Error {
    case unsupportedVersion
    case stale
    case malformed
}

enum PairingDecoder {
    /// Decodes and validates a scanned QR payload. Rejects unknown versions
    /// or payloads older than 90 seconds.
    static func decode(_ raw: String, now: Date = Date()) -> Result<PairingPayload, PairingError> {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PairingPayload.self, from: data) else {
            return .failure(.malformed)
        }
        guard payload.v == 1 else { return .failure(.unsupportedVersion) }
        let ageSeconds = now.timeIntervalSince1970 - (payload.iat / 1000)
        guard ageSeconds <= 90 else { return .failure(.stale) }
        return .success(payload)
    }
}

/// SwiftUI wrapper around an `AVCaptureSession` QR scanner.
struct PairingScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var didEmit = false
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didEmit,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        didEmit = true
        onCode?(value)
    }
}
