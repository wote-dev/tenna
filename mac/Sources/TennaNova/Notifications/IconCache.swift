import Foundation

/// Content-addressed store of the PNGs the phone sends — app icons and contact photos
/// alike. Each one crosses the wire once, ever.
final class IconCache {

    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("com.tennanova.mac/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func url(for hash: String) -> URL {
        // Hashes come off the wire — keep them to hex so they can't escape the directory.
        let safe = hash.filter { $0.isHexDigit }
        return dir.appendingPathComponent("\(safe).png")
    }

    func has(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    func store(_ data: Data, hash: String) {
        try? data.write(to: url(for: hash), options: .atomic)
    }

    /// UNNotificationAttachment *moves* the file it is handed into its own data store,
    /// so hand it a throwaway copy and keep the cached original.
    func temporaryCopy(of hash: String) -> URL? {
        let source = url(for: hash)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tenna-icon-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: source, to: tmp)
            return tmp
        } catch {
            return nil
        }
    }
}
