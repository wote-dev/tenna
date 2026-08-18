import Foundation
import Security
import CryptoKit

/// The Mac's stable TLS identity. Generated once, persisted in the login Keychain,
/// and pinned by the Android app via the SHA-256 of its public key.
enum TLSIdentity {

    /// The identity lives in a 0600 file under Application Support rather than the
    /// Keychain.
    ///
    /// The Keychain ties item access to the app's code signature. This app is ad-hoc
    /// signed, so *every rebuild* produces a new signature, the ACL stops matching, and
    /// `SecItemCopyMatching` blocks on a SecurityAgent password prompt — which hangs
    /// startup completely when nobody is watching for the dialog. File permissions plus
    /// FileVault are the right protection level for a personal LAN app.
    private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("TennaNova", isDirectory: true)
    }
    private static var p12URL: URL { supportDir.appendingPathComponent("identity.p12") }
    private static var passURL: URL { supportDir.appendingPathComponent("identity.key") }

    struct Loaded {
        let identity: SecIdentity
        let secIdentity: sec_identity_t
        /// Base64 SHA-256 of the public key — this is what Android pins.
        let spkiHash: String
    }

    /// Loads the existing identity, generating and persisting one on first run.
    static func loadOrCreate() throws -> Loaded {
        let (p12, password): (Data, String)
        if let existing = try? readStore() {
            (p12, password) = existing
        } else {
            let pw = randomToken()
            let data = try generateP12(password: pw)
            try writeStore(p12: data, password: pw)
            Log.info("generated a new TLS identity at \(supportDir.path)")
            (p12, password) = (data, pw)
        }

        let identity = try importIdentity(p12: p12, password: password)
        var certOut: SecCertificate?
        SecIdentityCopyCertificate(identity, &certOut)
        guard let cert = certOut, let hash = spkiHash(of: cert) else {
            throw TLSError.message("could not derive the public key hash")
        }
        guard let sec = sec_identity_create(identity) else {
            throw TLSError.message("sec_identity_create returned nil")
        }
        return Loaded(identity: identity, secIdentity: sec, spkiHash: hash)
    }

    /// Base64 SHA-256 over the certificate's public key bytes.
    static func spkiHash(of cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    static func randomToken(bytes: Int = 32) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return Data(buf).base64EncodedString()
    }

    // MARK: - Generation

    /// Shells out to the system openssl (always present at /usr/bin/openssl) to mint a
    /// self-signed cert. There is no public macOS API for creating certificates.
    private static func generateP12(password: String) throws -> Data {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tennanova-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = dir.appendingPathComponent("key.pem")
        let crt = dir.appendingPathComponent("cert.pem")
        let p12 = dir.appendingPathComponent("identity.p12")

        // RSA 2048, not EC. SecPKCS12Import *crashes* with an uncaught NSException on EC
        // keys on macOS 27 — it is not a recoverable error. Verified experimentally.
        try runOpenSSL(["req", "-x509", "-newkey", "rsa:2048",
                        "-keyout", key.path, "-out", crt.path,
                        "-days", "3650", "-nodes",
                        "-subj", "/CN=TennaNova Mac/O=TennaNova"])
        try runOpenSSL(["pkcs12", "-export", "-inkey", key.path, "-in", crt.path,
                        "-out", p12.path, "-passout", "pass:\(password)",
                        "-name", "TennaNova"])
        return try Data(contentsOf: p12)
    }

    private static func runOpenSSL(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "<no output>"
            throw TLSError.message("openssl \(args.first ?? "") failed: \(msg)")
        }
    }

    private static func importIdentity(p12: Data, password: String) throws -> SecIdentity {
        var items: CFArray?
        let opts: [String: Any] = [kSecImportExportPassphrase as String: password]
        let status = SecPKCS12Import(p12 as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let raw = first[kSecImportItemIdentity as String]
        else {
            throw TLSError.message("SecPKCS12Import failed (OSStatus \(status))")
        }
        return raw as! SecIdentity
    }

    // MARK: - Keychain

    private static func readStore() throws -> (Data, String) {
        let p12 = try Data(contentsOf: p12URL)
        let pw = try String(contentsOf: passURL, encoding: .utf8)
        return (p12, pw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func writeStore(p12: Data, password: String) throws {
        try FileManager.default.createDirectory(at: supportDir,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try p12.write(to: p12URL, options: [.atomic, .completeFileProtection])
        try Data(password.utf8).write(to: passURL, options: [.atomic, .completeFileProtection])
        for url in [p12URL, passURL] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        }
    }
}

enum TLSError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}
