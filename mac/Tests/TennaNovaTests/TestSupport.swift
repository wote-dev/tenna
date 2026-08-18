import Foundation
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
