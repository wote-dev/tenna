import Foundation

/// Which way a file is going. The word is from the Mac's point of view, because this is
/// the Mac's copy of the log.
enum TransferDirection: String, Codable, Equatable {
    case toPhone
    case toMac
}

/// Where a transfer has got to.
///
/// `paused` is deliberately separate from `failed`: a socket dropping mid-file is the
/// normal condition on a phone, not an error, and the partial file is kept so the next
/// connection continues rather than restarts. Only something that cannot be retried —
/// a checksum mismatch, a vanished source, a refusal — becomes `failed`.
enum TransferState: Equatable {
    case queued
    /// Hashing the source before offering it. Visible on a large file and nowhere else.
    case preparing
    /// The offer is on the wire; waiting for the peer to say where to start.
    case offered
    case active
    case paused(String)
    /// Every byte is in; hashing what landed.
    case verifying
    case completed
    case failed(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    /// Whether this transfer is occupying its direction's single active slot.
    var isRunning: Bool {
        switch self {
        case .preparing, .offered, .active, .verifying: return true
        default: return false
        }
    }
}

/// One file, in one direction, as this Mac knows it.
///
/// Timestamps are epoch millis and paths are strings rather than `Date` and `URL` on
/// purpose: it keeps this whole file free of anything a test would have to name, which
/// matters because a test file here cannot import `Foundation` alongside `Testing`.
struct Transfer: Identifiable, Equatable {
    /// The wire id. Hex, so it can also name the staging file without escaping its
    /// directory.
    var id: String
    var direction: TransferDirection
    /// The name as the peer sent it, or as the source file is called. Never used as a
    /// path — `TransferLog.safeFilename` decides what is actually written.
    var name: String
    var bytes: Int
    var mime: String
    /// Known from the start when receiving; known after `preparing` when sending.
    var sha256: String?
    /// Bytes the *receiver* has confirmed. On a send that is what `file.ack` reported, not
    /// what has been handed to the socket, so the percentage never runs ahead of reality.
    var transferred: Int = 0
    var state: TransferState = .queued
    var startedAt: Int
    /// Where the bytes are on this Mac: the source when sending, the finished file when
    /// receiving. Absent on a receive until it is verified and published.
    var path: String?

    var fraction: Double {
        guard bytes > 0 else { return 0 }
        return min(1, Double(transferred) / Double(bytes))
    }
}

/// Decides which chunk goes next, and stops the sender running arbitrarily far ahead of
/// the receiver.
///
/// The window exists because nothing else bounds a send. `NWConnection` will accept every
/// chunk of a 2 GiB file into its own queue and hold them all in memory, and the relay
/// path re-chunks each one into sixty-four smaller frames on the way out. `file.ack` is
/// what returns credit.
struct ChunkWindow: Equatable {
    let total: Int
    /// One past the last byte handed to the socket.
    private(set) var sent: Int
    /// One past the last byte the receiver has confirmed.
    private(set) var acked: Int

    init(total: Int, from offset: Int = 0) {
        self.total = max(0, total)
        let start = min(max(0, offset), self.total)
        self.sent = start
        self.acked = start
    }

    var isComplete: Bool { acked >= total }
    var everythingSent: Bool { sent >= total }
    var inFlight: Int { sent - acked }

    /// The next chunk, or `nil` when there is nothing to send right now — either the file
    /// is fully on the wire, or the window is full and the sender must wait for an ack.
    mutating func nextChunk() -> (offset: Int, bytes: Int)? {
        guard sent < total else { return nil }
        guard inFlight < Proto.fileWindowChunks * Proto.fileChunkBytes else { return nil }
        let offset = sent
        let count = min(Proto.fileChunkBytes, total - offset)
        sent += count
        return (offset, count)
    }

    /// An ack can only ever move forwards, and never past what was actually sent. A peer
    /// claiming otherwise is not trusted into a state where the window would reopen.
    mutating func acknowledge(_ received: Int) {
        acked = min(max(acked, received), sent)
    }
}

/// What a receiver should do about an offer.
enum OfferVerdict: Equatable {
    /// Take it, starting at this offset. Non-zero means a matching partial already exists.
    case begin(offset: Int)
    case refuse(reason: String)
}

/// Pure, testable reducer over every file this Mac has sent or received this session.
///
/// Split from the observable shell for the same reason `CallLog` and `ConversationLog`
/// are: all the behaviour worth testing lives here and none of it needs a main actor, a
/// socket or a window.
struct TransferLog: Equatable {

    /// Finished rows are a convenience, not a record. The files themselves are the record.
    static let maxFinished = 50

    private(set) var items: [Transfer] = []

    // MARK: - Reading

    subscript(id: String) -> Transfer? {
        items.first { $0.id == id }
    }

    var active: [Transfer] { items.filter { !$0.state.isFinished } }
    var finished: [Transfer] { items.filter { $0.state.isFinished } }

    /// Whether a direction's single slot is taken. One transfer at a time each way, so a
    /// Mac push and a phone share never stall each other but neither ever interleaves.
    func isBusy(_ direction: TransferDirection) -> Bool {
        items.contains { $0.direction == direction && $0.state.isRunning }
    }

    /// The next thing to start sending, if the outgoing slot is free.
    ///
    /// `last`, not `first`: `items` is newest-first because that is the order the pane
    /// draws, but a queue that ran in that order would send the most recently dropped
    /// file before the one dropped a minute ago.
    func nextQueuedSend() -> Transfer? {
        guard !isBusy(.toPhone) else { return nil }
        return items.last { $0.direction == .toPhone && $0.state == .queued }
    }

    /// Everything a reconnect should pick back up, oldest first.
    func pausedSends() -> [Transfer] {
        items.reversed().filter { $0.direction == .toPhone && isPaused($0) }
    }

    private func isPaused(_ transfer: Transfer) -> Bool {
        if case .paused = transfer.state { return true }
        return false
    }

    // MARK: - Writing

    mutating func insert(_ transfer: Transfer) {
        guard self[transfer.id] == nil else { return }
        items.insert(transfer, at: 0)
        trim()
    }

    mutating func set(_ id: String, _ state: TransferState) {
        update(id) { $0.state = state }
    }

    /// The digest, once the sender has hashed the source. Receives know it from the offer.
    mutating func setDigest(_ id: String, _ sha256: String) {
        update(id) { $0.sha256 = sha256 }
    }

    mutating func progress(_ id: String, transferred: Int) {
        update(id) { transfer in
            // Only ever forwards. An out-of-order ack must not make a bar jump backwards.
            transfer.transferred = min(transfer.bytes, max(transfer.transferred, transferred))
        }
    }

    mutating func complete(_ id: String, path: String?) {
        update(id) { transfer in
            transfer.transferred = transfer.bytes
            transfer.path = path ?? transfer.path
            transfer.state = .completed
        }
    }

    mutating func fail(_ id: String, _ reason: String) {
        update(id) { $0.state = .failed(reason) }
    }

    mutating func cancel(_ id: String) {
        update(id) { $0.state = .cancelled }
    }

    /// The socket went away. Nothing here failed — the partials are still on disk and the
    /// next connection continues them.
    mutating func pauseEverything(_ reason: String) {
        for index in items.indices where !items[index].state.isFinished {
            if items[index].state == .queued { continue }
            items[index].state = .paused(reason)
        }
    }

    mutating func clearFinished() {
        items.removeAll { $0.state.isFinished }
    }

    private mutating func update(_ id: String, _ body: (inout Transfer) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    private mutating func trim() {
        var seen = 0
        items.removeAll { transfer in
            guard transfer.state.isFinished else { return false }
            seen += 1
            return seen > Self.maxFinished
        }
    }

    // MARK: - Receiving decisions

    /// What to answer a `file.offer` with.
    ///
    /// Everything this needs to know that lives outside the log is passed in, so the whole
    /// decision stays testable: how much of this exact file is already staged, and how much
    /// room the disk has.
    func verdict(for offer: FileOffer,
                 stagedBytes: Int,
                 freeBytes: Int,
                 peerSupportsFiles: Bool) -> OfferVerdict {
        guard peerSupportsFiles else { return .refuse(reason: "unsupported") }
        guard offer.hasValidMetadata else { return .refuse(reason: "protocol") }

        // A re-offer of something already running is the same transfer arriving twice.
        if let existing = self[offer.id], existing.state.isRunning {
            return .refuse(reason: "protocol")
        }
        if isBusy(.toMac), self[offer.id] == nil {
            return .refuse(reason: "busy")
        }

        // Only resume a partial that is unambiguously this file: same id, and the log
        // still remembers the same length and digest. Anything else starts over.
        var offset = 0
        if stagedBytes > 0, stagedBytes < offer.bytes,
           let known = self[offer.id],
           known.bytes == offer.bytes, known.sha256 == offer.sha256 {
            offset = stagedBytes
        }

        guard freeBytes >= offer.bytes - offset else { return .refuse(reason: "disk") }
        return .begin(offset: offset)
    }

    // MARK: - Names

    /// Turns a name off the wire into something safe to write.
    ///
    /// `Proto.isValidTransferName` has already refused the outright hostile cases and the
    /// offer never got this far if it failed; this is the second layer, and it assumes
    /// nothing about the first. Separators, traversal and control characters go, a leading
    /// dot goes so nothing arrives hidden, and the length is capped well inside every
    /// filesystem's limit while keeping the extension.
    static func safeFilename(_ raw: String) -> String {
        var cleaned = String(raw.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == "\\" || scalar == ":" { return "_" }
            if scalar.properties.generalCategory == .control { return "_" }
            return Character(scalar)
        })

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading dots and underscores both go: a dot would arrive hidden, and an
        // underscore at the front is only ever the corpse of a separator replaced above.
        while let first = cleaned.first, first == "." || first == "_" { cleaned.removeFirst() }
        if cleaned.isEmpty { return "file" }

        // Cap the stem, not the whole name: an extension is what decides which app opens
        // the file, so it is the last thing worth losing.
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        let cappedStem = String(stem.prefix(120))
        let cappedExt = String(ext.prefix(20))
        if cappedExt.isEmpty { return cappedStem.isEmpty ? "file" : cappedStem }
        return "\(cappedStem.isEmpty ? "file" : cappedStem).\(cappedExt)"
    }

    /// `report.pdf`, then `report (2).pdf`, then `report (3).pdf` — the same thing a
    /// browser does, so a second copy of a file never quietly replaces the first.
    static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var counter = 2
        while counter < 1000 {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !taken(candidate) { return candidate }
            counter += 1
        }
        return name
    }
}
