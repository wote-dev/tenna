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

    /// The phone mirrors its real SMS store — whole threads with history, live arrivals,
    /// and sending to any number, none of it dependent on a notification.
    ///
    /// This is the one messaging surface Android actually opens to a third-party app.
    /// WhatsApp, Signal and the rest expose nothing but their notifications, so those can
    /// only ever be replied to; SMS can be a real client.
    static let smsCapability = "sms.v1"

    /// The phone mirrors calls, and can answer, decline and end one on this Mac's behalf.
    ///
    /// Calls are read out of notifications rather than from a telephony API, which is what
    /// makes this cover WhatsApp and Signal calls as well as cellular ones. **Audio is not
    /// part of it and cannot be** — Android lets no third-party app capture voice-call
    /// audio — so this Mac rings and controls, and the sound stays on the phone. Every
    /// surface that offers a call button here says so.
    static let callCapability = "call.v1"
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

extension NotifPosted {
    /// Whether this is a person talking rather than an app announcing something.
    ///
    /// The two signals that do not misfire. A `msg` category and a `conversationTitle`
    /// both do: marketing notifications set them — the category buys priority — which is
    /// why the window's Messages tab asks this and not `ConversationKey.groupsAsChat`.
    var isSomebodyTalking: Bool {
        !(senderName ?? "").isEmpty || actions.contains { $0.isReply }
    }
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

/// Every notification key the phone still holds a reply action for.
///
/// Sent after the reconnect replay. The Mac's own history is not evidence: it remembers
/// that a conversation once offered a reply, but the intent lives only in the phone's
/// listener process, and a chat cleared before that process last started is gone.
struct NotifReplyKeys: Codable {
    var v = Proto.version
    var type = "notif.reply.keys"
    var keys: [String]
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

// MARK: - SMS

/// One conversation in the phone's SMS store.
///
/// `displayName` is resolved on the phone, which already holds `READ_CONTACTS`. That is
/// why there is no contacts protocol here and no contact cache on the Mac.
struct SmsThreadSummary: Codable, Equatable {
    var id: Int64
    var address: String
    var displayName: String
    var snippet: String
    var when: Int64
    var unread: Int
}

/// Whether two phone numbers are the same person.
///
/// Mirrors `SmsAddresses.normalize` on the phone and must keep agreeing with it: both
/// sides keep the last nine digits, because country code and trunk prefix are exactly the
/// parts that differ between spellings of one number and the subscriber part is the part
/// that does not. Short codes and alphanumeric sender ids are left whole — a five-digit
/// sender has no prefix to strip, and truncating one would merge unrelated services.
enum SmsAddressMatch {
    static let significantDigits = 9

    static func normalize(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else {
            return raw.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard digits.count > significantDigits else { return digits }
        return String(digits.suffix(significantDigits))
    }

    static func same(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }
}

struct SmsThreads: Codable {
    var v = Proto.version
    var type = "sms.threads"
    var threads: [SmsThreadSummary]
}

/// One text.
///
/// `outgoing` means "the user sent this", not "this device sent it" — a message typed on
/// the phone and one typed on the Mac read identically in a transcript.
struct SmsMessage: Codable, Equatable {
    var id: Int64
    var threadId: Int64
    var address: String
    var displayName: String?
    var body: String
    var when: Int64
    var outgoing: Bool
    var read: Bool

    var date: Date { Date(timeIntervalSince1970: Double(when) / 1000) }
}

struct SmsMessages: Codable {
    var v = Proto.version
    var type = "sms.messages"
    var threadId: Int64
    var messages: [SmsMessage]
    /// False while older messages remain, so the Mac knows it may page further back.
    var complete: Bool
}

struct SmsReceived: Codable {
    var v = Proto.version
    var type = "sms.received"
    var message: SmsMessage
}

struct SmsThreadRequest: Codable {
    var v = Proto.version
    var type = "sms.thread.request"
    var threadId: Int64
    var beforeId: Int64?
    var limit: Int
}

struct SmsSend: Codable {
    var v = Proto.version
    var type = "sms.send"
    var address: String
    var body: String
    var clientId: String
}

struct SmsSendResult: Codable {
    var v = Proto.version
    var type = "sms.send.result"
    var clientId: String
    var ok: Bool
    var threadId: Int64?
    var error: String?
}

// MARK: - Calls

/// Where a call is in its life. Decoded leniently from the wire: an unfamiliar state from
/// a newer phone build must not take the whole message down with it.
enum CallLifecycle: String, Codable {
    case ringing
    case active
    case ended
}

/// Which way the call went. Android does not say, so the phone infers it from how the call
/// was first seen; it is only ever used to label a row in the recents list.
enum CallDirection: String, Codable {
    case incoming
    case outgoing
}

/// One call, sent on every change to it. `ended` is the last one for an id.
///
/// `canAnswer` / `canDecline` / `canHangUp` are per call and not per phone: whether *this*
/// notification carried the intents, or whether the phone's Telecom fallback will take it.
/// Drawing a button that resolves to nothing is worse than drawing no button.
struct CallStateMessage: Codable {
    var v = Proto.version
    var type = "call.state"
    var id: String
    /// Raw rather than the enum: see `lifecycle`.
    var state: String
    var direction: String?
    var pkg: String
    var appLabel: String
    var iconHash: String?
    var avatarHash: String?
    var displayName: String?
    var number: String?
    var video: Bool?
    var when: Int64?
    var canAnswer: Bool?
    var canDecline: Bool?
    var canHangUp: Bool?
    /// Set when the phone is replaying a call that was already in progress after a
    /// reconnect. The Mac still shows it — it is happening *now* — but see `CallLog`.
    var resync: Bool?
    /// The dialer's own extra buttons, "Message" and the like. Answer and decline are not
    /// among them; those are resolved on the phone. These fire through `notif.action`,
    /// whose key is this same id.
    var actions: [NotifAction]?

    /// An unknown state is treated as the call being over, which is the safe reading: it
    /// stops a Mac from holding a card with live buttons for something it cannot follow.
    var lifecycle: CallLifecycle { CallLifecycle(rawValue: state) ?? .ended }
    var way: CallDirection { direction.flatMap(CallDirection.init(rawValue:)) ?? .incoming }
}

/// Answer, decline or hang up. `decline` and `hangup` are kept apart because they are
/// different buttons on different screens, and because a `CallStyle` notification carries
/// a separate intent for each.
enum CallActionKind: String, Codable {
    case answer
    case decline
    case hangup

    var label: String {
        switch self {
        case .answer:  return "Answer"
        case .decline: return "Decline"
        case .hangup:  return "Hang up"
        }
    }
}

struct CallActionInvoke: Codable {
    var v = Proto.version
    var type = "call.action"
    var id: String
    var action: String
    /// Echoed back in `call.action.result`, so a failure lands on the call it belongs to.
    var clientId: String?

    init(id: String, action: CallActionKind, clientId: String? = nil) {
        self.id = id
        self.action = action.rawValue
        self.clientId = clientId
    }
}

/// What the phone did about it. `error` is a sentence written for the user, and is shown
/// on the call card as it arrives.
struct CallActionResult: Codable {
    var v = Proto.version
    var type = "call.action.result"
    var clientId: String?
    var id: String
    var action: String
    var ok: Bool
    var error: String?
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
