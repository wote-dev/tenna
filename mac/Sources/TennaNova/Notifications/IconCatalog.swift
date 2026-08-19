import Foundation
import AppKit
import Observation

/// The observable, main-thread face of `IconCache`.
///
/// `IconCache` is a file store on a background queue and is not observable, so a view
/// reading it directly would neither be allowed to touch it nor redraw when a PNG showed
/// up later — and icons routinely arrive after the message that referenced them, because
/// the bytes are requested only once the notification is already on screen.
///
/// Everything the window draws therefore goes through this in-memory mirror: decoded once,
/// published on the main actor, and observed like any other state.
@MainActor
@Observable
final class IconCatalog {

    private(set) var images: [String: NSImage] = [:]

    /// `nonisolated` so `warm` can decode off the main thread. `IconCache` is a
    /// content-addressed file store with no mutable state of its own — the same reason
    /// `NotificationPresenter` has always used one from its own queues.
    @ObservationIgnored private nonisolated let cache: IconCache

    /// `AppState` is not main-isolated, so it cannot call a main-isolated initializer.
    /// Same reasoning as `NotificationStore.init` — construction touches nothing shared.
    nonisolated init(cache: IconCache) {
        self.cache = cache
    }

    /// Nil-tolerant on purpose: almost every call site holds an optional hash.
    subscript(hash: String?) -> NSImage? {
        guard let hash else { return nil }
        return images[hash]
    }

    /// Publishes bytes that just came off the wire. No disk read — `IconCache` has been
    /// handed the same data, and decoding what is already in memory is free.
    nonisolated func received(_ data: Data, hash: String) {
        guard let image = NSImage(data: data) else { return }
        onMain { self.images[hash] = image }
    }

    /// Pulls hashes this Mac already has on disk into memory.
    ///
    /// Called for what a notification references, and once for a whole restored history at
    /// launch — hence the decode off the main thread. Hashes with no file are simply
    /// absent; they will be requested from the phone by the normal path.
    nonisolated func warm(_ hashes: [String?]) {
        let wanted = Set(hashes.compactMap { $0 })
        guard !wanted.isEmpty else { return }
        onMain {
            let missing = wanted.filter { self.images[$0] == nil }
            guard !missing.isEmpty else { return }
            DispatchQueue.global(qos: .utility).async {
                let loaded = missing.compactMap { hash in
                    self.cache.image(for: hash).map { (hash, $0) }
                }
                guard !loaded.isEmpty else { return }
                self.onMain {
                    for (hash, image) in loaded { self.images[hash] = image }
                }
            }
        }
    }

    /// A different phone's contact photos must not survive into the next pairing, for the
    /// same reason `NotificationStore.clearAll` exists.
    nonisolated func clearAll() {
        onMain { self.images.removeAll() }
    }

    private nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}
