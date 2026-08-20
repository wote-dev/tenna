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

    // MARK: - Replying to a withdrawn notification

    @Test func aWithdrawnConversationIsStillAddressableWhenThePhoneAllowsIt() {
        var log = ConversationLog()
        let key = ConversationKey.conversation(pkg: "com.whatsapp", title: "Sam")
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))
        log.markRemovedOnPhone(key: "k1")

        // Messaging apps withdraw their notification the moment the chat is read on the
        // phone, so refusing here is refusing almost every real conversation. The reply
        // PendingIntent outlives the notification that carried it.
        #expect(log.replyTarget(for: key) == nil)
        #expect(log.replyTarget(for: key, allowingWithdrawn: true)
                == ReplyTarget(key: "k1", actionId: 0))
    }

    @Test func aWithdrawnConversationThePhoneNoLongerHoldsIsRefused() {
        var log = ConversationLog()
        let key = ConversationKey.conversation(pkg: "com.whatsapp", title: "Sam")
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))
        log.markRemovedOnPhone(key: "k1")

        // Restarting the Android app loses the reply intent for anything already cleared.
        // Our own history still remembers the action, which is exactly why it is not
        // evidence — believing it promised replies that came back as failures.
        log.applyReplyableKeys([])
        #expect(log.replyTarget(for: key, allowingWithdrawn: true) == nil)

        // And the phone saying it holds one is what makes it addressable again.
        log.applyReplyableKeys(["k1"])
        #expect(log.replyTarget(for: key, allowingWithdrawn: true)
                == ReplyTarget(key: "k1", actionId: 0))
    }

    @Test func aLiveConversationDoesNotWaitForThePhonesReplyableList() {
        var log = ConversationLog()
        let key = ConversationKey.conversation(pkg: "com.whatsapp", title: "Sam")
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))

        // The list arrives once per reconnect; a notification posted since then is
        // self-evidently one the phone just captured.
        log.applyReplyableKeys([])
        #expect(log.replyTarget(for: key) == ReplyTarget(key: "k1", actionId: 0))
    }

    @Test func aRestoredHistoryClaimsNothingAboutWhatThePhoneHolds() {
        var log = ConversationLog()
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))
        #expect(log.replyableKeys == ["k1"])

        log.normalizeAfterRestore()

        // Nothing on disk can speak for a phone process that has not connected yet.
        #expect(log.replyableKeys.isEmpty)
    }

    @Test func aConversationWithNoReplyActionStaysUnaddressableEitherWay() {
        var log = ConversationLog()
        let key = ConversationKey.app(pkg: "com.google.android.gm")
        log.ingest(makeNotification(
            pkg: "com.google.android.gm", title: "Receipt", category: "status",
            actions: [NotifAction(id: 0, label: "Delete", isReply: false)]
        ))

        // `allowingWithdrawn` relaxes *which notification* may be addressed, never
        // whether one that never offered a reply suddenly does.
        #expect(log.replyTarget(for: key, allowingWithdrawn: true) == nil)
    }

    @Test func aReplyThePhoneCouldNotSendIsReportedAsFailed() {
        var log = ConversationLog()
        let key = ConversationKey.conversation(pkg: "com.whatsapp", title: "Sam")
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))
        let id = log.appendOutgoing("five minutes", to: key)!

        log.applyReplyResult(id, ok: false, error: "The app withdrew this conversation's reply.")

        #expect(log[key]?.messages.last?.delivery
                == .failed("The app withdrew this conversation's reply."))
    }

    @Test func aReplyThePhoneSentIsNotYetConfirmed() {
        var log = ConversationLog()
        let key = ConversationKey.conversation(pkg: "com.whatsapp", title: "Sam")
        log.ingest(makeNotification(title: "Sam", senderName: "Sam"))
        let id = log.appendOutgoing("five minutes", to: key)!
        log.markDelivery(id, .sent)

        log.applyReplyResult(id, ok: true, error: nil)

        // Firing the intent is not the app accepting it. Only the phone mirroring the
        // message back earns `.confirmed`.
        #expect(log[key]?.messages.last?.delivery == .sent)
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

/// SMS reuses the notification reducer rather than standing up a second store, so these
/// cover the parts where a text is genuinely not a notification.
struct SmsConversationTests {

    private let key = ConversationKey.sms(threadId: 42)

    @Test func textsAndChatsShareOneInbox() {
        var log = ConversationLog()
        log.ingest(makeNotification(title: "Sam", whenMs: 1_700_000_000_000, senderName: "Sam"))
        log.ingest(makeSms(whenMs: 1_700_000_100_000))

        // One sidebar, ordered by recency, with the whole tested reducer applying to both.
        #expect(log.threads.count == 2)
        #expect(log.threadsByRecency.first?.id == key)
    }

    @Test func aThreadSummaryFillsTheSidebarBeforeItsHistoryArrives() {
        var log = ConversationLog()
        log.applySmsThreads([makeSmsThread(snippet: "see you at 8", unread: 3)])

        let thread = log[key]
        #expect(thread?.title == "Sam")
        #expect(thread?.smsAddress == "+61491570006")
        #expect(thread?.unreadCount == 3)
        // A summary carries a snippet, not a transcript.
        #expect(thread?.messages.isEmpty == true)
        #expect(thread?.preview == "see you at 8")
    }

    @Test func historyDoesNotDuplicateWhenAThreadIsOpenedTwice() {
        var log = ConversationLog()
        let page = [makeSms(id: 1, body: "one"), makeSms(id: 2, body: "two")]
        log.applySmsMessages(threadId: 42, messages: page)
        log.applySmsMessages(threadId: 42, messages: page)

        #expect(log[key]?.messages.map(\.body) == ["one", "two"])
    }

    @Test func aReadSmsThreadStaysReadWhenThePhoneRepushesItsSummary() {
        var log = ConversationLog()
        log.applySmsThreads([makeSmsThread(unread: 3)])
        log.markRead(key)
        #expect(log[key]?.unreadCount == 0)

        // Every reconnect re-pushes this, and the provider still counts those three as
        // unread because reading on the Mac cannot mark them read on the phone. Before the
        // watermark this is where the badge came back.
        log.applySmsThreads([makeSmsThread(unread: 3)])

        #expect(log[key]?.unreadCount == 0)
    }

    @Test func aNewTextAfterReadingStillRaisesTheBadge() {
        var log = ConversationLog()
        log.applySmsThreads([makeSmsThread(whenMs: 1_700_000_000_000, unread: 3)])
        log.markRead(key)

        // Newer than the watermark, so this is genuinely news.
        log.applySmsThreads([makeSmsThread(whenMs: 1_700_000_060_000, unread: 1)])

        #expect(log[key]?.unreadCount == 1)
    }

    @Test func aTextSentFromTheMacIsConfirmedByTheRowThePhoneWrites() {
        var log = ConversationLog()
        log.applySmsThreads([makeSmsThread()])
        let id = log.appendOutgoing("five minutes", to: key)!
        log.markDelivery(id, .sent)

        // Unlike a notification reply, SMS really can be confirmed: the provider row comes
        // back through `sms.received` and is the same message.
        log.ingest(makeSms(id: 99, body: "five minutes", outgoing: true))

        let messages = log[key]?.messages ?? []
        #expect(messages.count == 1)
        #expect(messages.first?.delivery == .confirmed)
        #expect(messages.first?.id == id)
    }

    @Test func aTextSentOnThePhoneShowsAsOursWithoutAnEcho() {
        var log = ConversationLog()
        log.ingest(makeSms(id: 5, body: "on my way", outgoing: true))

        let message = log[key]?.messages.first
        #expect(message?.origin == .mac)
        // Nothing optimistic to reconcile — this one was typed on the phone.
        #expect(message?.delivery == .confirmed)
    }

    @Test func backfillAndLiveArrivalsEndUpInReadingOrder() {
        var log = ConversationLog()
        log.ingest(makeSms(id: 9, body: "newest", whenMs: 1_700_000_300_000))
        log.applySmsMessages(threadId: 42, messages: [
            makeSms(id: 7, body: "oldest", whenMs: 1_700_000_100_000),
            makeSms(id: 8, body: "middle", whenMs: 1_700_000_200_000)
        ])

        // History pages arrive after the live message that prompted the thread to open.
        #expect(log[key]?.messages.map(\.body) == ["oldest", "middle", "newest"])
    }

    @Test func anIncomingTextNamesTheSenderAndAnOutgoingOneDoesNot() {
        var log = ConversationLog()
        log.ingest(makeSms(id: 1, displayName: "Sam"))
        log.ingest(makeSms(id: 2, displayName: "Me", body: "nearly", outgoing: true))

        // An outgoing row's displayName is us, and must not rename the conversation.
        #expect(log[key]?.title == "Sam")
        #expect(log[key]?.messages.last?.senderName == nil)
    }

    @Test func alreadyReadTextsDoNotRaiseTheUnreadCount() {
        var log = ConversationLog()
        log.ingest(makeSms(id: 1, read: true))
        log.ingest(makeSms(id: 2, body: "and another", read: false))

        #expect(log[key]?.unreadCount == 1)
    }

    @Test func startingAConversationTwiceReusesTheSameThread() {
        var log = ConversationLog()
        let first = log.draftSmsThread(address: "+61 491 570 006", title: "+61 491 570 006")
        // The same person, written the way a phone keypad produces it.
        let second = log.draftSmsThread(address: "0491570006", title: "0491570006")

        #expect(first == second)
        #expect(log.threads.count == 1)
    }

    @Test func aDraftThreadCannotCollideWithARealOne() {
        var log = ConversationLog()
        log.applySmsThreads([makeSmsThread(id: 1)])
        let draft = log.draftSmsThread(address: "+61400000000", title: "New")

        // The phone assigns real ids; until it does, a negative one cannot be mistaken
        // for a thread that already exists.
        if case let .sms(threadId) = draft { #expect(threadId < 0) } else { Issue.record("not sms") }
        #expect(log.threads.count == 2)
    }
}

struct SmsAddressMatchTests {

    @Test func oneNumberWrittenSeveralWaysIsOnePerson() {
        // Must keep agreeing with `SmsAddresses.normalize` on the phone.
        #expect(SmsAddressMatch.same("+61 491 570 006", "0491570006"))
        #expect(SmsAddressMatch.same("+61491570006", "491570006"))
    }

    @Test func differentPeopleStayDifferent() {
        #expect(!SmsAddressMatch.same("+61491570006", "+61401660455"))
    }

    @Test func shortCodesAreNotTruncatedIntoEachOther() {
        #expect(!SmsAddressMatch.same("19876", "28876"))
        #expect(SmsAddressMatch.normalize("19876") == "19876")
    }

    @Test func alphanumericSendersSurvive() {
        #expect(SmsAddressMatch.normalize("amaysim") == "amaysim")
        #expect(SmsAddressMatch.same("amaysim", "AMAYSIM"))
    }

    // MARK: - Messages against notifications

    @Test func chatsAndAppNoiseGoIntoDifferentLists() {
        // The window draws these as two tabs. One combined list is dominated by whichever
        // arrives more often, and it is never the messages.
        var log = ConversationLog()
        log.ingest(makeNotification(key: "a", pkg: "com.whatsapp", title: "Sam",
                                    category: "msg", senderName: "Sam"))
        log.ingest(makeNotification(key: "b", pkg: "com.kfc", appLabel: "KFC",
                                    title: "The irresistible original",
                                    body: "Smash 6 pieces of OG gold.",
                                    category: "promo", actions: []))
        log.ingest(makeSms())

        #expect(log.conversationsByRecency.count == 2)
        #expect(log.alertsByRecency.count == 1)
        #expect(log.alertsByRecency.first?.pkg == "com.kfc")
        #expect(log.conversationsByRecency.allSatisfy { $0.isChat })
    }

    @Test func aPromotionThatClaimsToBeAMessageIsNotOne() {
        // Observed in the wild: a food-delivery promo carrying a `msg` category and a
        // conversation title, which the *grouping* honours — so it gets a row of its own —
        // and which put it in the inbox beside actual people. No sender, no reply button.
        var log = ConversationLog()
        log.ingest(makeNotification(key: "a", pkg: "com.dd.doordash", appLabel: "DoorDash",
                                    title: "Popular nearby",
                                    body: "KFC is getting lots of orders near you.",
                                    category: "msg",
                                    conversationTitle: "Popular nearby",
                                    actions: []))
        #expect(log.conversationsByRecency.isEmpty)
        #expect(log.alertsByRecency.count == 1)
    }

    @Test func oneQuietMessageDoesNotDemoteAChat() {
        // Chat apps post plenty of notifications with no reply action — a photo, a call
        // summary, "message deleted". A thread does not stop being a conversation for it.
        var log = ConversationLog()
        log.ingest(makeNotification(key: "a", pkg: "com.whatsapp",
                                    conversationTitle: "Family"))
        log.ingest(makeNotification(key: "b", pkg: "com.whatsapp", body: "📷 1 photo",
                                    category: nil, conversationTitle: "Family",
                                    actions: []))
        #expect(log.conversationsByRecency.count == 1)
        #expect(log.alertsByRecency.isEmpty)
    }

    @Test func restoredThreadsSortThemselvesFromTheReplyActionOnDisk() {
        // An archive written before the flag existed. The retained reply action is the
        // same evidence a live notification carries, so the inbox is right at launch
        // rather than after the next message arrives.
        var log = ConversationLog()
        log.ingest(makeNotification(key: "a", pkg: "com.whatsapp", senderName: "Sam"))
        log.ingest(makeNotification(key: "b", pkg: "com.dhl", title: "Delivered",
                                    category: "msg", conversationTitle: "Delivered",
                                    actions: []))
        log.forgetConversationFlagsForTesting()
        log.normalizeAfterRestore()

        #expect(log.conversationsByRecency.count == 1)
        #expect(log.conversationsByRecency.first?.pkg == "com.whatsapp")
        #expect(log.alertsByRecency.count == 1)
        #expect(log.alertsByRecency.first?.pkg == "com.dhl")
    }

    @Test func theTwoUnreadCountsAddUpToTheOldOne() {
        var log = ConversationLog()
        log.ingest(makeNotification(key: "a", pkg: "com.whatsapp", category: "msg"))
        log.ingest(makeNotification(key: "b", pkg: "com.kfc", title: "Deal",
                                    category: "promo", actions: []))
        log.ingest(makeNotification(key: "c", pkg: "com.dhl", title: "Delivered",
                                    category: "status", actions: []))

        #expect(log.conversationUnread == 1)
        #expect(log.alertUnread == 2)
        #expect(log.conversationUnread + log.alertUnread == log.totalUnread)
    }

    // MARK: - Reading, and badges that must not come back

    @Test func aRepostedNotificationDoesNotRelightAReadThread() {
        var log = ConversationLog()
        // Android stamps a notification with when it was *raised*, and a repost of the same
        // message carries that same stamp rather than the moment it was re-sent.
        let posted: Int64 = 1_700_000_000_000
        let notification = makeNotification(key: "k1", whenMs: posted)
        let threadKey = ConversationKey(notification)
        log.ingest(notification)
        log.markRead(threadKey)

        // Not a resync — several apps simply post the same message again when a chat
        // updates. Nothing in it is newer than what has already been read on this Mac.
        log.ingest(makeNotification(key: "k2", whenMs: posted))

        #expect(log[threadKey]?.unreadCount == 0)
    }

    @Test func aLaterMessageInAReadThreadStillCounts() {
        var log = ConversationLog()
        let notification = makeNotification(key: "k1", whenMs: 1_700_000_000_000)
        let threadKey = ConversationKey(notification)
        log.ingest(notification)
        log.markRead(threadKey)

        log.ingest(makeNotification(key: "k2", body: "still there?",
                                    whenMs: 1_700_000_060_000))

        #expect(log[threadKey]?.unreadCount == 1)
    }

    // MARK: - Alerting

    @Test func ourOwnReplyComingBackIsNotWorthAnAlert() {
        var log = ConversationLog()
        log.ingest(makeNotification(key: "k1", body: "are you close?"))
        let threadKey = ConversationKey(makeNotification(key: "k1", body: "are you close?"))
        log.appendOutgoing("five minutes", to: threadKey)

        // WhatsApp re-posts its MessagingStyle notification once the reply goes out, and
        // that post carries the line we just typed here.
        let outcome = log.ingest(makeNotification(key: "k1", body: "five minutes"))

        if case .reconciledOutgoing = outcome {} else {
            Issue.record("expected the echo to reconcile, got \(outcome)")
        }
        #expect(outcome.deservesAnAlert == false)
    }

    @Test func aGenuineMessageIsWorthAnAlert() {
        var log = ConversationLog()
        let outcome = log.ingest(makeNotification(key: "k1", body: "are you close?"))
        #expect(outcome.deservesAnAlert)
        // A duplicate stays alertable here: judging duplicates is the replay guard's job,
        // and it is the only thing that knows what Notification Center is holding.
        #expect(IngestOutcome.duplicate.deservesAnAlert)
    }

    @Test func anythingWithAReplyButtonIsAConversation() {
        // The line is exactly the one `ConversationKey.init` already drew: an app that
        // offers a reply is talking *with* someone, whatever its category says.
        var log = ConversationLog()
        log.ingest(makeNotification(key: "a", pkg: "com.slack", title: "deploys",
                                    category: nil,
                                    actions: [NotifAction(id: 0, label: "Reply", isReply: true)]))
        #expect(log.conversationsByRecency.count == 1)
        #expect(log.alertsByRecency.isEmpty)
    }
}

