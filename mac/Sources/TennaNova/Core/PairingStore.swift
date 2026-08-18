import Foundation

/// Remembers which phone is paired and the long-lived token it authenticates with.
/// Small enough that UserDefaults is the right tool; the secret it holds only grants
/// access to a listener that is already pinned to our TLS key.
final class PairingStore {

    private let key = "pairedDevice"
    private let tokenKey = "pairingToken"
    private let defaults = UserDefaults.standard

    /// The one-time token shown in the QR.
    ///
    /// Persisted deliberately: regenerating it on every launch invalidated any code the
    /// user had already scanned or copied, so restarting the Mac app silently broke
    /// pairing with `bad_token`. It is rotated when actually consumed, and on unpair.
    var pairingToken: String {
        if let existing = defaults.string(forKey: tokenKey) { return existing }
        let fresh = TLSIdentity.randomToken()
        defaults.set(fresh, forKey: tokenKey)
        return fresh
    }

    @discardableResult
    func rotatePairingToken() -> String {
        let fresh = TLSIdentity.randomToken()
        defaults.set(fresh, forKey: tokenKey)
        return fresh
    }

    struct Paired: Codable {
        var deviceId: String
        var name: String
        var token: String
    }

    var paired: Paired? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Paired.self, from: data)
    }

    func deviceToken(for deviceId: String) -> String? {
        guard let p = paired, p.deviceId == deviceId else { return nil }
        return p.token
    }

    func save(deviceId: String, name: String, token: String) {
        let p = Paired(deviceId: deviceId, name: name, token: token)
        if let data = try? JSONEncoder().encode(p) {
            defaults.set(data, forKey: key)
        }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
