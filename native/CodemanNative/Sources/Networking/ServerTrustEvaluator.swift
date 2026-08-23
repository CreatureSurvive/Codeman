import CryptoKit
import Foundation

/// Certificate pinning for self-signed Codeman servers.
///
/// A Codeman started with `--https` serves a self-signed certificate from `~/.codeman/certs/`.
/// Standard trust evaluation rejects it, so the app offers an explicit, per-server,
/// user-confirmed pin: the SHA-256 of the leaf certificate is shown, the user accepts once, and
/// the digest is stored with the server record.
///
/// Blanket `URLCredential(trust:)` acceptance is never used — that would silently accept *any*
/// certificate for that host forever, which is the exact failure mode pinning exists to prevent.
final class ServerTrustEvaluator: NSObject, URLSessionDelegate, @unchecked Sendable {
    /// `host -> expected leaf SHA-256 (lowercase hex)`.
    private let lock = NSLock()
    private var pins: [String: String] = [:]
    /// Set while a connection test is running so the UI can offer the digest to the user.
    private var lastRejectedPin: (host: String, sha256: String)?

    func setPin(_ sha256: String?, forHost host: String) {
        lock.lock()
        defer { lock.unlock() }
        if let sha256 { pins[host.lowercased()] = sha256.lowercased() } else { pins.removeValue(forKey: host.lowercased()) }
    }

    /// The digest of the most recent certificate that failed evaluation, so onboarding can show
    /// "this server presented <digest> — trust it?" instead of a bare failure.
    func takeLastRejectedPin() -> (host: String, sha256: String)? {
        lock.lock()
        defer { lock.unlock() }
        let value = lastRejectedPin
        lastRejectedPin = nil
        return value
    }

    static func sha256Hex(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Formats a digest for display: `AB:CD:EF:…` in uppercase, which is how every other tool
    /// shows a fingerprint, so a user can compare it against `openssl x509 -fingerprint`.
    static func displayFingerprint(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2)
            .map { offset -> String in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                let end = hex.index(start, offsetBy: min(2, hex.count - offset))
                return String(hex[start..<end]).uppercased()
            }
            .joined(separator: ":")
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host.lowercased()

        // System trust first: a properly signed server (including a Tailscale HTTPS cert) needs
        // no pin and must keep full validation.
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let digest = Self.sha256Hex(of: leaf)

        lock.lock()
        let expected = pins[host]
        lock.unlock()

        if let expected, expected == digest {
            Log.net.info("Accepted pinned certificate for host \(host, privacy: .private)")
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        lock.lock()
        lastRejectedPin = (host, digest)
        lock.unlock()

        Log.net.warning("Rejected untrusted certificate for host \(host, privacy: .private)")
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
