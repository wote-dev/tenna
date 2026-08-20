import Foundation
import Security
import CryptoKit

/// The Mac's stable TLS identity. Generated once, persisted under Application Support,
/// and pinned by the Android app via the SHA-256 of its public key.
///
/// **This file builds with a dozen `SecKeychain is deprecated` warnings, and that is
/// expected.** The replacement — the data-protection keychain — is gated on an
/// `application-identifier` entitlement, which needs a paid Apple Developer account and a
/// provisioning profile. Tennanova is ad-hoc signed so that anyone can build it from a
/// clone, so the deprecated file-keychain API is the only one available. It is the same API
/// the `security` command line tool uses and it works correctly; Swift has no way to
/// silence one diagnostic group for one file, so the warnings stay.
enum TLSIdentity {

    /// The identity is stored as a 0600 p12 under Application Support rather than in the
    /// login Keychain.
    ///
    /// The login Keychain ties item access to the app's code signature. This app is ad-hoc
    /// signed, so *every rebuild* produces a new signature, the ACL stops matching, and
    /// using the key blocks on a SecurityAgent password prompt — which hangs startup
    /// completely when nobody is watching for the dialog. File permissions plus FileVault
    /// are the right protection level for a personal LAN app.
    private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("TennaNova", isDirectory: true)
    }
    private static var p12URL: URL { supportDir.appendingPathComponent("identity.p12") }
    private static var passURL: URL { supportDir.appendingPathComponent("identity.key") }

    /// A keychain of our own, holding exactly one identity.
    ///
    /// `SecPKCS12Import` has to put the key *somewhere* — on macOS a `SecIdentity` only
    /// exists inside a keychain, and there is no API that makes one out of loose bytes.
    /// Left to itself it picks the **login** keychain, which is what produced the recurring
    /// "Tennanova wants to sign using key" dialog: one key per build, each with an ACL
    /// naming a code signature that no longer exists. Pointing the import at a keychain
    /// this app owns, unlocked with the token already sitting in `identity.key`, keeps all
    /// of that out of the user's keychain entirely.
    private static var keychainURL: URL {
        supportDir.appendingPathComponent("identity.keychain-db")
    }

    struct Loaded {
        let identity: SecIdentity
        let secIdentity: sec_identity_t
        /// Base64 SHA-256 of the public key — this is what Android pins.
        let spkiHash: String
    }

    /// Loads the existing identity, generating and persisting one on first run.
    static func loadOrCreate() throws -> Loaded {
        // Nothing in here may ever raise a SecurityAgent dialog. With interaction off, a
        // call that *would* prompt returns `errSecInteractionNotAllowed` instead, so the
        // worst case is a logged error rather than a launch blocked on an invisible
        // password box. Process-wide, hence the immediate restore.
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }

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

        // Inside the same no-interaction window, and after the identity we actually need is
        // in hand, so a failure here can never keep the server from starting.
        purgeLoginKeychainLeftovers()

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

    /// The subject the generated certificate carries. Named here because the login-keychain
    /// cleanup below identifies this app's leftovers by it.
    static let commonName = "TennaNova Mac"

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
                        "-subj", "/CN=\(commonName)/O=TennaNova"])
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

    // MARK: - Importing

    /// Puts the identity into a keychain this app owns, reachable without a password prompt
    /// no matter how many times the app is rebuilt and re-signed.
    private static func importIdentity(p12: Data, password: String) throws -> SecIdentity {
        let keychain = try openIdentityKeychain(password: password)
        let access = try permissiveAccess()

        var items: CFArray?
        let opts: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportExportKeychain as String: keychain,
            kSecImportExportAccess as String: access
        ]
        let status = SecPKCS12Import(p12 as CFData, opts as CFDictionary, &items)

        // The keychain survived a delete that failed and already holds this identity. The
        // copy in there was imported by this same code, so its ACL is the permissive one.
        if status == errSecDuplicateItem, let existing = findIdentity(in: keychain) {
            return existing
        }

        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let raw = first[kSecImportItemIdentity as String]
        else {
            throw TLSError.message("SecPKCS12Import failed (OSStatus \(status))")
        }
        return raw as! SecIdentity
    }

    /// A freshly created, never-locking keychain at ``keychainURL``.
    ///
    /// Recreated on every launch rather than reused. It holds nothing that is not already
    /// in `identity.p12`, so throwing it away is free — and it means exactly one item, no
    /// accumulation, and no ACL that can drift out of step with the p12 beside it.
    private static func openIdentityKeychain(password: String) throws -> SecKeychain {
        try FileManager.default.createDirectory(at: supportDir,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let path = keychainURL.path
        var keychain: SecKeychain?

        // Best-effort: an open handle elsewhere can refuse the delete, and the duplicate
        // branch below is the answer to that.
        if SecKeychainOpen(path, &keychain) == errSecSuccess, let stale = keychain {
            SecKeychainDelete(stale)
        }
        keychain = nil

        var status = password.withCString { pw in
            SecKeychainCreate(path, UInt32(strlen(pw)), pw, false, nil, &keychain)
        }
        if status == errSecDuplicateKeychain {
            status = SecKeychainOpen(path, &keychain)
        }
        guard status == errSecSuccess, let kc = keychain else {
            throw TLSError.message("could not open the identity keychain (OSStatus \(status))")
        }

        // The half of the fix that answers "it comes back whenever I leave my Mac". A
        // keychain that never relocks — not on sleep, not on a timer — is never in a state
        // that needs a password to get back into.
        var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
                                           lockOnSleep: false,
                                           useLockInterval: false,
                                           lockInterval: .max)
        SecKeychainSetSettings(kc, &settings)

        // Explicit, so a keychain somehow left locked still opens silently.
        _ = password.withCString { pw in
            SecKeychainUnlock(kc, UInt32(strlen(pw)), pw, true)
        }

        // Security creates it 0644. It holds the same private key as the p12 beside it, so
        // it gets the same 0600 the p12 has rather than the default.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: path)

        removeFromSearchList(kc, path: path)
        return kc
    }

    /// Takes our keychain back out of the user's search list.
    ///
    /// `SecKeychainCreate` adds it automatically. Nothing here needs it there — every
    /// lookup names the keychain explicitly — and leaving it would put a stray "identity"
    /// keychain in Keychain Access's sidebar and in every other app's item searches.
    private static func removeFromSearchList(_ keychain: SecKeychain, path: String) {
        var listRef: CFArray?
        guard SecKeychainCopySearchList(&listRef) == errSecSuccess,
              let list = listRef as? [SecKeychain] else { return }

        let filtered = list.filter { entry in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            var length = UInt32(buffer.count)
            guard SecKeychainGetPath(entry, &length, &buffer) == errSecSuccess else {
                // Unreadable path: keep it. Dropping a keychain we cannot identify would be
                // editing the user's search list on a guess.
                return true
            }
            return String(cString: buffer) != path
        }
        guard filtered.count != list.count else { return }
        SecKeychainSetSearchList(filtered as CFArray)
    }

    private static func findIdentity(in keychain: SecKeychain) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchSearchList as String: [keychain] as CFArray,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let result = out else { return nil }
        return (result as! SecIdentity)
    }

    /// An ACL that trusts **every** application, which is what stops the prompt for good.
    ///
    /// `SecAccessCreate` on its own would trust only the process that created the item —
    /// this build of this app, identified by its ad-hoc signature. That is precisely the
    /// ACL that stopped matching after every rebuild. Rewriting each ACL's application list
    /// to NULL means "any application, no warning": the programmatic form of `security
    /// import -A`. Safe here because the item is the only thing in a keychain unlocked by a
    /// token that lives in a 0600 file beside it — the ACL was never what protected it.
    private static func permissiveAccess() throws -> SecAccess {
        var access: SecAccess?
        let status = SecAccessCreate("Tennanova" as CFString, nil, &access)
        guard status == errSecSuccess, let access else {
            throw TLSError.message("SecAccessCreate failed (OSStatus \(status))")
        }

        var aclsRef: CFArray?
        if SecAccessCopyACLList(access, &aclsRef) == errSecSuccess,
           let acls = aclsRef as? [SecACL] {
            for acl in acls {
                SecACLSetContents(acl, nil, "" as CFString, SecKeychainPromptSelector())
            }
        }
        return access
    }

    // MARK: - Cleaning up after earlier builds

    private static let purgeFlag = "didPurgeLoginKeychainIdentities.v1"

    /// Removes the certificate/key pairs earlier builds left in the login keychain.
    ///
    /// Every launch before this change imported a fresh copy, so a machine that has run
    /// this app for a while has one pair per build sitting in Keychain Access. They are
    /// inert now that nothing looks them up, but they are the user's clutter and this app
    /// put them there.
    ///
    /// Entirely best-effort. It runs with user interaction disabled, so an item whose ACL
    /// would demand a password returns an error instead of showing one; that item simply
    /// stays, and the README says how to remove it by hand.
    private static func purgeLoginKeychainLeftovers() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: purgeFlag) else { return }
        defaults.set(true, forKey: purgeFlag)

        var out: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let certificates = out as? [SecCertificate] else { return }

        var removed = 0
        for cert in certificates {
            var nameRef: CFString?
            SecCertificateCopyCommonName(cert, &nameRef)
            guard (nameRef as String?) == commonName else { continue }

            // The key first: once its certificate is gone there is nothing left to derive
            // the key's identifier from. `kSecAttrApplicationLabel` on a key is the SHA-1
            // of the public key, so this names one specific key — unlike matching on the
            // label "Imported Private Key", which every app's imports share.
            if let key = SecCertificateCopyKey(cert),
               let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data? {
                let keyQuery: [String: Any] = [
                    kSecClass as String: kSecClassKey,
                    kSecAttrApplicationLabel as String: Data(Insecure.SHA1.hash(data: bytes))
                ]
                let status = SecItemDelete(keyQuery as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    Log.info("left a stale private key in the login keychain (OSStatus \(status))")
                }
            }

            let status = SecItemDelete([kSecValueRef as String: cert] as CFDictionary)
            if status == errSecSuccess {
                removed += 1
            } else if status != errSecItemNotFound {
                Log.info("left a stale certificate in the login keychain (OSStatus \(status))")
            }
        }

        if removed > 0 {
            Log.info("removed \(removed) leftover identit\(removed == 1 ? "y" : "ies") "
                     + "from the login keychain")
        }
    }

    // MARK: - Store

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
        // A new identity means the old keychain describes a key that no longer matters, and
        // leaving it would have the next launch try to unlock it with the wrong password.
        try? FileManager.default.removeItem(at: keychainURL)
    }
}

enum TLSError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}
