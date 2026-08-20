import Testing
@testable import TennaNova

struct CallLogTests {

    @Test func aRingingCallIsLiveAndAlerts() {
        var log = CallLog()
        let change = log.apply(makeCall())
        #expect(change == .started(log.live[0]))
        #expect(log.live.count == 1)
        #expect(log.isRinging)
        #expect(log.current?.title == "Sam")
        #expect(log.current?.canAnswer == true)
    }

    @Test func aCallNamesTheNumberWhenNobodyKnowsWhoItIs() {
        var log = CallLog()
        log.apply(makeCall(displayName: nil))
        #expect(log.current?.title == "+61491570006")
        // The subtitle must not simply repeat the title back.
        #expect(log.current?.subtitle == "Phone")
    }

    @Test func answeringDoesNotStartASecondCall() {
        var log = CallLog()
        log.apply(makeCall())
        let change = log.apply(makeCall(state: "active", canAnswer: false,
                                    canDecline: false, canHangUp: true))
        guard case .updated(let updated) = change else {
            Issue.record("a second report of one call must not start another")
            return
        }
        #expect(log.live.count == 1)
        #expect(updated.wasAnswered)
        #expect(updated.answeredAt != nil)
        #expect(updated.canHangUp)
        #expect(!updated.canAnswer)
        #expect(!log.isRinging)
    }

    @Test func aCallThatWasAnsweredIsNotAMissedCall() {
        var log = CallLog()
        log.apply(makeCall())
        log.apply(makeCall(state: "active"))
        let change = log.apply(makeCall(state: "ended"))
        guard case .ended(let ended) = change else {
            Issue.record("the end of a call must be reported as one")
            return
        }
        #expect(!ended.isMissed)
        #expect(ended.wasAnswered)
        #expect(log.live.isEmpty)
        #expect(log.recents.count == 1)
        #expect(log.missedCount == 0)
    }

    @Test func aCallThatOnlyEverRangIsMissed() {
        // The one entry in the recents list that means the user owes someone a call back.
        var log = CallLog()
        log.apply(makeCall())
        log.apply(makeCall(state: "ended"))
        #expect(log.recents.first?.isMissed == true)
        #expect(log.missedCount == 1)
    }

    @Test func anOutgoingCallIsNeverMissed() {
        var log = CallLog()
        log.apply(makeCall(state: "active", direction: "outgoing"))
        log.apply(makeCall(state: "ended", direction: "outgoing"))
        #expect(log.recents.first?.isMissed == false)
    }

    @Test func endedButtonsAreTakenAwayWithTheCall() {
        // A card in the recents list still carrying `canAnswer` would draw a button that
        // fires an intent for a call that is over.
        var log = CallLog()
        log.apply(makeCall())
        log.apply(makeCall(state: "ended", canAnswer: true, canDecline: true))
        let ended = log.recents[0]
        #expect(!ended.canAnswer && !ended.canDecline && !ended.canHangUp)
        #expect(ended.endedAt != nil)
    }

    @Test func anEndForACallWeNeverSawIsIgnored() {
        // A phone reconnecting after a call finished replays nothing, but a stray removal
        // must not put a phantom row in the recents list.
        var log = CallLog()
        #expect(log.apply(makeCall(state: "ended")) == .ignored)
        #expect(log.recents.isEmpty)
    }

    @Test func anUnknownStateIsTreatedAsTheCallBeingOver() {
        // The safe reading of a newer phone build: never leave live buttons on screen for
        // something this Mac cannot follow.
        var log = CallLog()
        log.apply(makeCall())
        log.apply(makeCall(state: "on-hold-or-whatever-comes-next"))
        #expect(log.live.isEmpty)
        #expect(log.recents.count == 1)
    }

    @Test func aRingingCallOutranksOneAlreadyInProgress() {
        // Call waiting: the one needing an answer is the one the banner must show.
        var log = CallLog()
        log.apply(makeCall(id: "a", state: "active", displayName: "Amro"))
        log.apply(makeCall(id: "b", state: "ringing", displayName: "Sam"))
        #expect(log.current?.title == "Sam")
        #expect(log.live.count == 2)
    }

    @Test func aFailureLastsUntilThePhoneSaysSomethingNewer() {
        var log = CallLog()
        log.apply(makeCall())
        log.noteFailure(log.live[0].id, "Not sent — the phone is not connected.")
        #expect(log.live[0].failure != nil)
        log.apply(makeCall(state: "active"))
        #expect(log.live[0].failure == nil)
    }

    @Test func losingThePhoneDropsLiveCallsWithoutInventingMissedOnes() {
        // Every button on a live card fires through the socket, so a card left ringing
        // after the connection dropped is a card of buttons that go nowhere. It does not
        // become a missed call either: this Mac has no idea how those calls ended, and
        // recording a ring it lost sight of would invent a fact out of a network hiccup.
        var log = CallLog()
        log.apply(makeCall(id: "a"))
        log.apply(makeCall(id: "b", state: "active"))
        log.dropLiveCalls()
        #expect(log.live.isEmpty)
        #expect(log.recents.isEmpty)
        #expect(log.current == nil)
    }

    @Test func aDialerThatReKeysItsNotificationDoesNotInventAMissedCall() {
        // Some dialers cancel their ringing notification on answer and post a fresh one
        // under a new key. Read literally that is a missed call followed by an unrelated
        // call already in progress — wrong on both counts.
        var log = CallLog()
        log.apply(makeCall(id: "ring"), at: TestClock.origin)
        log.apply(makeCall(id: "ring", state: "ended"), at: TestClock.after(1))
        let change = log.apply(makeCall(id: "in-call", state: "active", canAnswer: false,
                                        canHangUp: true), at: TestClock.after(2))

        guard case .updated(let revived) = change else {
            Issue.record("a re-keyed call must not ring a second time")
            return
        }
        #expect(revived.id == "in-call")
        #expect(revived.wasAnswered)
        #expect(log.live.count == 1)
        #expect(log.recents.isEmpty)
        #expect(log.missedCount == 0)
    }

    @Test func callingSomebodyElseStraightAfterIsNotTheSameCall() {
        var log = CallLog()
        log.apply(makeCall(id: "a"), at: TestClock.origin)
        log.apply(makeCall(id: "a", state: "ended"), at: TestClock.after(1))
        let change = log.apply(makeCall(id: "b", displayName: "Amro", number: nil),
                               at: TestClock.after(2))
        guard case .started = change else {
            Issue.record("a different caller is a different call")
            return
        }
        #expect(log.recents.count == 1)
    }

    @Test func theSameCallerRingingAgainMuchLaterIsANewCall() {
        var log = CallLog()
        log.apply(makeCall(id: "a"), at: TestClock.origin)
        log.apply(makeCall(id: "a", state: "ended"), at: TestClock.after(1))
        let change = log.apply(makeCall(id: "b"), at: TestClock.after(120))
        guard case .started = change else {
            Issue.record("a call two minutes later is a second call, not a repost")
            return
        }
        #expect(log.recents.count == 1)
        #expect(log.live.count == 1)
    }

    @Test func recentsStopGrowing() {
        var log = CallLog()
        for index in 0..<(CallLog.maxRecents + 20) {
            // A different caller each time, or the revive window would fold each call
            // into the one before it — which is exactly what it is there to do.
            log.apply(makeCall(id: "\(index)", displayName: "Caller \(index)"))
            log.apply(makeCall(id: "\(index)", state: "ended",
                               displayName: "Caller \(index)"))
        }
        #expect(log.recents.count == CallLog.maxRecents)
        // Newest first, so the newest is the one that survives.
        #expect(log.recents.first?.id == "\(CallLog.maxRecents + 19)")
    }

    @Test func elapsedTimeReadsAsAClock() {
        let start = TestClock.origin
        #expect(CallStatusLine.elapsed(since: start, now: TestClock.after(9)) == "0:09")
        #expect(CallStatusLine.elapsed(since: start, now: TestClock.after(605)) == "10:05")
        #expect(CallStatusLine.elapsed(since: start, now: TestClock.after(3_661)) == "1:01:01")
        // A clock that runs backwards is worse than one that sits at zero.
        #expect(CallStatusLine.elapsed(since: start, now: TestClock.after(-5)) == "0:00")
    }
}

struct CallMessageTests {

    @Test func aCallStateSurvivesTheWire() throws {
        let decoded = try Wire.decode(CallStateMessage.self, from: Wire.encode(makeCall()))
        #expect(decoded.type == "call.state")
        #expect(decoded.lifecycle == .ringing)
        #expect(decoded.way == .incoming)
        #expect(decoded.canAnswer == true)
    }

    @Test func aCallFromAnOlderOrTerserPhoneStillDecodes() throws {
        // Everything but id, state, pkg and appLabel is optional on the wire, and a phone
        // that knows nothing about the caller sends none of it.
        let data = Wire.utf8(
            #"{"v":1,"type":"call.state","id":"k","state":"active","pkg":"com.dialer","appLabel":"Phone"}"#
        )
        let decoded = try Wire.decode(CallStateMessage.self, from: data)
        #expect(decoded.lifecycle == .active)
        #expect(decoded.canAnswer == nil)
        #expect(decoded.actions == nil)
        // Absent direction reads as incoming, which is what an unlabelled call almost
        // always is and what the recents row would otherwise have to guess at.
        #expect(decoded.way == .incoming)
    }

    @Test func anActionCarriesItsVerbAndItsBubble() throws {
        let invoke = CallActionInvoke(id: "k", action: .hangup, clientId: "9F3B")
        let decoded = try Wire.decode(CallActionInvoke.self, from: Wire.encode(invoke))
        #expect(decoded.type == "call.action")
        #expect(decoded.action == "hangup")
        #expect(decoded.clientId == "9F3B")
    }
}
