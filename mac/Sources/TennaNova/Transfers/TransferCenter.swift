import Foundation

/// Files, in a form the window can draw and observe.
///
/// The same shape as `CallCenter` and `NotificationStore`: an observable shell with no
/// behaviour of its own. Every decision lives in `TransferLog`, and `TransferEngine`
/// pushes finished snapshots here.
@MainActor
@Observable
final class TransferCenter {

    private(set) var items: [Transfer] = []

    /// The last thing worth saying in one line, for the Device pane.
    private(set) var summary: String?

    nonisolated init() {}

    var running: [Transfer] { items.filter { !$0.state.isFinished } }
    var finished: [Transfer] { items.filter { $0.state.isFinished } }

    var hasAnything: Bool { !items.isEmpty }

    /// Rows the user has not had in front of them, for the sidebar badge.
    private(set) var unseen = 0

    func markSeen() { unseen = 0 }

    /// Replaces the whole list. The engine holds the authoritative log on its own queue
    /// and hands over a snapshot; merging here would mean two copies of the same state
    /// disagreeing about which is newer.
    nonisolated func publish(_ snapshot: [Transfer], summary: String?, arrived: Int) {
        onMain {
            self.items = snapshot
            if let summary { self.summary = summary }
            self.unseen += arrived
        }
    }

    nonisolated func clearFinished(_ remaining: [Transfer]) {
        onMain { self.items = remaining }
    }

    /// `DispatchQueue.main.async` rather than `Task { @MainActor }`, for the reason
    /// `NotificationStore.onMain` spells out: separate tasks are not guaranteed to run in
    /// the order they were created, and a progress snapshot overtaking the completion
    /// snapshot behind it would leave a finished transfer drawn as if it were still going.
    private nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}
