import Testing
@testable import TennaNova

struct ConversationLogTests {

    // MARK: - Grouping

    @Test func groupChatKeysOnItsConversationTitle() {
        let key = ConversationKey(makeNotification(conversationTitle: "Weekend plans"))
        #expect(key == .conversation(pkg: "com.whatsapp", title: "Weekend plans"))
    }

    @Test func oneToOneChatKeysOnItsTitle() {
        // Android sets conversationTitle only for group chats by convention, so a 1:1 has
        // to fall back to the title or every message becomes its own conversation.
        let key = ConversationKey(makeNotification(title: "Sam", senderName: "Sam"))
        #expect(key == .conversation(pkg: "com.whatsapp", title: "Sam"))
    }

    @Test func titlelessConversationFallsBackToItsNotificationKey() {
        let key = ConversationKey(
            makeNotification(key: "k1", title: nil, senderName: "Sam")
        )
        #expect(key == .keyed(pkg: "com.whatsapp", key: "k1"))
    }

    @Test func transactionalNotificationsShareOneRowPerApp() {
        // A delivery update and a build failure from the same app belong together, not in
        // one sidebar row each.
        let first = makeNotification(
            key: "a", title: "Order shipped", category: "status", actions: []
        )
        let second = makeNotification(
            key: "b", title: "Out for delivery", category: "status", actions: []
        )
        #expect(ConversationKey(first) == .app(pkg: "com.whatsapp"))
        #expect(ConversationKey(first) == ConversationKey(second))
    }

    @Test func oneChatStaysOneThreadEvenAsItsKeyChanges() {
        var log = ConversationLog()
        log.ingest(makeNotification(key: "k1", body: "first",
                                      conversationTitle: "Weekend plans"))
        log.ingest(makeNotification(key: "k2", body: "second",
                                      conversationTitle: "Weekend plans"))

        #expect(log.threadsByRecency.count == 1)
        #expect(log.threadsByRecency[0].messages.count == 2)
    }

    // MARK: - Ingest

    @Test func resyncReplayDoesNotDuplicateTheTranscript() {
        var log = ConversationLog()
        var notification = makeNotification(body: "are you close?")
        log.ingest(notification)

        notification.resync = true
        let outcome = log.ingest(notification)

        #expect(outcome == .duplicate)
        #expect(log.threadsByRecency[0].messages.count == 1)
    }

    @Test func aReplayedNotificationDoesNotCountAsUnread() {
        var log = ConversationLog()
        var notification = makeNotification(key: "k1", body: "seen already")
        notification.resync = true
        log.ingest(notification)

        #expect(log.totalUnread == 0)
        #expect(log.threadsByRecency[0].messages.count == 1)
    }

    @Test func aGrowingBodyReplacesRatherThanStutters() {
        var log = ConversationLog()
        let start = TestClock.origin
        log.ingest(makeNotification(key: "k1", body: "are you"), at: start)
        let outcome = log.ingest(makeNotification(key: "k1", body: "are you close?"),
                                 at: start.addingTimeInterval(0.2))

        #expect(outcome == .replacedLatest(.conversation(pkg: "com.whatsapp", title: "Sam")))
        #expect(log.threadsByRecency[0].messages.count == 1)
        #expect(log.threadsByRecency[0].messages[0].body == "are you close?")
    }

    @Test func anUnrelatedLaterMessageOnTheSameKeyAppends() {
        var log = ConversationLog()
        let start = TestClock.origin
        log.ingest(makeNotification(key: "k1", body: "are you close?"), at: start)
        let outcome = log.ingest(makeNotification(key: "k1", body: "never mind"),
                                 at: start.addingTimeInterval(60))

        #expect(outcome == .appended(.conversation(pkg: "com.whatsapp", title: "Sam")))
        #expect(log.threadsByRecency[0].messages.count == 2)
    }

    // MARK: - Removal

    @Test func clearingOnThePhoneKeepsTheTranscriptButKillsTheReplyTarget() {
        var log = ConversationLog()
        let notification = makeNotification(key: "k1")
        log.ingest(notification)
        let key = ConversationKey(notification)

        #expect(log.replyTarget(for: key) != nil)

        log.markRemovedOnPhone(key: "k1")

        #expect(log.threadsByRecency[0].messages.count == 1)
        #expect(log.threadsByRecency[0].isLiveOnPhone == false)
        #expect(log.replyTarget(for: key) == nil)
    }

    // MARK: - Reply targeting

    @Test func replyTargetTracksTheLatestPostNotAnOlderOne() {
        // actionId is a positional index into whichever notification carried it, so a
        // target resolved from a stale action list can invoke the wrong button entirely.
        var log = ConversationLog()
        log.ingest(makeNotification(
            key: "k1", body: "first",
            actions: [NotifAction(id: 0, label: "Reply", isReply: true)]
        ))
        let notification = makeNotification(
            key: "k1", body: "second",
            actions: [NotifAction(id: 0, label: "Mark as read", isReply: false),
                      NotifAction(id: 1, label: "Reply", isReply: true)]
        )
        log.ingest(notification)

        #expect(log.replyTarget(for: ConversationKey(notification))
            == ReplyTarget(key: "k1", actionId: 1))
    }

    @Test func anAppWithNoReplyActionOffersNoTarget() {
        var log = ConversationLog()
        let notification = makeNotification(
            title: "Sam", senderName: "Sam",
            actions: [NotifAction(id: 0, label: "Archive", isReply: false)]
        )
        log.ingest(notification)

        #expect(log.replyTarget(for: ConversationKey(notification)) == nil)
    }

    // MARK: - Optimistic echo

    @Test func ourOwnReplyComingBackReconcilesIntoOneBubble() {
        var log = ConversationLog()
        let notification = makeNotification(body: "are you close?")
        log.ingest(notification)
        let key = ConversationKey(notification)

        let sent = TestClock.origin
        let id = log.appendOutgoing("on my way", to: key, at: sent)
        log.markDelivery(id!, .sent)

        let outcome = log.ingest(
            makeNotification(key: "k1", body: "on my way", senderName: "You"),
            at: sent.addingTimeInterval(2)
        )

        #expect(outcome == .reconciledOutgoing(id!))
        #expect(log.threadsByRecency[0].messages.count == 2)
        #expect(log.threadsByRecency[0].messages.last?.delivery == .confirmed)
    }

    @Test func anIdenticalMessageLongAfterIsNotAnEcho() {
        var log = ConversationLog()
        let notification = makeNotification(body: "are you close?")
        log.ingest(notification)
        let key = ConversationKey(notification)

        let sent = TestClock.origin
        let id = log.appendOutgoing("ok", to: key, at: sent)
        log.markDelivery(id!, .sent)

        log.ingest(makeNotification(key: "k9", body: "ok", senderName: "Sam"),
                   at: sent.addingTimeInterval(ConversationLog.echoWindow + 5))

        #expect(log.threadsByRecency[0].messages.count == 3)
    }

    // MARK: - Retention

    @Test func aThreadStopsGrowingAtItsCap() {
        var log = ConversationLog()
        let start = TestClock.origin
        for i in 0...(ConversationLog.maxMessagesPerThread + 20) {
            log.ingest(makeNotification(key: "k\(i)", body: "message \(i)"),
                       at: start.addingTimeInterval(Double(i) * 60))
        }

        let thread = log.threadsByRecency[0]
        #expect(thread.messages.count == ConversationLog.maxMessagesPerThread)
        // Oldest go first.
        #expect(thread.messages.first?.body == "message 21")
    }

    @Test func threadsAreOrderedByRecencyAndTieBreakStably() {
        var log = ConversationLog()
        let stamp = TestClock.origin
        log.ingest(makeNotification(key: "b", conversationTitle: "Beta"), at: stamp)
        log.ingest(makeNotification(key: "a", conversationTitle: "Alpha"), at: stamp)

        // Identical timestamps must not let the order wobble between reads.
        let first = log.threadsByRecency.map(\.id.sortKey)
        let second = log.threadsByRecency.map(\.id.sortKey)
        #expect(first == second)
    }

    @Test func markingReadClearsOnlyThatThread() {
        var log = ConversationLog()
        let one = makeNotification(key: "k1", conversationTitle: "Alpha")
        let two = makeNotification(key: "k2", conversationTitle: "Beta")
        log.ingest(one)
        log.ingest(two)

        log.markRead(ConversationKey(one))

        #expect(log[ConversationKey(one)]?.unreadCount == 0)
        #expect(log[ConversationKey(two)]?.unreadCount == 1)
        #expect(log.totalUnread == 1)
    }
}

struct IconRequestPolicyTests {
    // `shouldRequest` is mutating, and #expect lifts its argument into a closure where the
    // captured value is immutable — so every call is made first and the result asserted.

    @Test func aHashIsRequestedOnceThenBackedOff() {
        var policy = IconRequestPolicy()

        let first = policy.shouldRequest("abc", at: TestClock.origin)
        let tooSoon = policy.shouldRequest("abc", at: TestClock.after(1))
        let afterBackoff = policy.shouldRequest("abc", at: TestClock.after(31))

        #expect(first)
        #expect(!tooSoon)
        #expect(afterBackoff)
    }

    @Test func aHashThePhoneNeverAnswersIsAbandoned() {
        // The phone's asset cache holds 128 entries and an evicted hash produces no reply
        // at all, so without a cap the Mac would ask forever.
        var policy = IconRequestPolicy()
        var granted = 0
        var elapsed = 0.0
        for _ in 0..<IconRequestPolicy.maxAttempts {
            if policy.shouldRequest("abc", at: TestClock.after(elapsed)) { granted += 1 }
            elapsed += IconRequestPolicy.backoff + 1
        }
        let afterCap = policy.shouldRequest("abc", at: TestClock.after(elapsed))
        let muchLater = policy.shouldRequest("abc", at: TestClock.after(elapsed + 3600))

        #expect(granted == IconRequestPolicy.maxAttempts)
        #expect(!afterCap)
        #expect(!muchLater)
    }

    @Test func bytesArrivingResetTheHash() {
        var policy = IconRequestPolicy()
        let first = policy.shouldRequest("abc", at: TestClock.origin)
        policy.received("abc")
        let again = policy.shouldRequest("abc", at: TestClock.origin)

        #expect(first)
        #expect(again)
    }
}
