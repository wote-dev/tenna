import Foundation
import CoreGraphics
@testable import TennaNova

// Deliberately not importing `Testing` here.
//
// A file that imports both `Testing` and `Foundation` pulls in the _Testing_Foundation
// cross-import overlay, and the standalone Command Line Tools ship that framework's binary
// without its .swiftmodule — so it fails to compile. Keeping every Foundation type name in
// this file lets the test files name only inferred values, which needs no import.

/// A fixed origin so tests can express "later" without touching the wall clock.
enum TestClock {
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    static func after(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
}

func makeNotification(
    key: String = "k1",
    pkg: String = "com.whatsapp",
    appLabel: String = "WhatsApp",
    iconHash: String? = nil,
    avatarHash: String? = nil,
    title: String? = "Sam",
    body: String? = "are you close?",
    whenMs: Int64? = nil,
    category: String? = "msg",
    senderName: String? = nil,
    conversationTitle: String? = nil,
    resync: Bool? = nil,
    actions: [NotifAction] = [NotifAction(id: 0, label: "Reply", isReply: true)]
) -> NotifPosted {
    NotifPosted(
        key: key,
        pkg: pkg,
        appLabel: appLabel,
        iconHash: iconHash,
        avatarHash: avatarHash,
        title: title,
        body: body,
        when: whenMs,
        category: category,
        senderName: senderName,
        conversationTitle: conversationTitle,
        resync: resync,
        actions: actions
    )
}

/// Encodes and decodes a replay guard, the way `PresentationArchive` does across a launch.
///
/// Here rather than in the test file because `JSONEncoder` is a Foundation type — see the
/// note at the top of this file for why naming one next to `import Testing` does not build.
func roundTripped(_ guardState: NotificationReplayGuard) -> NotificationReplayGuard? {
    guard let data = try? JSONEncoder().encode(guardState) else { return nil }
    return try? JSONDecoder().decode(NotificationReplayGuard.self, from: data)
}

func validMirrorPacketBytes() -> Data {
    var bytes = Data("TNMV".utf8)
    bytes.append(contentsOf: [1, 1, 0x12, 0x34, 0x10, 0x20, 0x30, 0x40,
                              1, 2, 3, 4, 5, 6, 7, 8])
    bytes.append(contentsOf: [0, 0, 0, 1, 0x65])
    return bytes
}

func malformedMirrorPacket(flags: UInt8 = 0, corruptMagic: Bool = false) -> Data {
    var packet = Data(repeating: 0, count: 21)
    packet.replaceSubrange(0..<4, with: Data("TNMV".utf8))
    packet[4] = 1
    packet[5] = flags
    if corruptMagic { packet[0] = 0 }
    return packet
}

func mirrorAccessUnitBytes(_ packet: MirrorVideoPacket) -> [UInt8] {
    Array(packet.accessUnit)
}

func annexBFixture() -> Data { Data([0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2]) }
func annexBUnitBytes() -> [[UInt8]] { H264AnnexB.units(annexBFixture()).map(Array.init) }
func annexBAVCCBytes() -> [UInt8]? { H264AnnexB.avcc(annexBFixture()).map(Array.init) }

func portraitLetterboxFrame() -> [Double] {
    let rect = MirrorViewport.videoRect(
        container: CGSize(width: 1000, height: 500),
        video: CGSize(width: 500, height: 1000)
    )
    return [rect.origin.x, rect.origin.y, rect.width, rect.height].map(Double.init)
}

func portraitLetterboxPoint(x: Double, y: Double) -> [Double]? {
    let rect = MirrorViewport.videoRect(
        container: CGSize(width: 1000, height: 500),
        video: CGSize(width: 500, height: 1000)
    )
    return MirrorViewport.normalized(CGPoint(x: x, y: y), in: rect)
        .map { [Double($0.x), Double($0.y)] }
}

func mirrorConfigRoundTrip() throws -> MirrorConfig {
    let config = MirrorConfig(sessionId: "session", generation: 2, codec: "h264",
                              width: 1080, height: 1920, rotation: 0,
                              sps: Data([0x67, 1]), pps: Data([0x68, 2]))
    return try Wire.decode(MirrorConfig.self, from: Wire.encode(config))
}

func mirrorConfigParameterBytes(_ config: MirrorConfig) -> [[UInt8]] {
    [Array(config.sps), Array(config.pps)]
}

/// Hands a test its own presentation archive in a throwaway directory, and cleans up.
func withTemporaryPresentationArchive(_ body: (PresentationArchive) -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tenna-presented-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    body(PresentationArchive(directory: dir))
}

/// Hands a test its own archive in a throwaway directory and cleans up after it.
///
/// The directory plumbing lives here rather than in the test file for the same reason
/// everything else in this file does: naming a Foundation type in a file that imports
/// `Testing` pulls in a cross-import overlay the Command Line Tools ship broken.
func withTemporaryArchive(_ body: (ConversationArchive) -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tenna-archive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    body(ConversationArchive(directory: dir))
}

func makeSms(
    id: Int64 = 1,
    threadId: Int64 = 42,
    address: String = "+61491570006",
    displayName: String? = "Sam",
    body: String = "are you close?",
    whenMs: Int64 = 1_700_000_000_000,
    outgoing: Bool = false,
    read: Bool = false
) -> SmsMessage {
    SmsMessage(
        id: id, threadId: threadId, address: address, displayName: displayName,
        body: body, when: whenMs, outgoing: outgoing, read: read
    )
}

func makeSmsThread(
    id: Int64 = 42,
    address: String = "+61491570006",
    displayName: String = "Sam",
    snippet: String = "are you close?",
    whenMs: Int64 = 1_700_000_000_000,
    unread: Int = 0
) -> SmsThreadSummary {
    SmsThreadSummary(
        id: id, address: address, displayName: displayName,
        snippet: snippet, when: whenMs, unread: unread
    )
}

func makeSearchThread(
    id: Int64 = 42,
    pkg: String = ConversationKey.smsPseudoPackage,
    appLabel: String = "Messages",
    title: String = "Sam",
    body: String = "are you close?",
    address: String? = "+61491570006",
    isConversation: Bool = true
) -> ConversationThread {
    ConversationThread(
        id: .sms(threadId: id),
        pkg: pkg,
        appLabel: appLabel,
        title: title,
        messages: [MirroredMessage(notificationKey: nil, fingerprint: nil,
                                   origin: .phone, senderName: nil, body: body,
                                   when: TestClock.origin, avatarHash: nil,
                                   delivery: .incoming)],
        lastActivity: TestClock.origin,
        smsAddress: address,
        isConversation: isConversation
    )
}

func makeCall(
    id: String = "0|com.dialer|1|null|1000",
    state: String = "ringing",
    direction: String = "incoming",
    pkg: String = "com.dialer",
    appLabel: String = "Phone",
    displayName: String? = "Sam",
    number: String? = "+61491570006",
    video: Bool = false,
    whenMs: Int64 = 1_700_000_000_000,
    canAnswer: Bool = true,
    canDecline: Bool = true,
    canHangUp: Bool = false,
    resync: Bool? = nil,
    actions: [NotifAction]? = nil
) -> CallStateMessage {
    CallStateMessage(
        id: id, state: state, direction: direction, pkg: pkg, appLabel: appLabel,
        displayName: displayName, number: number, video: video, when: whenMs,
        canAnswer: canAnswer, canDecline: canDecline, canHangUp: canHangUp,
        resync: resync, actions: actions
    )
}

func makeTransfer(
    id: String = "a1b2c3d4",
    direction: TransferDirection = .toPhone,
    name: String = "notes.txt",
    bytes: Int = 1024,
    mime: String = "text/plain",
    sha256: String? = nil,
    startedAtMs: Int = 1_700_000_000_000
) -> Transfer {
    Transfer(id: id, direction: direction, name: name, bytes: bytes, mime: mime,
             sha256: sha256, startedAt: startedAtMs)
}

func makeOffer(
    id: String = "a1b2c3d4",
    name: String = "notes.txt",
    bytes: Int = 1024,
    mime: String = "text/plain",
    sha256: String = String(repeating: "b", count: 64),
    modifiedMs: Int64? = nil
) -> FileOffer {
    FileOffer(id: id, name: name, bytes: bytes, mime: mime, sha256: sha256,
              modified: modifiedMs)
}

/// Lowercase hex, so tests can mint ids that `Proto.isTransferID` accepts without naming
/// a formatter.
func hexID(_ value: Int) -> String {
    String(format: "%08x", value)
}
