import Foundation

/// Main-thread home of everything the phone has mirrored.
///
/// A thin shell over `ConversationLog`, which holds all the behaviour and all the tests.
/// The shell exists for two reasons: SwiftUI needs an observable reference type, and the
/// hop from the server queue has to be ordered.
@MainActor
@Observable
final class NotificationStore {

    private(set) var log = ConversationLog()

    /// `AppState` is not main-isolated, so it cannot call a main-isolated initializer.
    /// Constructing this touches nothing but a value-type default, so it is safe anywhere;
    /// every *use* still goes through the main actor.
    nonisolated init() {}

    var threads: [ConversationThread] { log.threadsByRecency }
    var totalUnread: Int { log.totalUnread }

    // MARK: - Entry points from the server queue

    /// `DispatchQueue.main.async`, deliberately, and not `Task { @MainActor }`.
    ///
    /// Separate tasks are not guaranteed to run in the order they were created. For
    /// `battery` or `status` that is invisible — last writer wins and the value is right
    /// either way. For a transcript it is not: messages would reorder, and a `notif.removed`
    /// could overtake the `notif.posted` it refers to. A serial queue keeps the order the
    /// wire had.
    private nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    nonisolated func ingest(_ notification: NotifPosted) {
        onMain { self.log.ingest(notification) }
    }

    nonisolated func markRemovedOnPhone(key: String) {
        onMain { self.log.markRemovedOnPhone(key: key) }
    }

    nonisolated func clearAll() {
        onMain { self.log.clear() }
    }

    // MARK: - Main-thread mutations

    func appendOutgoing(_ text: String, to key: ConversationKey) -> UUID? {
        log.appendOutgoing(text, to: key)
    }

    func markDelivery(_ id: UUID, _ state: DeliveryState) {
        log.markDelivery(id, state)
    }

    func removeMessage(_ id: UUID) {
        log.removeMessage(id)
    }

    func markRead(_ key: ConversationKey) {
        log.markRead(key)
    }

    func replyTarget(for key: ConversationKey) -> ReplyTarget? {
        log.replyTarget(for: key)
    }
}
