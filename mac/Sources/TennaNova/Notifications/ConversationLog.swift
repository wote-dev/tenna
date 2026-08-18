import Foundation

/// Which conversation a mirrored notification belongs to.
///
/// `conversationTitle` alone is not enough to group by. Android sets it conventionally
/// only for *group* chats, so keying on it would drop every one-to-one chat into its own
/// bucket per notification. `title` is the reliable chat name — the contact for a 1:1, the
/// group name for a group — but only for notifications that are conversations at all, so
/// it takes a check before it can be trusted.
///
/// Deliberately *not* `NotificationPresentationIdentity.threadIdentifier`. That one is
/// tuned for how macOS stacks cards in Notification Center; sharing it would mean a change
/// to how the window groups chats silently changed when the Mac re-alerts.
enum ConversationKey: Hashable, Codable {
    case conversation(pkg: String, title: String)
    case keyed(pkg: String, key: String)
    case app(pkg: String)

    init(_ n: NotifPosted) {
        let conversational = n.category == "msg"
            || !(n.senderName ?? "").isEmpty
            || n.actions.contains { $0.isReply }

        if let chat = n.conversationTitle, !chat.isEmpty {
            self = .conversation(pkg: n.pkg, title: chat)
        } else if conversational, let title = n.title, !title.isEmpty {
            self = .conversation(pkg: n.pkg, title: title)
        } else if conversational {
            self = .keyed(pkg: n.pkg, key: n.key)
        } else {
            // Everything transactional — delivery updates, digests, build failures —
            // shares one row per app rather than one row per ping.
            self = .app(pkg: n.pkg)
        }
    }

    var pkg: String {
        switch self {
        case let .conversation(pkg, _), let .keyed(pkg, _), let .app(pkg): return pkg
        }
    }

    /// Stable tiebreaker so equal timestamps cannot make the sidebar reorder itself.
    var sortKey: String {
        switch self {
        case let .conversation(pkg, title): return "\(pkg)#c#\(title)"
        case let .keyed(pkg, key):          return "\(pkg)#k#\(key)"
        case let .app(pkg):                 return "\(pkg)#a"
        }
    }
}

enum MessageOrigin: String, Codable, Equatable {
    case phone
    case mac
}

/// How far an outgoing reply has got.
///
/// `sent` genuinely only means the frame reached the socket — the protocol has no ack for
/// `notif.reply`, and the phone can still fail to fire the intent. `confirmed` is the
/// stronger claim, and it is only earned when the phone mirrors the message back.
enum DeliveryState: Codable, Equatable {
    case incoming
    case sending
    case sent
    case confirmed
    case failed(String)
}

struct MirroredMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    /// The `StatusBarNotification.key` this came from. Nil for messages we sent.
    var notificationKey: String?
    var fingerprint: String?
    var origin: MessageOrigin
    var senderName: String?
    var body: String
    var when: Date
    var avatarHash: String?
    var delivery: DeliveryState
}

struct ConversationThread: Identifiable, Codable, Equatable {
    var id: ConversationKey
    var pkg: String
    var appLabel: String
    var title: String
    var iconHash: String?
    var messages: [MirroredMessage] = []
    var lastActivity: Date
    var unreadCount: Int = 0
    /// False once the phone clears the notification. The transcript survives; the ability
    /// to reply into it does not, because Android drops the RemoteInput intent with it.
    var isLiveOnPhone: Bool = true
    /// The most recent notification key and its action list — the only pair a reply may
    /// use, since `actionId` is a positional index into whichever post it came from.
    var latestKey: String?
    var latestActions: [NotifAction] = []

    var latest: MirroredMessage? { messages.last }
}

struct ReplyTarget: Equatable {
    var key: String
    var actionId: Int
}

enum IngestOutcome: Equatable {
    case appended(ConversationKey)
    case replacedLatest(ConversationKey)
    case duplicate
    /// A phone post that turned out to be the echo of a reply we sent.
    case reconciledOutgoing(UUID)
}

/// Pure, testable reducer over everything the phone has mirrored.
///
/// Split out from the observable shell for the same reason `NotificationReplayGuard` is
/// split out from `NotificationPresenter`: all the behaviour worth testing lives here, and
/// none of it needs a main actor, a window, or a filesystem.
struct ConversationLog: Codable, Equatable {

    static let maxMessagesPerThread = 200
    static let maxThreads = 200
    /// A phone that mirrors our own reply back within this window is echoing it, not
    /// reporting a new message.
    static let echoWindow: TimeInterval = 30
    /// Two posts on one key this close together are one message settling, not two.
    static let coalesceWindow: TimeInterval = 1.5

    private(set) var threads: [ConversationKey: ConversationThread] = [:]

    var threadsByRecency: [ConversationThread] {
        threads.values.sorted {
            $0.lastActivity == $1.lastActivity
                ? $0.id.sortKey < $1.id.sortKey
                : $0.lastActivity > $1.lastActivity
        }
    }

    var totalUnread: Int { threads.values.reduce(0) { $0 + $1.unreadCount } }

    subscript(key: ConversationKey) -> ConversationThread? { threads[key] }

    // MARK: - Ingest

    @discardableResult
    mutating func ingest(_ n: NotifPosted, at now: Date = Date()) -> IngestOutcome {
        let key = ConversationKey(n)
        let fingerprint = NotificationPresentationIdentity(n).fingerprint
        let body = n.body ?? ""
        let sender = n.senderName ?? n.title
        let stamp = n.when.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? now

        var thread = threads[key] ?? ConversationThread(
            id: key,
            pkg: n.pkg,
            appLabel: n.appLabel,
            title: n.conversationTitle ?? n.senderName ?? n.title ?? n.appLabel,
            lastActivity: stamp
        )

        // Metadata always refreshes: a later post carries the current action list, and the
        // reply target must never be resolved from a stale one.
        thread.appLabel = n.appLabel
        if let icon = n.iconHash { thread.iconHash = icon }
        thread.latestKey = n.key
        thread.latestActions = n.actions
        thread.isLiveOnPhone = true

        defer { threads[key] = thread; evictThreadsIfNeeded() }

        // 1. Seen this exact content on this exact key already. Resync replays land here,
        //    which is what lets a reconnecting phone repopulate without duplicating.
        if thread.messages.contains(where: {
            $0.notificationKey == n.key && $0.fingerprint == fingerprint
        }) {
            return .duplicate
        }

        // 2. Our own reply coming back. Without this the optimistic bubble and the phone's
        //    mirror of it both show, and every sent message appears twice.
        if !body.isEmpty, let echoed = thread.messages.lastIndex(where: {
            $0.origin == .mac
                && $0.body == body
                && ($0.delivery == .sending || $0.delivery == .sent)
                && now.timeIntervalSince($0.when) < Self.echoWindow
        }) {
            thread.messages[echoed].delivery = .confirmed
            thread.lastActivity = max(thread.lastActivity, stamp)
            return .reconciledOutgoing(thread.messages[echoed].id)
        }

        // 3. The same notification settling — a title that arrives before its body, or a
        //    body that grows. Replacing keeps one bubble instead of a stuttering pair.
        if let last = thread.messages.indices.last,
           thread.messages[last].notificationKey == n.key,
           thread.messages[last].origin == .phone,
           body.hasPrefix(thread.messages[last].body)
            || now.timeIntervalSince(thread.messages[last].when) < Self.coalesceWindow {
            thread.messages[last].body = body
            thread.messages[last].fingerprint = fingerprint
            thread.messages[last].senderName = sender
            thread.messages[last].avatarHash = n.avatarHash ?? thread.messages[last].avatarHash
            thread.messages[last].when = stamp
            thread.lastActivity = max(thread.lastActivity, stamp)
            return .replacedLatest(key)
        }

        thread.messages.append(MirroredMessage(
            notificationKey: n.key,
            fingerprint: fingerprint,
            origin: .phone,
            senderName: sender,
            body: body,
            when: stamp,
            avatarHash: n.avatarHash,
            delivery: .incoming
        ))
        thread.lastActivity = max(thread.lastActivity, stamp)
        // A replay of something the user has already seen is not news.
        if n.resync != true { thread.unreadCount += 1 }
        trim(&thread)
        return .appended(key)
    }

    /// The phone cleared the notification. The transcript stays — a chat that vanishes
    /// when the phone tidies up is worse than useless — but replying is no longer possible.
    mutating func markRemovedOnPhone(key: String) {
        for (id, var thread) in threads where thread.latestKey == key {
            thread.isLiveOnPhone = false
            threads[id] = thread
        }
    }

    // MARK: - Outgoing

    @discardableResult
    mutating func appendOutgoing(_ text: String, to key: ConversationKey,
                                 at now: Date = Date()) -> UUID? {
        guard var thread = threads[key] else { return nil }
        let message = MirroredMessage(
            notificationKey: nil,
            fingerprint: nil,
            origin: .mac,
            senderName: nil,
            body: text,
            when: now,
            avatarHash: nil,
            delivery: .sending
        )
        thread.messages.append(message)
        thread.lastActivity = now
        trim(&thread)
        threads[key] = thread
        return message.id
    }

    mutating func markDelivery(_ id: UUID, _ state: DeliveryState) {
        for (key, var thread) in threads {
            guard let index = thread.messages.firstIndex(where: { $0.id == id }) else { continue }
            thread.messages[index].delivery = state
            threads[key] = thread
            return
        }
    }

    mutating func removeMessage(_ id: UUID) {
        for (key, var thread) in threads where thread.messages.contains(where: { $0.id == id }) {
            thread.messages.removeAll { $0.id == id }
            threads[key] = thread
            return
        }
    }

    // MARK: - Reading

    mutating func markRead(_ key: ConversationKey) {
        threads[key]?.unreadCount = 0
    }

    /// The only sanctioned way to address a reply.
    ///
    /// Resolves from the *latest* post's action list, because `actionId` is a positional
    /// index into whichever notification carried it — an id captured from an older message
    /// can silently invoke a different button.
    func replyTarget(for key: ConversationKey) -> ReplyTarget? {
        guard let thread = threads[key], thread.isLiveOnPhone,
              let notificationKey = thread.latestKey,
              let action = thread.latestActions.first(where: { $0.isReply })
        else { return nil }
        return ReplyTarget(key: notificationKey, actionId: action.id)
    }

    mutating func clear() { threads.removeAll() }

    // MARK: - Retention

    private func trim(_ thread: inout ConversationThread) {
        let overflow = thread.messages.count - Self.maxMessagesPerThread
        if overflow > 0 { thread.messages.removeFirst(overflow) }
    }

    private mutating func evictThreadsIfNeeded() {
        guard threads.count > Self.maxThreads else { return }
        let doomed = threads.values
            .sorted { $0.lastActivity < $1.lastActivity }
            .prefix(threads.count - Self.maxThreads)
        for thread in doomed { threads[thread.id] = nil }
    }
}
