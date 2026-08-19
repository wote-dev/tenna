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

    // MARK: - Sidebar preview

    @Test func aGroupChatPreviewNamesWhoeverSpoke() {
        var log = ConversationLog()
        log.ingest(makeNotification(senderName: "Sam", conversationTitle: "Weekend plans"))

        // Without the name, "are you close?" in a group of six says nothing at all.
        #expect(log.threadsByRecency[0].preview == "Sam: are you close?")
    }

    @Test func aOneToOnePreviewDoesNotRepeatTheRowTitle() {
        var log = ConversationLog()
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))

        let thread = log.threadsByRecency[0]
        #expect(thread.title == "Sam")
        #expect(thread.preview == "are you close?")
    }

    @Test func ourOwnReplyPreviewsAsOurs() {
        var log = ConversationLog()
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))
        log.appendOutgoing("five minutes", to: .conversation(pkg: "com.whatsapp", title: "Sam"))

        #expect(log.threadsByRecency[0].preview == "You: five minutes")
    }

    // MARK: - Restoring

    @Test func aReplyStillInFlightAtQuitIsNotLeftSpinning() {
        var log = ConversationLog()
        let key = ConversationKey.conversation(pkg: "com.whatsapp", title: "Sam")
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))
        log.appendOutgoing("five minutes", to: key)

        log.normalizeAfterRestore()

        // Nothing will ever reconcile it, so a spinner that never resolves would be a lie.
        #expect(log[key]?.messages.last?.delivery == .failed("Not sent — Tennanova quit"))
    }

    @Test func aRestoredThreadCannotBeRepliedToUntilThePhoneResyncs() {
        var log = ConversationLog()
        let key = ConversationKey.conversation(pkg: "com.whatsapp", title: "Sam")
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))
        #expect(log.replyTarget(for: key) != nil)

        log.normalizeAfterRestore()
        // `latestKey` addresses a notification from a session that is over; `actionId` is
        // a positional index into it. Firing either would hit the wrong thing or nothing.
        #expect(log.replyTarget(for: key) == nil)

        // The phone re-asserts both by replaying what is still on its screen.
        log.ingest(makeNotification(key: "k2", title: "Sam", senderName: "Sam", resync: true))
        #expect(log.replyTarget(for: key) != nil)
    }

    @Test func restoringKeepsTheTranscriptAndTheUnreadCount() {
        var log = ConversationLog()
        log.ingest(makeNotification(key: "k1", body: "one"))
        log.ingest(makeNotification(key: "k2", body: "two"))
        let before = log.threadsByRecency[0]

        log.normalizeAfterRestore()

        let after = log.threadsByRecency[0]
        #expect(after.messages.map(\.body) == before.messages.map(\.body))
        #expect(after.unreadCount == 2)
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

/// The transcript has to reach the disk: `ConversationLog` has been `Codable` since it
/// was written and nothing ever wrote it, so every quit threw the history away.
struct ConversationArchiveTests {

    @Test func nothingSavedReadsAsNothing() {
        withTemporaryArchive { archive in
            #expect(archive.load() == nil)
        }
    }

    @Test func aSavedTranscriptComesBackWhole() {
        withTemporaryArchive { archive in
            var log = ConversationLog()
            log.ingest(makeNotification(key: "k1", body: "one", senderName: "Sam",
                                        conversationTitle: "Weekend plans"))
            log.ingest(makeNotification(key: "k2", body: "two", senderName: "Ana",
                                        conversationTitle: "Weekend plans"))
            archive.save(log)

            let restored = archive.load()
            let thread = restored?.threadsByRecency.first
            #expect(restored?.threads.count == 1)
            #expect(thread?.title == "Weekend plans")
            #expect(thread?.messages.map(\.body) == ["one", "two"])
            #expect(thread?.messages.map(\.senderName) == ["Sam", "Ana"])
        }
    }

    @Test func loadingNormalisesWhatTheSavedStateCanNoLongerClaim() {
        withTemporaryArchive { archive in
            var log = ConversationLog()
            let key = ConversationKey.conversation(pkg: "com.whatsapp", title: "Sam")
            log.ingest(makeNotification(title: "Sam", senderName: "Sam"))
            log.appendOutgoing("five minutes", to: key)
            archive.save(log)

            // Loading, not just `normalizeAfterRestore`, is what has to do this — every
            // relaunch goes through here and nothing else.
            let restored = archive.load()
            #expect(restored?[key]?.isLiveOnPhone == false)
            #expect(restored?[key]?.messages.last?.delivery == .failed("Not sent — Tennanova quit"))
        }
    }

    @Test func aCorruptFileIsNotFatal() {
        withTemporaryArchive { archive in
            var log = ConversationLog()
            log.ingest(makeNotification())
            archive.save(log)
            archive.delete()

            // A history that cannot be read is not worth refusing to launch over.
            #expect(archive.load() == nil)
        }
    }
}
