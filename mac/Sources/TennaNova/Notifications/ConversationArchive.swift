import Foundation

/// Where the transcript lives between launches.
///
/// `ConversationLog` has been `Codable` since it was written and nothing ever wrote it,
/// so every quit threw the history away — which for a messages window is the difference
/// between an inbox and a live ticker.
///
/// Caches are the wrong place for it: this is user content, not something regenerable,
/// and the phone only ever replays notifications that are still on its screen.
struct ConversationArchive {

    let url: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tennanova.mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")
    }

    /// Nil for "nothing saved" and for "what was saved no longer decodes". A history that
    /// cannot be read is not worth refusing to launch over.
    func load() -> ConversationLog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            var log = try JSONDecoder().decode(ConversationLog.self, from: data)
            log.normalizeAfterRestore()
            return log
        } catch {
            Log.warn("could not read saved history: \(error.localizedDescription)")
            return nil
        }
    }

    func save(_ log: ConversationLog) {
        do {
            let data = try JSONEncoder().encode(log)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("could not save history: \(error.localizedDescription)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
