import Foundation
import CryptoKit

/// Identity and configuration for the internet relay.
///
/// The relay is a fallback, not a replacement: the phone only reaches for it once every
/// LAN address and the USB tunnel have failed. See `relay/README.md` for why it has to
/// exist at all — networks with AP client isolation drop every packet between their own
/// clients, and nothing in the LAN transport can survive that.
enum Relay {

    /// Overridable without a rebuild, because the person deploying the relay is the one
    /// who finds out what it ends up being called.
    ///
    ///     defaults write com.tennanova.mac relayHost tennanova-relay.fly.dev
    static let defaultHost = "tennanova-relay.fly.dev"

    static var host: String {
        let configured = UserDefaults.standard.string(forKey: "relayHost")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else { return defaultHost }
        return configured
    }

    /// Set to false to keep this Mac off the relay entirely and stay LAN + USB only.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "relayEnabled") as? Bool ?? true
    }

    /// Plain `ws` against a relay running on this machine, for testing the bridge end to
    /// end without a public certificate.
    ///
    /// Safe to expose because of what the outer hop actually protects: the relay only
    /// ever carries the pinned TLS session between phone and Mac, so dropping its own TLS
    /// exposes which room is in use and the traffic pattern — never a byte of content,
    /// and never the ability to impersonate either device. Off unless explicitly set.
    ///
    ///     defaults write com.tennanova.mac relayInsecureLocal -bool YES
    static var isInsecureLocal: Bool {
        UserDefaults.standard.bool(forKey: "relayInsecureLocal")
    }

    /// The public name of this Mac's room: `base64url(sha256(secret))`.
    ///
    /// A hash, so the phone can be told the room without being handed the ability to
    /// host it. Only the holder of the secret can be the Mac end of this room.
    static func roomId(for secret: String) -> String {
        base64url(Data(SHA256.hash(data: Data(secret.utf8))))
    }

    static func controlURL(secret: String) -> URL? {
        url(path: "/v1/host", query: [("secret", secret)])
    }

    static func acceptURL(secret: String, sid: String) -> URL? {
        url(path: "/v1/accept", query: [("secret", secret), ("sid", sid)])
    }

    private static func url(path: String, query: [(String, String)]) -> URL? {
        var components = URLComponents()
        // wss on 443: the one outbound port that every captive, filtered and corporate
        // network already has to allow, because it is what a browser uses.
        components.scheme = isInsecureLocal ? "ws" : "wss"
        // `host:port` is accepted so a relay running locally can be pointed at without a
        // second setting. A bare name — the real case — keeps the scheme's default port.
        let (name, port) = splitPort(host)
        components.host = name
        components.port = port
        components.path = path
        components.percentEncodedQuery = query
            .map { "\($0.0)=\(escape($0.1))" }
            .joined(separator: "&")
        return components.url
    }

    private static func splitPort(_ value: String) -> (String, Int?) {
        guard let colon = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: colon)...]),
              (1...65535).contains(port) else { return (value, nil) }
        return (String(value[..<colon]), port)
    }

    /// Percent-encodes a query *value*, `+` very much included.
    ///
    /// `URLComponents.queryItems` will not do this. It leaves `+`, `/` and `=` alone
    /// because all three are legal in a query — but the relay reads its parameters with
    /// `URLSearchParams`, which follows the form-encoding rule that a bare `+` means a
    /// space. The secret is base64 and therefore contains `+` more often than not, so
    /// the relay would have hashed a mangled string, hosted a room under a name the Mac
    /// never computed, and left every phone knocking on a door that does not exist.
    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Base64url without padding — it travels in a query string and in a QR code, and
    /// `+`, `/` and `=` are hostile in both.
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
