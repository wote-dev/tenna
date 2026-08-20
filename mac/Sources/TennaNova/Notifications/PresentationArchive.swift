import Foundation

/// Where the record of "macOS has already alerted about this" lives between launches.
///
/// `NotificationReplayGuard` was memory-only, and `NotificationPresenter` reseeded it at
/// startup from `getDeliveredNotifications` — that is, from the cards still sitting in
/// Notification Center. Anything the user had read and cleared was therefore *unknown* to a
/// freshly launched Mac app, so the phone's reconnect replay alerted all of it again, with
/// sound. Reading your notifications is the single most common reason for them to leave
/// Notification Center, which made the guard blindest exactly where it mattered most.
///
/// Like `ConversationArchive`, and for the same reason, this sits in Application Support
/// rather than Caches: regenerating it is not possible — the phone only ever replays what is
/// still on *its* screen, and macOS cannot be asked what it showed you yesterday.
struct PresentationArchive {

    let url: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tennanova.mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("presented.json")
    }

    /// Nil for "nothing saved" and for "what was saved no longer decodes". The cost of
    /// failing to read this is one round of re-alerting, which is not worth refusing to
    /// launch over.
    func load() -> NotificationReplayGuard? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(NotificationReplayGuard.self, from: data)
        } catch {
            Log.warn("could not read the presentation history: \(error.localizedDescription)")
            return nil
        }
    }

    func save(_ guardState: NotificationReplayGuard) {
        do {
            let data = try JSONEncoder().encode(guardState)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("could not save the presentation history: \(error.localizedDescription)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
