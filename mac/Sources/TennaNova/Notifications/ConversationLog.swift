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
    /// A real SMS conversation, keyed on the phone's own thread id.
    ///
    /// Deliberately a case here rather than a second store. SMS and WhatsApp threads
    /// belong in one inbox, and this way the whole tested reducer — recency ordering,
    /// unread counts, the optimistic-send state machine, retention — applies to both.
    case sms(threadId: Int64)

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

    /// The Android package a thread came from. SMS has no single package — the point of
    /// the SMS channel is that it bypasses whichever app happens to display texts.
    static let smsPseudoPackage = "sms"

    var pkg: String {
        switch self {
        case let .conversation(pkg, _), let .keyed(pkg, _), let .app(pkg): return pkg
        case .sms: return Self.smsPseudoPackage
        }
    }

    var isSms: Bool {
        if case .sms = self { return true }
        return false
    }

    /// Stable tiebreaker so equal timestamps cannot make the sidebar reorder itself.
    var sortKey: String {
        switch self {
        case let .conversation(pkg, title): return "\(pkg)#c#\(title)"
        case let .keyed(pkg, key):          return "\(pkg)#k#\(key)"
        case let .app(pkg):                 return "\(pkg)#a"
        case let .sms(threadId):            return "sms#\(threadId)"
        }
    }
}

/// Who a message came from, not which machine typed it.
///
/// `.mac` reads as "ours" throughout the UI. For SMS that covers a text sent from the
/// phone as much as one sent from the window — to whoever is reading the thread they are
/// the same thing, and the raw string is what history.json already holds.
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
    /// For `.sms` threads: the number to text. Notification threads reply through their
    /// own action instead and leave this nil.
    var smsAddress: String?
    /// The phone's own one-line preview, shown until this thread's history is fetched.
    /// A summary carries a snippet, not a transcript, so a never-opened SMS thread would
    /// otherwise sit blank in the sidebar.
    var snippet: String?

    var latest: MirroredMessage? { messages.last }

    /// The one line the sidebar shows under the thread name.
    ///
    /// A group chat prefixes the speaker, because "are you close?" with no name attached
    /// is meaningless there. A one-to-one does not: the row title already names the only
    /// other person in it, so the prefix would be pure repetition.
    var preview: String {
        guard let latest else { return snippet ?? "" }
        if latest.origin == .mac { return "You: \(latest.body)" }
        guard let sender = latest.senderName, !sender.isEmpty, sender != title else {
            return latest.body
        }
        return "\(sender): \(latest.body)"
    }
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

    /// Notification keys the phone has said it can still reply to.
    ///
    /// Authoritative and phone-owned: the reply travels through a `PendingIntent` held in
    /// the phone's listener process, so only the phone knows whether one survives. Grows
    /// as notifications arrive, and is replaced wholesale on every reconnect.
    private(set) var replyableKeys: Set<String> = []

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
        // The phone has just captured this notification's actions, so it can reply to it
        // for as long as its listener lives. `notif.reply.keys` corrects this wholesale on
        // the next reconnect.
        if n.actions.contains(where: { $0.isReply }) { replyableKeys.insert(n.key) }

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

    // MARK: - SMS

    /// The phone's conversation list, folded into the same inbox as everything else.
    ///
    /// Metadata only: a summary carries a snippet, not a transcript, so a thread the Mac
    /// has never opened shows its latest line in the sidebar and fills in the moment it is
    /// selected. Existing messages are left alone.
    mutating func applySmsThreads(_ summaries: [SmsThreadSummary]) {
        for summary in summaries {
            let key = ConversationKey.sms(threadId: summary.id)
            let stamp = Date(timeIntervalSince1970: Double(summary.when) / 1000)
            var thread = threads[key] ?? ConversationThread(
                id: key,
                pkg: ConversationKey.smsPseudoPackage,
                appLabel: "Messages",
                title: summary.displayName,
                lastActivity: stamp
            )
            thread.title = summary.displayName
            thread.smsAddress = summary.address
            thread.lastActivity = max(thread.lastActivity, stamp)
            // The phone counts unread from the provider, which is the truth: it knows
            // about texts read on the phone that never reached this Mac at all.
            thread.unreadCount = summary.unread
            if thread.messages.isEmpty { thread.snippet = summary.snippet }
            threads[key] = thread
        }
        evictThreadsIfNeeded()
    }

    /// A page of history for one thread, oldest first. Idempotent, so re-requesting a
    /// thread cannot double it.
    mutating func applySmsMessages(threadId: Int64, messages: [SmsMessage]) {
        for message in messages { ingest(message, alerting: false) }
    }

    /// One text.
    ///
    /// `alerting` is false for history being backfilled and true for a live arrival —
    /// the same distinction `resync` draws for notifications.
    @discardableResult
    mutating func ingest(_ m: SmsMessage, alerting: Bool = true,
                         at now: Date = Date()) -> IngestOutcome {
        let key = ConversationKey.sms(threadId: m.threadId)
        let sourceId = Self.smsSourceId(m.id)
        let stamp = m.date

        var thread = threads[key] ?? ConversationThread(
            id: key,
            pkg: ConversationKey.smsPseudoPackage,
            appLabel: "Messages",
            title: m.displayName ?? m.address,
            lastActivity: stamp
        )
        if thread.smsAddress == nil { thread.smsAddress = m.address }
        // An incoming text names the other party; an outgoing one names us, and must not
        // rewrite the conversation's title to our own number.
        if !m.outgoing, let name = m.displayName, !name.isEmpty { thread.title = name }

        defer { threads[key] = thread; evictThreadsIfNeeded() }

        // 1. Already have this provider row. Backfill overlapping a live arrival, or a
        //    thread opened twice, both land here.
        if thread.messages.contains(where: { $0.notificationKey == sourceId }) {
            return .duplicate
        }

        // 2. The provider echoing back something we just sent from the window. Without
        //    this every Mac-sent text appears twice — once optimistically, once as the
        //    row the phone wrote.
        if m.outgoing, let echoed = thread.messages.lastIndex(where: {
            $0.origin == .mac
                && $0.notificationKey == nil
                && $0.body == m.body
                && ($0.delivery == .sending || $0.delivery == .sent)
                && now.timeIntervalSince($0.when) < Self.echoWindow
        }) {
            thread.messages[echoed].notificationKey = sourceId
            thread.messages[echoed].delivery = .confirmed
            thread.messages[echoed].when = stamp
            thread.lastActivity = max(thread.lastActivity, stamp)
            sortMessages(&thread)
            return .reconciledOutgoing(thread.messages[echoed].id)
        }

        thread.messages.append(MirroredMessage(
            notificationKey: sourceId,
            fingerprint: nil,
            origin: m.outgoing ? .mac : .phone,
            senderName: m.outgoing ? nil : m.displayName,
            body: m.body,
            when: stamp,
            avatarHash: nil,
            // An outgoing row read back from the provider is as delivered as SMS gets.
            delivery: m.outgoing ? .confirmed : .incoming
        ))
        // Backfill arrives newest-page-first and can interleave with live arrivals.
        sortMessages(&thread)
        thread.lastActivity = max(thread.lastActivity, stamp)
        if alerting && !m.outgoing && !m.read { thread.unreadCount += 1 }
        trim(&thread)
        return .appended(key)
    }

    /// Starts an SMS conversation with a number that has no thread yet.
    ///
    /// The phone assigns the real thread id when the message lands; until then the Mac
    /// needs somewhere to put the bubble, and a negative id cannot collide with one.
    mutating func draftSmsThread(address: String, title: String) -> ConversationKey {
        let existing = threads.values.first {
            $0.id.isSms && $0.smsAddress.map { SmsAddressMatch.same($0, address) } == true
        }
        if let existing { return existing.id }
        let key = ConversationKey.sms(threadId: Self.nextDraftThreadId(in: threads))
        threads[key] = ConversationThread(
            id: key,
            pkg: ConversationKey.smsPseudoPackage,
            appLabel: "Messages",
            title: title,
            lastActivity: Date(),
            smsAddress: address
        )
        return key
    }

    /// Provider row ids share `notificationKey` with StatusBarNotification keys. They are
    /// namespaced rather than given a field of their own so the existing dedupe, the
    /// existing persistence and the existing tests all keep working unchanged.
    static func smsSourceId(_ id: Int64) -> String { "sms:\(id)" }

    private static func nextDraftThreadId(in threads: [ConversationKey: ConversationThread])
        -> Int64 {
        let lowest = threads.keys.compactMap { key -> Int64? in
            if case let .sms(id) = key, id < 0 { return id }
            return nil
        }.min() ?? 0
        return lowest - 1
    }

    /// Backfill and live arrivals interleave, so order is asserted rather than assumed.
    private func sortMessages(_ thread: inout ConversationThread) {
        thread.messages.sort {
            $0.when == $1.when
                ? (($0.notificationKey ?? "") < ($1.notificationKey ?? ""))
                : $0.when < $1.when
        }
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
    ///
    /// `allowingWithdrawn` is what makes replying to a real conversation possible at all.
    /// A phone advertising `notif.reply.offline.v1` keeps the reply action after the
    /// notification is cleared, and an Android reply `PendingIntent` outlives the
    /// notification that carried it — so "the phone is no longer showing this" is not the
    /// same as "you cannot reply to this". Against an older phone it still is, and the
    /// caller passes false.
    ///
    /// A withdrawn conversation additionally has to be one the phone still holds, because
    /// the intent lives in the phone's listener process and not in this history. Offering
    /// a composer on the strength of our own records alone promised replies that came back
    /// as "this phone no longer has a way to reply to that conversation".
    func replyTarget(for key: ConversationKey,
                     allowingWithdrawn: Bool = false) -> ReplyTarget? {
        guard let thread = threads[key],
              let notificationKey = thread.latestKey,
              let action = thread.latestActions.first(where: { $0.isReply })
        else { return nil }
        guard thread.isLiveOnPhone
                || (allowingWithdrawn && replyableKeys.contains(notificationKey))
        else { return nil }
        return ReplyTarget(key: notificationKey, actionId: action.id)
    }

    /// The phone's authoritative account of what it can still reply to.
    mutating func applyReplyableKeys(_ keys: Set<String>) {
        replyableKeys = keys
    }

    /// The phone's verdict on a reply we sent.
    ///
    /// Only failure is acted on. Success means the phone fired the intent, which is not
    /// yet proof the app accepted it — `.confirmed` stays reserved for the phone mirroring
    /// the message back, and a reply into a withdrawn conversation may never earn it.
    mutating func applyReplyResult(_ id: UUID, ok: Bool, error: String?) {
        guard !ok else { return }
        markDelivery(id, .failed(error ?? "The phone could not send this reply."))
    }

    mutating func clear() { threads.removeAll() }

    // MARK: - Restoring

    /// Corrects the two claims a saved transcript can no longer make.
    ///
    /// A reply left `.sending` was in flight when the app quit; nothing will ever
    /// reconcile it, so leaving it spinning would be a lie that never resolves. And
    /// `isLiveOnPhone` promises that `latestKey` still addresses a notification the phone
    /// is holding — replying through a key from a previous session either does nothing or
    /// fires the wrong positional action. The phone re-asserts both by resyncing whatever
    /// is still on its screen the moment it reconnects.
    mutating func normalizeAfterRestore() {
        // Nothing on disk can say what a phone process that has not connected yet holds.
        // The phone replaces this wholesale the moment it does.
        replyableKeys.removeAll()
        for (key, var thread) in threads {
            thread.isLiveOnPhone = false
            for index in thread.messages.indices where thread.messages[index].delivery == .sending {
                thread.messages[index].delivery = .failed("Not sent — Tennanova quit")
            }
            threads[key] = thread
        }
    }

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
