import Foundation

/// One call, as this Mac knows it.
///
/// Deliberately *not* a `ConversationThread`. A call is not a conversation: it has no
/// transcript, it cannot be replied to, and its whole life is a few seconds of "this is
/// happening right now". Folding it into the inbox would put a row in the sidebar that can
/// never be opened for anything useful, and would push the actual messages down.
struct MirroredCall: Identifiable, Equatable {
    /// The phone's `StatusBarNotification.key`. Opaque, and the identity everything is
    /// keyed on — including the dialer's extra buttons, which fire through `notif.action`.
    var id: String
    var state: CallLifecycle
    var direction: CallDirection
    var pkg: String
    var appLabel: String
    var displayName: String?
    var number: String?
    var isVideo: Bool = false
    var when: Date
    var canAnswer: Bool = false
    var canDecline: Bool = false
    var canHangUp: Bool = false
    var iconHash: String?
    var avatarHash: String?
    var actions: [NotifAction] = []
    /// Whether it ever reached `active` — the only thing separating a call that was taken
    /// from one that was missed, since Android reports neither.
    var wasAnswered: Bool = false
    /// When *this Mac* saw the call go from ringing to in progress. The elapsed time on
    /// the card is measured from here and not from `when`, which is only the moment the
    /// notification was posted — a call answered before Tennanova ever saw it would
    /// otherwise be given a duration this Mac has no way of knowing.
    var answeredAt: Date?
    var endedAt: Date?
    /// What went wrong the last time this Mac tried to do something about this call.
    /// Cleared by the next state the phone sends, because that state is newer news.
    var failure: String?

    /// Whoever is calling, in the order a person would want it. Never the app's name on
    /// its own unless nothing else exists — the card names the app separately.
    var title: String {
        if let name = displayName, !name.isEmpty { return name }
        if let number, !number.isEmpty { return number }
        return appLabel
    }

    /// The line under the title: the number when the name is a contact, the app otherwise.
    /// Repeating the title back is worse than saying nothing.
    var subtitle: String {
        if let number, !number.isEmpty, number != title { return number }
        return appLabel
    }

    /// Rang, was never picked up. Worth its own word in the recents list, because it is
    /// the one entry there that means the user still owes someone a call back.
    var isMissed: Bool {
        state == .ended && direction == .incoming && !wasAnswered
    }

    init(_ m: CallStateMessage, at now: Date) {
        id = m.id
        state = m.lifecycle
        direction = m.way
        pkg = m.pkg
        appLabel = m.appLabel
        displayName = m.displayName
        number = m.number
        isVideo = m.video ?? false
        when = m.when.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? now
        iconHash = m.iconHash
        avatarHash = m.avatarHash
        wasAnswered = m.lifecycle == .active
        apply(m, at: now)
    }

    /// Folds a later report of the same call in. Identity, timing and direction are fixed
    /// at the first sighting; everything else is whatever the phone last said.
    mutating func apply(_ m: CallStateMessage, at now: Date) {
        state = m.lifecycle
        appLabel = m.appLabel
        if let name = m.displayName, !name.isEmpty { displayName = name }
        if let number = m.number, !number.isEmpty { self.number = number }
        if let icon = m.iconHash { iconHash = icon }
        if let avatar = m.avatarHash { avatarHash = avatar }
        canAnswer = m.canAnswer ?? false
        canDecline = m.canDecline ?? false
        canHangUp = m.canHangUp ?? false
        actions = m.actions ?? []
        isVideo = m.video ?? isVideo
        // Once answered, always answered: the phone stops saying so the moment the call
        // ends, and that is exactly when this is needed to tell taken from missed.
        if m.lifecycle == .active {
            wasAnswered = true
            if answeredAt == nil { answeredAt = now }
        }
        // A fresh report supersedes whatever this Mac last failed to do.
        failure = nil
    }
}

/// What one `call.state` changed, so the caller knows whether to ring.
enum CallChange: Equatable {
    /// Not seen before. The only case that alerts — including after a reconnect, because
    /// a phone that is ringing *now* is news to a Mac that has just come up.
    case started(MirroredCall)
    case updated(MirroredCall)
    case ended(MirroredCall)
    /// An end for a call this Mac never saw start. Nothing to withdraw, nothing to log.
    case ignored
}

/// Pure, testable reducer over every call the phone has reported.
///
/// Split from the observable shell for the same reason `ConversationLog` is: all the
/// behaviour worth testing lives here and none of it needs a main actor or a window.
struct CallLog: Equatable {

    /// Recents are a convenience, not a record — the phone's own call log is the record,
    /// and reading it would need `READ_CALL_LOG`, which nothing here is worth.
    static let maxRecents = 50

    /// How long after a call ends another one from the same caller is treated as the same
    /// call carrying on.
    ///
    /// Some dialers do not update their call notification when the call is answered: they
    /// cancel it and post a fresh one under a new key. Taken at face value that is a call
    /// that ended while still ringing — a missed call — immediately followed by an
    /// unrelated one already in progress, which is exactly wrong on both counts. Five
    /// seconds is far longer than a notification swap and far shorter than anyone
    /// redialling the person who just hung up.
    static let reviveWindow: TimeInterval = 5

    private(set) var live: [MirroredCall] = []
    private(set) var recents: [MirroredCall] = []

    /// The one call a banner should show. A ringing call outranks one already in progress:
    /// the second is a status, the first needs an answer.
    var current: MirroredCall? {
        live.first { $0.state == .ringing } ?? live.first
    }

    var isRinging: Bool { live.contains { $0.state == .ringing } }

    var missedCount: Int { recents.filter(\.isMissed).count }

    @discardableResult
    mutating func apply(_ m: CallStateMessage, at now: Date = Date()) -> CallChange {
        let index = live.firstIndex { $0.id == m.id }

        guard m.lifecycle != .ended else {
            guard let index else { return .ignored }
            var call = live.remove(at: index)
            call.apply(m, at: now)
            call.state = .ended
            call.endedAt = now
            call.canAnswer = false
            call.canDecline = false
            call.canHangUp = false
            recents.insert(call, at: 0)
            if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
            return .ended(call)
        }

        if let index {
            live[index].apply(m, at: now)
            return .updated(live[index])
        }

        // The same call under a new key — see `reviveWindow`. Reviving rather than
        // starting is what keeps it from ringing a second time and from leaving a missed
        // call behind for a call that was answered.
        if let revived = revive(m, at: now) {
            live.insert(revived, at: 0)
            return .updated(revived)
        }

        let call = MirroredCall(m, at: now)
        live.insert(call, at: 0)
        return .started(call)
    }

    private mutating func revive(_ m: CallStateMessage, at now: Date) -> MirroredCall? {
        guard let last = recents.first,
              last.pkg == m.pkg,
              last.endedAt.map({ now.timeIntervalSince($0) < Self.reviveWindow }) == true
        else { return nil }
        var candidate = last
        candidate.apply(m, at: now)
        // Same caller, or the newer report simply says less about who it is. A different
        // name is a different call and must not be folded in.
        guard candidate.title == last.title else { return nil }
        recents.removeFirst()
        candidate.id = m.id
        candidate.endedAt = nil
        return candidate
    }

    /// This Mac could not do the thing it was asked to. Kept on the call rather than in a
    /// banner somewhere: the sentence only means anything beside the call it is about.
    mutating func noteFailure(_ id: String, _ message: String) {
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        live[index].failure = message
    }

    mutating func clearRecents() { recents.removeAll() }

    mutating func clear() {
        live.removeAll()
        recents.removeAll()
    }

    /// The phone is gone, so nothing can still be live: every button on a live card
    /// fires through the socket, and a card left ringing after it dropped is a card of
    /// buttons that go nowhere.
    ///
    /// Deliberately *not* filed in recents. This Mac has no idea how those calls ended —
    /// the connection died, not the call — and recording a ring it lost sight of as a
    /// missed call would invent a fact out of a network hiccup.
    mutating func dropLiveCalls() {
        live.removeAll()
    }
}

/// Main-thread home of the call log, in the shape `NotificationStore` established: a thin
/// observable shell over a pure reducer, entered from the server queue through one serial
/// hop so events cannot reorder.
@MainActor
@Observable
final class CallCenter {

    private(set) var log = CallLog()

    /// Constructing this touches nothing but a value-type default, so it is safe from
    /// `AppState`'s non-isolated initializer. Every *use* still goes through the main actor.
    nonisolated init() {}

    var live: [MirroredCall] { log.live }
    var recents: [MirroredCall] { log.recents }
    var current: MirroredCall? { log.current }
    var isRinging: Bool { log.isRinging }
    var missedCount: Int { log.missedCount }

    /// `DispatchQueue.main.async` rather than `Task { @MainActor }`, for the reason spelled
    /// out on `NotificationStore.onMain`: separate tasks are not ordered, and an `ended`
    /// overtaking the `ringing` it refers to would leave a card ringing forever.
    nonisolated func apply(_ m: CallStateMessage,
                           then: @escaping @MainActor (CallChange) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { then(self.log.apply(m)) }
        }
    }

    func noteFailure(_ id: String, _ message: String) {
        log.noteFailure(id, message)
    }

    func clearRecents() {
        log.clearRecents()
    }

    nonisolated func dropLiveCalls() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.log.dropLiveCalls() } }
    }

    nonisolated func clearAll() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.log.clear() } }
    }
}
