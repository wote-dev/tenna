import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// How the engine reaches the phone. `AppState` conforms; nothing else does.
///
/// A protocol rather than a pile of closures because one of these is generic over the
/// message type, and the engine sends seven different ones.
protocol TransferTransport: AnyObject {
    @discardableResult
    func sendTransfer<T: Encodable>(_ message: T) -> Bool

    /// Header and body as one indivisible pair, with `then` firing once the body has been
    /// handed to the transport. That completion is the only backpressure signal
    /// `NWConnection` offers, and it is what paces the send.
    @discardableResult
    func sendTransferChunk(header: FileChunk, body: Data, then: @escaping () -> Void) -> Bool
}

/// Moves files, both ways.
///
/// Everything here runs on one serial queue of its own — not the server's. A 256 KiB read
/// or write on the connection queue would sit in front of the receive loop, and the
/// receive loop is what delivers the acks this pump is waiting for.
///
/// Whole-file hashing is the one thing that does not run on that queue: it is unbounded
/// work, and holding the state queue for the length of a 2 GiB digest would stall every
/// other transfer and every progress update behind it.
final class TransferEngine {

    weak var transport: TransferTransport?

    private let center: TransferCenter
    private let queue = DispatchQueue(label: "com.tennanova.transfers")
    private let hashQueue = DispatchQueue(label: "com.tennanova.transfers.hash",
                                          qos: .utility)
    private let staging: URL
    private let downloads: URL

    private var log = TransferLog()
    private var peerSupportsFiles = false
    private var connected = false

    /// The single outgoing file in flight, if any.
    private var outgoing: Outgoing?
    /// The single incoming file in flight, if any.
    private var incoming: Incoming?

    /// Coalesces progress publishing. A 2 GiB file over USB would otherwise redraw the
    /// pane thousands of times a second.
    private var lastPublish = Date.distantPast

    init(center: TransferCenter,
         staging: URL? = nil,
         downloads: URL? = nil) {
        self.center = center
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.staging = staging
            ?? caches.appendingPathComponent("com.tennanova.mac/transfers", isDirectory: true)
        self.downloads = downloads
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: self.staging,
                                                 withIntermediateDirectories: true)
        queue.async { [weak self] in self?.sweepStaleStaging() }
    }

    private struct Outgoing {
        let id: String
        let handle: FileHandle
        var window: ChunkWindow
        /// Set while a chunk is with the transport, so only one pump runs at a time.
        var pumping = false
    }

    private struct Incoming {
        let id: String
        let offer: FileOffer
        let handle: FileHandle
        /// Where the next chunk must start. A chunk that does not is a protocol error,
        /// not something to write at whatever offset it claims.
        var expected: Int
        var chunksSinceAck = 0
    }

    // MARK: - Session

    func sessionReady(peerSupportsFiles: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.peerSupportsFiles = peerSupportsFiles
            self.connected = true
            guard peerSupportsFiles else {
                for transfer in self.log.pausedSends() {
                    self.log.fail(transfer.id, "This phone's build cannot receive files")
                }
                self.publish()
                return
            }
            // Everything paused by the last disconnect goes back in the queue, oldest
            // first, and is re-offered under the same id so the phone can resume it.
            for transfer in self.log.pausedSends() {
                self.log.set(transfer.id, .queued)
            }
            self.publish()
            self.startNextSend()
        }
    }

    func sessionLost() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connected = false
            self.peerSupportsFiles = false
            try? self.outgoing?.handle.close()
            try? self.incoming?.handle.close()
            self.outgoing = nil
            self.incoming = nil
            // Not a failure. The partials are still on disk and the next connection
            // continues them; failing here would mean re-sending a whole file for a walk
            // out of Wi-Fi range.
            self.log.pauseEverything("Waiting for the phone")
            self.publish()
        }
    }

    // MARK: - Sending

    /// Queues files the user dropped on the window or picked from the panel.
    func enqueue(_ urls: [URL]) {
        queue.async { [weak self] in
            guard let self else { return }
            for url in urls {
                guard let transfer = self.describe(url) else {
                    self.center.publish(self.log.items,
                                        summary: "Couldn't read \(url.lastPathComponent)",
                                        arrived: 0)
                    continue
                }
                self.log.insert(transfer)
            }
            self.publish()
            self.startNextSend()
        }
    }

    func cancel(_ id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.releaseOutgoing(id)
            self.releaseIncoming(id, deletingPartial: true)
            self.log.cancel(id)
            self.transport?.sendTransfer(FileCancel(id: id, reason: "user"))
            self.publish()
            self.startNextSend()
        }
    }

    func clearFinished() {
        queue.async { [weak self] in
            guard let self else { return }
            self.log.clearFinished()
            self.center.clearFinished(self.log.items)
        }
    }

    private func describe(_ url: URL) -> Transfer? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else {
            return nil
        }
        guard size <= Proto.maxFileBytes else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return Transfer(id: Self.freshID(), direction: .toPhone,
                        name: url.lastPathComponent, bytes: size, mime: mime,
                        sha256: nil, startedAt: Self.nowMillis(), path: url.path)
    }

    private func startNextSend() {
        guard connected, peerSupportsFiles, outgoing == nil,
              let next = log.nextQueuedSend() else { return }

        log.set(next.id, .preparing)
        publish(force: true)

        // The digest covers the whole file and travels in the offer, which is what lets a
        // resumed transfer be verified rather than assumed. It costs one read pass, off
        // this queue so nothing else waits for it.
        let path = next.path
        hashQueue.async { [weak self] in
            guard let self, let path else { return }
            let digest = Self.digest(ofFileAt: URL(fileURLWithPath: path))
            self.queue.async {
                guard self.connected, self.log[next.id]?.state == .preparing else { return }
                guard let digest else {
                    self.log.fail(next.id, "The file could not be read")
                    self.publish(force: true)
                    self.startNextSend()
                    return
                }
                self.offer(next.id, digest: digest)
            }
        }
    }

    private func offer(_ id: String, digest: String) {
        guard var transfer = log[id] else { return }
        transfer.sha256 = digest
        log.set(id, .offered)
        log.setDigest(id, digest)

        let modified = transfer.path
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] }
            .flatMap { $0 as? Date }
            .map { Int64($0.timeIntervalSince1970 * 1000) }

        let message = FileOffer(id: id, name: transfer.name, bytes: transfer.bytes,
                                mime: transfer.mime, sha256: digest, modified: modified)
        guard transport?.sendTransfer(message) == true else {
            log.set(id, .paused("Waiting for the phone"))
            publish(force: true)
            return
        }
        publish(force: true)
    }

    func handle(begin: FileBegin) {
        queue.async { [weak self] in
            guard let self, let transfer = self.log[begin.id],
                  transfer.direction == .toPhone, transfer.state == .offered,
                  begin.hasValidMetadata(fileBytes: transfer.bytes),
                  let path = transfer.path else { return }

            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                self.log.fail(begin.id, "The file could not be read")
                self.transport?.sendTransfer(FileCancel(id: begin.id, reason: "gone"))
                self.publish(force: true)
                self.startNextSend()
                return
            }
            try? handle.seek(toOffset: UInt64(begin.offset))

            self.outgoing = Outgoing(id: begin.id, handle: handle,
                                     window: ChunkWindow(total: transfer.bytes,
                                                         from: begin.offset))
            self.log.set(begin.id, .active)
            self.log.progress(begin.id, transferred: begin.offset)
            self.publish(force: true)
            self.pump()
        }
    }

    func handle(ack: FileAck) {
        queue.async { [weak self] in
            guard let self, var outgoing = self.outgoing, outgoing.id == ack.id else { return }
            outgoing.window.acknowledge(ack.received)
            self.outgoing = outgoing
            self.log.progress(ack.id, transferred: Int(outgoing.window.acked))
            self.publish()
            self.pump()
        }
    }

    func handle(result: FileResult) {
        queue.async { [weak self] in
            guard let self, self.log[result.id]?.direction == .toPhone else { return }
            self.releaseOutgoing(result.id)
            if result.ok {
                self.log.complete(result.id, path: self.log[result.id]?.path)
                self.center.publish(self.log.items,
                                    summary: "Sent \(self.log[result.id]?.name ?? "a file")",
                                    arrived: 0)
            } else {
                self.log.fail(result.id, result.error ?? "The phone refused it")
            }
            self.publish(force: true)
            self.startNextSend()
        }
    }

    /// Hands one chunk to the transport and arranges for the next one to follow it.
    ///
    /// `pumping` is what keeps this to a single chain: an ack arriving while a chunk is
    /// still with the transport must not start a second one, or the two would interleave
    /// their reads of the same file handle.
    private func pump() {
        guard var outgoing, !outgoing.pumping else { return }

        guard let next = outgoing.window.nextChunk() else {
            self.outgoing = outgoing
            // Either the window is full and an ack will restart this, or the whole file is
            // on the wire and the only thing left is `file.done` and the verdict.
            if outgoing.window.everythingSent {
                transport?.sendTransfer(FileDone(id: outgoing.id))
            }
            return
        }

        try? outgoing.handle.seek(toOffset: UInt64(next.offset))
        guard let body = try? outgoing.handle.read(upToCount: next.bytes),
              body.count == next.bytes else {
            let id = outgoing.id
            releaseOutgoing(id)
            log.fail(id, "The file changed while it was being sent")
            transport?.sendTransfer(FileCancel(id: id, reason: "gone"))
            publish(force: true)
            startNextSend()
            return
        }

        outgoing.pumping = true
        self.outgoing = outgoing

        let header = FileChunk(id: outgoing.id, offset: next.offset, bytes: next.bytes)
        let sent = transport?.sendTransferChunk(header: header, body: body) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard var current = self.outgoing, current.id == header.id else { return }
                current.pumping = false
                self.outgoing = current
                self.pump()
            }
        }

        if sent != true {
            self.outgoing?.pumping = false
            log.set(header.id, .paused("Waiting for the phone"))
            publish(force: true)
        }
    }

    /// Releases the outgoing slot and its file handle. The log state is the caller's
    /// business — this only stops the pump.
    private func releaseOutgoing(_ id: String) {
        guard outgoing?.id == id else { return }
        try? outgoing?.handle.close()
        outgoing = nil
    }

    /// Releases the incoming slot. The partial is kept unless the transfer is over for
    /// good — a pause must leave it exactly where it is, or there is nothing to resume.
    private func releaseIncoming(_ id: String, deletingPartial: Bool) {
        guard incoming?.id == id else { return }
        try? incoming?.handle.close()
        incoming = nil
        if deletingPartial { try? FileManager.default.removeItem(at: partURL(for: id)) }
    }

    // MARK: - Receiving

    func handle(offer: FileOffer) {
        queue.async { [weak self] in
            guard let self else { return }
            let part = self.partURL(for: offer.id)
            let staged = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            switch self.log.verdict(for: offer, stagedBytes: staged,
                                    freeBytes: self.freeBytes(),
                                    peerSupportsFiles: self.peerSupportsFiles) {
            case .refuse(let reason):
                self.transport?.sendTransfer(FileCancel(id: offer.id, reason: reason))
                if self.log[offer.id] != nil {
                    self.log.fail(offer.id, Self.explain(reason))
                    self.publish(force: true)
                }

            case .begin(let offset):
                Log.info(offset > 0
                         ? "resuming \(offer.name) at \(offset) of \(offer.bytes)"
                         : "receiving \(offer.name), \(offer.bytes) bytes")
                if offset == 0 { try? FileManager.default.removeItem(at: part) }
                if !FileManager.default.fileExists(atPath: part.path) {
                    FileManager.default.createFile(atPath: part.path, contents: nil)
                }
                guard let handle = try? FileHandle(forWritingTo: part) else {
                    self.transport?.sendTransfer(FileCancel(id: offer.id, reason: "disk"))
                    return
                }
                try? handle.truncate(atOffset: UInt64(offset))
                try? handle.seekToEnd()

                var transfer = self.log[offer.id] ?? Transfer(
                    id: offer.id, direction: .toMac, name: offer.name, bytes: offer.bytes,
                    mime: offer.mime, sha256: offer.sha256, startedAt: Self.nowMillis()
                )
                transfer.state = .active
                transfer.transferred = offset
                self.log.insert(transfer)
                self.log.set(offer.id, .active)
                self.log.progress(offer.id, transferred: offset)

                self.incoming = Incoming(id: offer.id, offer: offer, handle: handle,
                                         expected: offset)
                self.transport?.sendTransfer(FileBegin(id: offer.id, offset: offset))
                self.publish(force: true)
            }
        }
    }

    /// The header's body frame. Anything that does not line up exactly with what was
    /// promised is a protocol error rather than something to write at face value.
    func handleChunk(header: FileChunk, body: Data) {
        queue.async { [weak self] in
            guard let self, var incoming = self.incoming, incoming.id == header.id,
                  header.offset == incoming.expected, body.count == header.bytes,
                  incoming.expected + body.count <= incoming.offer.bytes else {
                self?.abortIncoming(header.id, reason: "protocol",
                                    message: "The phone sent a chunk out of order")
                return
            }

            do {
                try incoming.handle.write(contentsOf: body)
            } catch {
                self.abortIncoming(header.id, reason: "disk",
                                   message: "The file could not be written")
                return
            }

            incoming.expected += body.count
            incoming.chunksSinceAck += 1
            let shouldAck = incoming.expected >= incoming.offer.bytes ||
                incoming.chunksSinceAck >= Proto.fileAckEveryChunks
            if shouldAck { incoming.chunksSinceAck = 0 }
            self.incoming = incoming

            if shouldAck {
                self.transport?.sendTransfer(FileAck(id: header.id,
                                                     received: incoming.expected))
            }
            self.log.progress(header.id, transferred: incoming.expected)
            self.publish()
        }
    }

    func handle(done: FileDone) {
        queue.async { [weak self] in
            guard let self, let incoming = self.incoming, incoming.id == done.id else { return }
            try? incoming.handle.close()
            self.incoming = nil

            guard incoming.expected == incoming.offer.bytes else {
                self.log.fail(done.id, "The phone stopped part-way through")
                self.transport?.sendTransfer(
                    FileResult(id: done.id, ok: false, error: "short file")
                )
                self.publish(force: true)
                return
            }

            self.log.set(done.id, .verifying)
            self.publish(force: true)

            let part = self.partURL(for: done.id)
            let offer = incoming.offer
            self.hashQueue.async {
                let digest = Self.digest(ofFileAt: part)
                self.queue.async { self.settle(offer: offer, part: part, digest: digest) }
            }
        }
    }

    private func settle(offer: FileOffer, part: URL, digest: String?) {
        guard digest == offer.sha256 else {
            log.fail(offer.id, "Checksum mismatch — the file was not saved")
            try? FileManager.default.removeItem(at: part)
            transport?.sendTransfer(
                FileResult(id: offer.id, ok: false, error: "checksum mismatch")
            )
            publish(force: true)
            return
        }

        let name = TransferLog.uniqueName(TransferLog.safeFilename(offer.name)) { candidate in
            FileManager.default.fileExists(
                atPath: self.downloads.appendingPathComponent(candidate).path
            )
        }
        let destination = downloads.appendingPathComponent(name)

        // The last line of defence on a name that came off the wire. Everything above has
        // already refused and rewritten it; this asks the filesystem itself whether the
        // result is still inside Downloads.
        guard destination.resolvingSymlinksInPath().deletingLastPathComponent().path
                == downloads.resolvingSymlinksInPath().path else {
            log.fail(offer.id, "The file's name could not be used")
            try? FileManager.default.removeItem(at: part)
            transport?.sendTransfer(FileResult(id: offer.id, ok: false, error: "bad name"))
            publish(force: true)
            return
        }

        do {
            try FileManager.default.moveItem(at: part, to: destination)
        } catch {
            log.fail(offer.id, "The file could not be saved to Downloads")
            transport?.sendTransfer(FileResult(id: offer.id, ok: false, error: "disk"))
            publish(force: true)
            return
        }

        log.complete(offer.id, path: destination.path)
        transport?.sendTransfer(FileResult(id: offer.id, ok: true, error: nil))
        center.publish(log.items, summary: "Saved \(name) to Downloads", arrived: 1)
    }

    func handle(cancel: FileCancel) {
        queue.async { [weak self] in
            guard let self else { return }
            self.releaseOutgoing(cancel.id)
            self.releaseIncoming(cancel.id, deletingPartial: true)
            if self.log[cancel.id] != nil {
                self.log.fail(cancel.id, Self.explain(cancel.reason))
            }
            self.publish(force: true)
            self.startNextSend()
        }
    }

    private func abortIncoming(_ id: String, reason: String, message: String) {
        releaseIncoming(id, deletingPartial: true)
        log.fail(id, message)
        transport?.sendTransfer(FileCancel(id: id, reason: reason))
        publish(force: true)
    }

    // MARK: - Plumbing

    private func partURL(for id: String) -> URL {
        // Ids come off the wire — hex only, so they cannot escape the directory. Same rule
        // and same reason as `IconCache`.
        let safe = id.filter { $0.isHexDigit }
        return staging.appendingPathComponent("\(safe).part")
    }

    private func freeBytes() -> Int {
        let values = try? downloads.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Partials from a session that never came back. Kept for a week, because a phone
    /// left at home for the weekend should still resume on Monday.
    private func sweepStaleStaging() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        for url in contents ?? [] {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func publish(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublish) > 0.1 else { return }
        lastPublish = now
        center.publish(log.items, summary: nil, arrived: 0)
    }

    private static func explain(_ reason: String) -> String {
        switch reason {
        case "too_large":   return "Too large — the limit is 2 GB"
        case "disk":        return "Not enough room to save it"
        case "unsupported": return "This phone's build cannot transfer files"
        case "busy":        return "Another transfer was already running"
        case "gone":        return "The file was no longer there"
        case "user":        return "Cancelled"
        default:            return "The transfer was refused"
        }
    }

    private static func freshID() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func nowMillis() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    /// Streamed rather than `SHA256.hash(data:)`: the whole point of this feature is files
    /// that do not fit comfortably in memory.
    static func digest(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let block = try? handle.read(upToCount: 1 << 20), !block.isEmpty else {
                break
            }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
