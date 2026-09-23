import Foundation
import AppKit
import CoreImage
import CryptoKit

/// The compact pairing payload handed to a phone over the camera. Mirrors
/// docs/auth-and-pairing-spec.md §2. Never written to disk or logged.
struct PairingPayload: Encodable {
    let v = 1
    let t: String
    let r: String?
    let e: Double?
    let s: [String]
    let iat: Double

    enum CodingKeys: String, CodingKey { case v, t, r, e, s, iat }
}

/// Builds the on-demand QR pairing payload for the active account and
/// renders it with CoreImage's built-in generator — no network, no
/// third-party dependency, nothing persisted.
enum PairingQR {
    enum Error: Swift.Error {
        case noToken(String)
    }

    /// Builds the payload + a short display-only backup code for `account`.
    static func build(accountStore: AccountStore, account: Account) throws -> (payload: PairingPayload, backupCode: String) {
        do {
            let creds = try accountStore.pairingCredentials(for: account.id)
            // The refresh token is deliberately withheld. Refresh tokens rotate:
            // whichever device renews first revokes the other's copy, which
            // silently signed the Mac out once a paired phone renewed. The
            // phone gets the access token only and signs in on its own later.
            let payload = PairingPayload(
                t: creds.accessToken,
                r: nil,
                e: creds.expiresAt.map { $0.timeIntervalSince1970 * 1000 },
                s: creds.scopes,
                iat: Date().timeIntervalSince1970 * 1000)
            return (payload, backupCode(for: payload))
        } catch let e as AccountStore.TokenError {
            throw Error.noToken(Self.describe(e))
        }
    }

    private static func describe(_ e: AccountStore.TokenError) -> String {
        switch e {
        case .primaryUnavailable: return "Claude Code sign-in not found in Keychain."
        case .noToken: return "No stored sign-in for this account."
        case .signInExpired: return "Sign-in expired — update it in Settings."
        }
    }

    /// A short, display-only code derived from the payload (not a secret by
    /// itself — it's a human-readable check the phone's UI can show, not an
    /// alternate way to transmit the token).
    private static func backupCode(for payload: PairingPayload) -> String {
        guard let data = try? JSONEncoder().encode(payload) else { return "--------" }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8).uppercased()
    }

    /// Renders `payload` as a QR code image. Returns nil if encoding or
    /// rendering fails.
    static func image(for payload: PairingPayload, pointSize: CGFloat = 240) -> NSImage? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // The generator produces a tiny image (one point per module); scale
        // up with nearest-neighbor so modules stay crisp.
        let scale = pointSize / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
