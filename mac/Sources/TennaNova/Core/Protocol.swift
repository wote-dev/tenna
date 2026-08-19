import Foundation

/// Wire protocol v1. Mirrors `protocol/PROTOCOL.md` — change both together.
enum Proto {
    static let version = 1
    static let bonjourType = "_tennanova._tcp"
    static let defaultPort: UInt16 = 18777
    static let imageClipboardCapability = "clip.image.v1"

    /// The phone keeps a notification's reply action after the notification is gone, and
    /// answers every `notif.reply` with a `notif.reply.result`.
    ///
    /// Without it the Mac must keep refusing to compose into a conversation the phone is
    /// no longer showing, because such a reply would be dropped in silence. Messaging
    /// apps withdraw their notification the moment the chat is read on the phone, so that
    /// refusal is the normal case, not the edge one.
    static let offlineReplyCapability = "notif.reply.offline.v1"
    static let maxImageBytes = 25 * 1024 * 1024

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// Every message starts with these two fields; decode this first to learn what follows.
struct Envelope: Codable {
    let v: Int
    let type: String
}

// MARK: - Session

struct DeviceInfo: Codable {
    var id: String
    var name: String
    var model: String?
    var androidSdk: Int?
    var battery: Int?
}

struct Hello: Codable {
    var v = Proto.version
    var type = "hello"
    var token: String?          // one-time pairing token, first connection only
    var deviceToken: String?    // long-lived, every subsequent connection
    var device: DeviceInfo
    var capabilities: [String]?
}

struct HelloAck: Codable {
    var v = Proto.version
    var type = "hello.ack"
    var ok = true
    var deviceToken: String?
    var macName: String
    /// Every address this Mac is currently reachable on. Re-taught on every connection
    /// so the phone's list survives the Mac moving between a LAN and a hotspot without
    /// anyone rescanning the pairing QR.
    var hosts: [String] = []
    var port: Int = Int(Proto.defaultPort)
    /// See `MacHosts.usbPort`. Repeated here so a reconnecting phone re-learns the USB
    /// endpoint immediately rather than waiting for the next address change.
    var usbPort: Int?
    /// Where this Mac can be reached when the local network refuses to carry traffic
    /// between its own clients.
    ///
    /// Sent on every connection rather than only in the QR, for the same reason as
    /// `usbPort`: phones paired before the relay existed, or before it was deployed,
    /// would otherwise never learn about it without rescanning a code — and the moment
    /// they need it is the moment they cannot reach the Mac to be told.
    var relayHost: String?
    var relayRoom: String?
    var capabilities: [String] = [Proto.imageClipboardCapability]
}

/// Sent mid-session when the Mac gains or loses an address — joining a phone hotspot
/// while still on Ethernet, say. Purely additive: a phone that ignores it simply keeps
/// the list it was given at `hello.ack`.
struct MacHosts: Codable {
    var v = Proto.version
    var type = "mac.hosts"
    var hosts: [String]
    var port: Int
    /// The loopback port, present only while the `adb reverse` tunnel is actually up.
    ///
    /// It has to travel here and not only in the pairing QR. The tunnel normally comes up
    /// *after* pairing — a phone gets plugged in once it is already paired — so a QR-only
    /// `usbPort` means a phone paired while unplugged can never learn the USB endpoint at
    /// all. On a network with AP client isolation that leaves it with no route to the Mac.
    ///
    /// Absent means "no USB right now", not "unchanged": like `hosts`, this message is the
    /// Mac's complete account of where it can be reached, so the phone replaces rather
    /// than merges.
    var usbPort: Int?
    /// Where this Mac can be reached when the local network refuses to carry traffic
    /// between its own clients.
    ///
    /// Sent on every connection rather than only in the QR, for the same reason as
    /// `usbPort`: phones paired before the relay existed, or before it was deployed,
    /// would otherwise never learn about it without rescanning a code — and the moment
    /// they need it is the moment they cannot reach the Mac to be told.
    var relayHost: String?
    var relayRoom: String?
}

struct HelloNack: Codable {
    var v = Proto.version
    var type = "hello.nack"
    var reason: String          // bad_token | version_mismatch
}

struct DeviceState: Codable {
    var v = Proto.version
    var type = "device.state"
    var battery: Int?
    var charging: Bool?
    var dnd: Bool?
}

// MARK: - Notifications

struct NotifAction: Codable, Equatable {
    var id: Int
    var label: String
    var isReply: Bool
}

struct NotifPosted: Codable {
    var v = Proto.version
    var type = "notif.posted"
    /// `StatusBarNotification.key` — opaque, and the identity we key everything on.
    var key: String
    var pkg: String
    var appLabel: String
    var iconHash: String?
    /// Content hash of the sender's photo, fetched over the same channel as `iconHash`.
    /// Optional and currently unused for display: the card's thumbnail is the app icon,
    /// since that is the only place a mirrored card can say which app it came from.
    var avatarHash: String?
    var title: String?
    var body: String?
    var when: Int64?
    var category: String?
    /// Sender and chat, when the phone notification carried a MessagingStyle. Used to
    /// group a conversation's cards together the way macOS groups its own.
    var senderName: String?
    var conversationTitle: String?
    /// Set when the phone is replaying its active notifications after a reconnect rather
    /// than reporting something new. Those must never re-alert.
    var resync: Bool?
    var actions: [NotifAction]
}

struct NotifRemoved: Codable {
    var v = Proto.version
    var type = "notif.removed"
    var key: String
}

struct NotifReply: Codable {
    var v = Proto.version
    var type = "notif.reply"
    var key: String
    var actionId: Int
    var text: String
    /// The bubble this belongs to, echoed back in `notif.reply.result`. A phone without
    /// `notif.reply.offline.v1` ignores the field, exactly as it ignored it before.
    var clientId: String?
}

/// What the phone did with a `notif.reply`.
///
/// The only thing that ever told the Mac a reply had failed was the socket being down.
/// A phone can also have no action for that key any more, or an app can have withdrawn
/// its reply intent — both silent until this existed.
struct NotifReplyResult: Codable {
    var v = Proto.version
    var type = "notif.reply.result"
    var clientId: String?
    var key: String
    var actionId: Int
    var ok: Bool
    var error: String?
}

struct NotifActionInvoke: Codable {
    var v = Proto.version
    var type = "notif.action"
    var key: String
    var actionId: Int
}

struct NotifDismiss: Codable {
    var v = Proto.version
    var type = "notif.dismiss"
    var key: String
}

// MARK: - Icons

struct IconRequest: Codable {
    var v = Proto.version
    var type = "icon.request"
    var hash: String
}

struct IconData: Codable {
    var v = Proto.version
    var type = "icon.data"
    var hash: String
    var bytes: Int

    var hasValidMetadata: Bool {
        bytes > 0 && bytes <= 2 * 1024 * 1024 && Proto.isLowercaseSHA256(hash)
    }
}

// MARK: - Clipboard

struct ClipUpdate: Codable {
    var v = Proto.version
    var type = "clip.update"
    var format = "text"
    var body: String
    var origin: String          // "android" | "mac"
    var seq: Int
}

/// Metadata for a single image. The next WebSocket binary frame contains exactly
/// `bytes` bytes and must hash to `sha256`.
struct ClipImage: Codable {
    var v = Proto.version
    var type = "clip.image"
    var origin: String
    var seq: Int
    var mime: String
    var bytes: Int
    var sha256: String
    var name: String?

    func hasValidMetadata(expectedOrigin: String) -> Bool {
        origin == expectedOrigin && seq >= 0 && bytes > 0 && bytes <= Proto.maxImageBytes &&
            mime.count <= 100 && mime.hasPrefix("image/") &&
            Proto.isLowercaseSHA256(sha256) && (name?.count ?? 0) <= 120
    }
}

// MARK: - Coding helpers

enum Wire {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func utf8(_ value: String) -> Data {
        Data(value.utf8)
    }

    /// Reads just the envelope so the caller can switch on `type`.
    static func peek(_ data: Data) -> Envelope? {
        try? decoder.decode(Envelope.self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
