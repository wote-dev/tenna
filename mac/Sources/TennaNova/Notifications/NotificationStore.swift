import Foundation

/// Main-thread home of everything the phone has mirrored.
///
/// A thin shell over `ConversationLog`, which holds all the behaviour and all the tests.
/// The shell exists for three reasons: SwiftUI needs an observable reference type, the hop
/// from the server queue has to be ordered, and the transcript has to reach the disk.
@MainActor
@Observable
final class NotificationStore {

    /// Long enough that a burst of messages costs one write, short enough that a crash
    /// loses a sentence rather than a conversation.
    static let saveDebounce: TimeInterval = 2

    private(set) var log = ConversationLog()

    @ObservationIgnored private let archive: ConversationArchive
    @ObservationIgnored private var pendingSave: DispatchWorkItem?

    /// `AppState` is not main-isolated, so it cannot call a main-isolated initializer.
    /// Constructing this touches nothing but a value-type default, so it is safe anywhere;
    /// every *use* still goes through the main actor.
    nonisolated init(archive: ConversationArchive = ConversationArchive()) {
        self.archive = archive
    }

    var threads: [ConversationThread] { log.threadsByRecency }
    var totalUnread: Int { log.totalUnread }

    // MARK: - Persistence

    /// Reads the saved transcript back. Separate from `init` because it belongs to app
    /// startup, and because a test wants a store it can populate itself.
    ///
    /// Returns every asset hash the restored history references, so the caller can warm
    /// them without this file needing to know what an icon is.
    @discardableResult
    func restore() -> [String?] {
        guard let restored = archive.load() else { return [] }
        log = restored
        Log.info("restored \(log.threads.count) conversations")
        return log.threads.values.flatMap { thread in
            [thread.iconHash] + thread.messages.map { $0.avatarHash }
        }
    }

    /// Writes now rather than in two seconds. For app termination, where there is no
    /// "later".
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        archive.save(log)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSave = nil
                self.archive.save(self.log)
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// Every mutation goes through one of these two, so none can be added later that
    /// forgets to save.
    private func mutate(_ body: (inout ConversationLog) -> Void) {
        body(&log)
        scheduleSave()
    }

    private func mutating<T>(_ body: (inout ConversationLog) -> T) -> T {
        let result = body(&log)
        scheduleSave()
        return result
    }

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
        onMain { self.mutate { $0.ingest(notification) } }
    }

    nonisolated func markRemovedOnPhone(key: String) {
        onMain { self.mutate { $0.markRemovedOnPhone(key: key) } }
    }

    nonisolated func clearAll() {
        onMain {
            self.mutate { $0.clear() }
            // Unpairing is the one case where the file must go rather than be rewritten
            // empty at the next debounce — the next phone must not inherit any of it.
            self.flush()
        }
    }

    // MARK: - Main-thread mutations

    func appendOutgoing(_ text: String, to key: ConversationKey) -> UUID? {
        mutating { $0.appendOutgoing(text, to: key) }
    }

    func markDelivery(_ id: UUID, _ state: DeliveryState) {
        mutate { $0.markDelivery(id, state) }
    }

    func removeMessage(_ id: UUID) {
        mutate { $0.removeMessage(id) }
    }

    func markRead(_ key: ConversationKey) {
        mutate { $0.markRead(key) }
    }

    func replyTarget(for key: ConversationKey,
                     allowingWithdrawn: Bool = false) -> ReplyTarget? {
        log.replyTarget(for: key, allowingWithdrawn: allowingWithdrawn)
    }

    nonisolated func applyReplyResult(_ id: UUID, ok: Bool, error: String?) {
        onMain { self.mutate { $0.applyReplyResult(id, ok: ok, error: error) } }
    }
}
