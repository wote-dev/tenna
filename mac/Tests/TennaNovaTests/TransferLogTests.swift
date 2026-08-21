import Testing
@testable import TennaNova

/// No `import Foundation` here, deliberately — see the note at the top of `TestSupport`.
/// `TransferLog` is built out of `Int` and `String` for exactly this reason.
struct ChunkWindowTests {

    @Test func aWholeFileIsHandedOutInChunks() {
        var window = ChunkWindow(total: Proto.fileChunkBytes * 2 + 17)

        let first = window.nextChunk()
        #expect(first?.offset == 0)
        #expect(first?.bytes == Proto.fileChunkBytes)

        let second = window.nextChunk()
        #expect(second?.offset == Proto.fileChunkBytes)
        #expect(second?.bytes == Proto.fileChunkBytes)

        let last = window.nextChunk()
        #expect(last?.offset == Proto.fileChunkBytes * 2)
        #expect(last?.bytes == 17)

        #expect(window.nextChunk() == nil)
        #expect(window.everythingSent)
        #expect(!window.isComplete)
    }

    /// The whole point of the window: without it a 2 GiB file is handed to the socket in
    /// one go and held there in memory.
    @Test func theSenderStopsWhenTheReceiverStopsAcking() {
        var window = ChunkWindow(total: Proto.fileChunkBytes * 100)

        var handed = 0
        while window.nextChunk() != nil { handed += 1 }
        #expect(handed == Proto.fileWindowChunks)

        window.acknowledge(Proto.fileChunkBytes * 4)
        var more = 0
        while window.nextChunk() != nil { more += 1 }
        #expect(more == 4)
    }

    @Test func resumingStartsAtTheOffsetAndNotAtZero() {
        var window = ChunkWindow(total: Proto.fileChunkBytes * 3, from: Proto.fileChunkBytes)
        #expect(window.nextChunk()?.offset == Proto.fileChunkBytes)
        while window.nextChunk() != nil {}
        window.acknowledge(Proto.fileChunkBytes * 3)
        #expect(window.isComplete)
    }

    /// An ack is the only thing the peer can say that reopens the window, so it is the
    /// one number worth distrusting.
    @Test func anAckCannotRunBackwardsOrPastWhatWasSent() {
        var window = ChunkWindow(total: Proto.fileChunkBytes * 10)
        _ = window.nextChunk()
        _ = window.nextChunk()

        window.acknowledge(Proto.fileChunkBytes)
        window.acknowledge(0)
        #expect(window.acked == Proto.fileChunkBytes)

        window.acknowledge(Int.max)
        #expect(window.acked == Proto.fileChunkBytes * 2)
        #expect(!window.isComplete)
    }

    @Test func anEmptyFileIsAlreadyDone() {
        var window = ChunkWindow(total: 0)
        #expect(window.nextChunk() == nil)
        #expect(window.isComplete)
    }
}

struct TransferLogTests {

    @Test func oneTransferRunsPerDirectionAtATime() {
        var log = TransferLog()
        log.insert(makeTransfer(id: "aaaaaaaa", direction: .toPhone))
        log.insert(makeTransfer(id: "bbbbbbbb", direction: .toPhone))
        log.insert(makeTransfer(id: "cccccccc", direction: .toMac))

        #expect(log.nextQueuedSend()?.id == "aaaaaaaa")
        log.set("aaaaaaaa", .active)
        #expect(log.isBusy(.toPhone))
        #expect(!log.isBusy(.toMac))
        #expect(log.nextQueuedSend() == nil)

        log.complete("aaaaaaaa", path: "/tmp/a")
        #expect(log.nextQueuedSend()?.id == "bbbbbbbb")
    }

    @Test func progressOnlyEverMovesForwards() {
        var log = TransferLog()
        log.insert(makeTransfer(id: "aaaaaaaa", bytes: 1000))

        log.progress("aaaaaaaa", transferred: 400)
        log.progress("aaaaaaaa", transferred: 100)
        #expect(log["aaaaaaaa"]?.transferred == 400)

        log.progress("aaaaaaaa", transferred: 99_999)
        #expect(log["aaaaaaaa"]?.transferred == 1000)
        #expect(log["aaaaaaaa"]?.fraction == 1)
    }

    /// A dropped socket is the normal condition on a phone. Failing every transfer on it
    /// would mean re-sending whole files for a walk out of Wi-Fi range.
    @Test func aDroppedSocketPausesRatherThanFails() {
        var log = TransferLog()
        log.insert(makeTransfer(id: "aaaaaaaa", direction: .toPhone))
        log.insert(makeTransfer(id: "bbbbbbbb", direction: .toPhone))
        log.insert(makeTransfer(id: "cccccccc", direction: .toPhone))
        log.set("aaaaaaaa", .active)
        log.complete("cccccccc", path: "/tmp/c")

        log.pauseEverything("Phone not connected")

        #expect(log["aaaaaaaa"]?.state == .paused("Phone not connected"))
        // Something never started is still just queued, not paused.
        #expect(log["bbbbbbbb"]?.state == .queued)
        // And something already done is left alone.
        #expect(log["cccccccc"]?.state == .completed)
        #expect(log.pausedSends().map(\.id) == ["aaaaaaaa"])
    }

    @Test func finishedRowsAreBoundedAndActiveOnesAreNever() {
        var log = TransferLog()
        for index in 0..<(TransferLog.maxFinished + 20) {
            let id = hexID(index)
            log.insert(makeTransfer(id: id))
            log.complete(id, path: "/tmp/\(id)")
        }
        log.insert(makeTransfer(id: "ffffffff"))

        #expect(log.finished.count == TransferLog.maxFinished)
        #expect(log.active.count == 1)

        log.clearFinished()
        #expect(log.finished.isEmpty)
        #expect(log["ffffffff"] != nil)
    }
}

struct TransferOfferTests {

    @Test func afreshOfferStartsAtZero() {
        let log = TransferLog()
        let verdict = log.verdict(for: makeOffer(), stagedBytes: 0,
                                  freeBytes: 1_000_000, peerSupportsFiles: true)
        #expect(verdict == .begin(offset: 0))
    }

    @Test func aPeerWithoutTheCapabilityIsRefused() {
        let log = TransferLog()
        let verdict = log.verdict(for: makeOffer(), stagedBytes: 0,
                                  freeBytes: 1_000_000, peerSupportsFiles: false)
        #expect(verdict == .refuse(reason: "unsupported"))
    }

    @Test func aFullDiskIsSaidOutLoudRatherThanFailedAt99Percent() {
        let log = TransferLog()
        let verdict = log.verdict(for: makeOffer(bytes: 5000), stagedBytes: 0,
                                  freeBytes: 4999, peerSupportsFiles: true)
        #expect(verdict == .refuse(reason: "disk"))
    }

    @Test func anOversizedOfferIsRefusedBeforeAnyByteMoves() {
        let log = TransferLog()
        let verdict = log.verdict(for: makeOffer(bytes: Proto.maxFileBytes + 1),
                                  stagedBytes: 0, freeBytes: Int.max,
                                  peerSupportsFiles: true)
        #expect(verdict == .refuse(reason: "protocol"))
    }

    /// The staged partial is only continued when the log still agrees it is the same
    /// file. A digest or a length that has changed means the sender is offering something
    /// else under a reused id, and resuming would splice two files together.
    @Test func aPartialIsResumedOnlyWhenItIsProvablyTheSameFile() {
        var log = TransferLog()
        let offer = makeOffer(bytes: 5000)
        log.insert(makeTransfer(id: offer.id, direction: .toMac, bytes: 5000,
                                sha256: offer.sha256))
        log.set(offer.id, .paused("Phone not connected"))

        #expect(log.verdict(for: offer, stagedBytes: 2000, freeBytes: 999_999,
                            peerSupportsFiles: true) == .begin(offset: 2000))

        let differentDigest = makeOffer(bytes: 5000, sha256: String(repeating: "d", count: 64))
        #expect(log.verdict(for: differentDigest, stagedBytes: 2000, freeBytes: 999_999,
                            peerSupportsFiles: true) == .begin(offset: 0))
    }

    @Test func aPartialAsLongAsTheFileIsNotAResume() {
        var log = TransferLog()
        let offer = makeOffer(bytes: 5000)
        log.insert(makeTransfer(id: offer.id, direction: .toMac, bytes: 5000,
                                sha256: offer.sha256))
        log.set(offer.id, .paused("gone"))

        #expect(log.verdict(for: offer, stagedBytes: 5000, freeBytes: 999_999,
                            peerSupportsFiles: true) == .begin(offset: 0))
    }

    @Test func aSecondOfferForARunningTransferIsRejected() {
        var log = TransferLog()
        let offer = makeOffer()
        log.insert(makeTransfer(id: offer.id, direction: .toMac))
        log.set(offer.id, .active)

        #expect(log.verdict(for: offer, stagedBytes: 0, freeBytes: 999_999,
                            peerSupportsFiles: true) == .refuse(reason: "protocol"))
    }

    @Test func anOfferArrivingMidReceiveWaitsItsTurn() {
        var log = TransferLog()
        log.insert(makeTransfer(id: "aaaaaaaa", direction: .toMac))
        log.set("aaaaaaaa", .active)

        #expect(log.verdict(for: makeOffer(id: "bbbbbbbb"), stagedBytes: 0,
                            freeBytes: 999_999,
                            peerSupportsFiles: true) == .refuse(reason: "busy"))
    }
}

struct TransferNameTests {

    @Test func aNameThatCouldNameAPathIsFlattened() {
        #expect(TransferLog.safeFilename("../../.ssh/authorized_keys") == "ssh_authorized_keys")
        #expect(TransferLog.safeFilename("a/b/c.txt") == "a_b_c.txt")
        #expect(TransferLog.safeFilename(#"win\path.txt"#) == "win_path.txt")
        #expect(TransferLog.safeFilename("Macintosh HD:file") == "Macintosh HD_file")
    }

    /// Nothing arrives hidden. A file the user cannot see in Finder is a file they did not
    /// know they received.
    @Test func aLeadingDotIsRemovedSoNothingArrivesHidden() {
        #expect(TransferLog.safeFilename(".bashrc") == "bashrc")
        #expect(TransferLog.safeFilename("...notes.txt") == "notes.txt")
        #expect(TransferLog.safeFilename("_leading.txt") == "leading.txt")
        // A dot in the middle is just a filename.
        #expect(TransferLog.safeFilename("my..notes.txt") == "my..notes.txt")
    }

    @Test func anEmptyOrUnusableNameStillGetsAFile() {
        #expect(TransferLog.safeFilename("") == "file")
        #expect(TransferLog.safeFilename("   ") == "file")
        #expect(TransferLog.safeFilename("..") == "file")
        #expect(TransferLog.safeFilename("/") == "file")
    }

    /// The extension decides which app opens the file, so it is the last thing to lose.
    @Test func aLongNameIsCappedWithoutLosingItsExtension() {
        let long = String(repeating: "n", count: 400) + ".mp4"
        let safe = TransferLog.safeFilename(long)
        #expect(safe.hasSuffix(".mp4"))
        #expect(safe.count == 124)
    }

    @Test func aControlCharacterCannotSurviveIntoAFilename() {
        #expect(TransferLog.safeFilename("no\u{0}nul.txt") == "no_nul.txt")
        #expect(TransferLog.safeFilename("no\nnewline.txt") == "no_newline.txt")
    }

    /// A second copy of a file never quietly replaces the first.
    @Test func acollidingNameIsNumberedTheWayABrowserDoesIt() {
        let existing: Set<String> = ["report.pdf", "report (2).pdf", "notes"]
        let taken: (String) -> Bool = { existing.contains($0) }

        #expect(TransferLog.uniqueName("fresh.pdf", taken: taken) == "fresh.pdf")
        #expect(TransferLog.uniqueName("report.pdf", taken: taken) == "report (3).pdf")
        #expect(TransferLog.uniqueName("notes", taken: taken) == "notes (2)")
    }
}

/// The two apps have to phrase the same row the same way, or a file crossing one direction
/// reads differently from the same file crossing back. Mirrors `FilesCopyTest` in
/// `android/app/src/test/java/com/tennanova/ui/FilesCopyTest.kt`.
struct TransferFormatTests {

    @Test func sizesAreWrittenTheWayAPersonWouldSayThem() {
        #expect(TransferFormat.bytes(512) == "512 B")
        #expect(TransferFormat.bytes(10_500) == "10.5 KB")
        #expect(TransferFormat.bytes(5_100_000) == "5.1 MB")
        #expect(TransferFormat.bytes(1_500_000_000) == "1.5 GB")
    }

    @Test func anActiveRowNamesBothNumbers() {
        var transfer = makeTransfer(bytes: 13_800_000)
        transfer.transferred = 6_900_000
        transfer.state = .active
        #expect(TransferFormat.status(transfer) == "6.9 MB / 13.8 MB")
    }

    /// A paused transfer must not read like a failure. It is the normal outcome of a phone
    /// walking out of Wi-Fi range, and the partial file is still there waiting.
    @Test func aPausedRowSaysItWillContinue() {
        var transfer = makeTransfer()
        transfer.state = .paused("")
        #expect(TransferFormat.status(transfer).contains("continue"))

        transfer.state = .paused("Waiting for the phone")
        #expect(TransferFormat.status(transfer) == "Waiting for the phone")
    }

    @Test func aFailedRowPrefersTheReasonOverTheWordFailed() {
        var transfer = makeTransfer()
        transfer.state = .failed("Checksum mismatch — the file was not saved")
        #expect(TransferFormat.status(transfer) == "Checksum mismatch — the file was not saved")

        transfer.state = .failed("")
        #expect(TransferFormat.status(transfer) == "Failed")
    }

    @Test func aFinishedRowReadsDifferentlyEachWay() {
        var sent = makeTransfer(direction: .toPhone, bytes: 13_800_000)
        sent.state = .completed
        #expect(TransferFormat.status(sent) == "Sent · 13.8 MB")

        var received = makeTransfer(direction: .toMac, bytes: 13_800_000)
        received.state = .completed
        #expect(TransferFormat.status(received) == "Saved to Downloads · 13.8 MB")
    }
}
