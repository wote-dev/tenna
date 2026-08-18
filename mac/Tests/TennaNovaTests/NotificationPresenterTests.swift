import Testing
@testable import TennaNova

struct NotificationPresenterTests {
    @Test func identicalNotificationIsSuppressedAfterFirstReservation() {
        let notification = sampleNotification()
        let identity = NotificationPresentationIdentity(notification)
        var guardState = NotificationReplayGuard()

        #expect(guardState.reserve(
            key: notification.key,
            fingerprint: identity.fingerprint
        ) != nil)
        #expect(guardState.reserve(
            key: notification.key,
            fingerprint: identity.fingerprint
        ) == nil)
    }

    @Test func seededDeliveredNotificationSuppressesReconnectReplay() {
        let notification = sampleNotification()
        let identity = NotificationPresentationIdentity(notification)
        var guardState = NotificationReplayGuard()

        guardState.seed(key: notification.key, fingerprint: identity.fingerprint)

        #expect(guardState.reserve(
            key: notification.key,
            fingerprint: identity.fingerprint
        ) == nil)
    }

    @Test func differentKeysWithSameContentBothPresent() {
        let first = sampleNotification(key: "whatsapp.message.1")
        let second = sampleNotification(key: "whatsapp.message.2")
        var guardState = NotificationReplayGuard()

        #expect(guardState.reserve(
            key: first.key,
            fingerprint: NotificationPresentationIdentity(first).fingerprint
        ) != nil)
        #expect(guardState.reserve(
            key: second.key,
            fingerprint: NotificationPresentationIdentity(second).fingerprint
        ) != nil)
    }

    @Test func meaningfulContentAndActionChangesPresentAgain() {
        let original = sampleNotification()
        let changedTitle = sampleNotification(title: "Maya")
        let changedBody = sampleNotification(body: "A second message")
        let changedIcon = sampleNotification(iconHash: String(repeating: "b", count: 64))
        let changedCategory = sampleNotification(category: "social")
        let changedPackage = sampleNotification(pkg: "com.whatsapp.business")
        let changedActions = sampleNotification(actions: [
            NotifAction(id: 0, label: "Reply", isReply: true),
            NotifAction(id: 1, label: "Mark as read", isReply: false)
        ])
        var guardState = NotificationReplayGuard()

        #expect(guardState.reserve(
            key: original.key,
            fingerprint: NotificationPresentationIdentity(original).fingerprint
        ) != nil)
        #expect(guardState.reserve(
            key: changedTitle.key,
            fingerprint: NotificationPresentationIdentity(changedTitle).fingerprint
        ) != nil)
        #expect(guardState.reserve(
            key: changedBody.key,
            fingerprint: NotificationPresentationIdentity(changedBody).fingerprint
        ) != nil)
        #expect(guardState.reserve(
            key: changedIcon.key,
            fingerprint: NotificationPresentationIdentity(changedIcon).fingerprint
        ) != nil)
        #expect(guardState.reserve(
            key: changedCategory.key,
            fingerprint: NotificationPresentationIdentity(changedCategory).fingerprint
        ) != nil)
        #expect(guardState.reserve(
            key: changedPackage.key,
            fingerprint: NotificationPresentationIdentity(changedPackage).fingerprint
        ) != nil)
        #expect(guardState.reserve(
            key: changedActions.key,
            fingerprint: NotificationPresentationIdentity(changedActions).fingerprint
        ) != nil)
    }

    @Test func timestampOnlyChangeRemainsADuplicate() {
        let original = sampleNotification(whenMs: 1)
        let replay = sampleNotification(whenMs: 2)

        #expect(
            NotificationPresentationIdentity(original).fingerprint ==
                NotificationPresentationIdentity(replay).fingerprint
        )
    }

    @Test func clearAllowsSameNotificationToAppearAgain() {
        let notification = sampleNotification()
        let identity = NotificationPresentationIdentity(notification)
        var guardState = NotificationReplayGuard()

        #expect(guardState.reserve(
            key: notification.key,
            fingerprint: identity.fingerprint
        ) != nil)
        guardState.clear(key: notification.key)
        #expect(guardState.reserve(
            key: notification.key,
            fingerprint: identity.fingerprint
        ) != nil)
    }

    @Test func failedDeliveryRestoresPreviousFingerprint() {
        let original = sampleNotification()
        let update = sampleNotification(body: "Updated")
        let originalIdentity = NotificationPresentationIdentity(original)
        let updateIdentity = NotificationPresentationIdentity(update)
        var guardState = NotificationReplayGuard()

        guardState.seed(key: original.key, fingerprint: originalIdentity.fingerprint)
        let reservation = guardState.reserve(
            key: update.key,
            fingerprint: updateIdentity.fingerprint
        )
        #expect(reservation != nil)
        guardState.rollBack(reservation!)

        #expect(guardState.reserve(
            key: original.key,
            fingerprint: originalIdentity.fingerprint
        ) == nil)
        #expect(guardState.reserve(
            key: update.key,
            fingerprint: updateIdentity.fingerprint
        ) != nil)
    }

    @Test func notificationsFromSamePackageUseDifferentThreads() {
        let first = sampleNotification(key: "whatsapp.message.1")
        let second = sampleNotification(key: "whatsapp.message.2")

        #expect(NotificationPresentationIdentity(first).threadIdentifier == first.key)
        #expect(NotificationPresentationIdentity(second).threadIdentifier == second.key)
        #expect(
            NotificationPresentationIdentity(first).threadIdentifier !=
                NotificationPresentationIdentity(second).threadIdentifier
        )
    }

    @Test func oneConversationSharesAThreadAcrossKeys() {
        // WhatsApp gives a reaction its own key, but it belongs to the same chat.
        let message = sampleNotification(key: "whatsapp.message.1", conversationTitle: "Deema")
        let reaction = sampleNotification(key: "whatsapp.reaction.9", conversationTitle: "Deema")
        let otherChat = sampleNotification(key: "whatsapp.message.2", conversationTitle: "Maya")

        #expect(
            NotificationPresentationIdentity(message).threadIdentifier ==
                NotificationPresentationIdentity(reaction).threadIdentifier
        )
        #expect(
            NotificationPresentationIdentity(message).threadIdentifier !=
                NotificationPresentationIdentity(otherChat).threadIdentifier
        )
    }

    @Test func avatarDoesNotChangeIdentity() {
        // The photo arrives after the first card. If it altered the fingerprint the next
        // notification would ring a second time for content the user has already seen.
        let withoutAvatar = sampleNotification()
        let withAvatar = sampleNotification(avatarHash: String(repeating: "c", count: 64))

        #expect(
            NotificationPresentationIdentity(withoutAvatar).fingerprint ==
                NotificationPresentationIdentity(withAvatar).fingerprint
        )
    }

    @Test func differentSendersInOneChatArePresentedSeparately() {
        let fromDeema = sampleNotification(senderName: "Deema")
        let fromMaya = sampleNotification(senderName: "Maya")

        #expect(
            NotificationPresentationIdentity(fromDeema).fingerprint !=
                NotificationPresentationIdentity(fromMaya).fingerprint
        )
    }

    @Test func replayedNotificationStaysQuietAfterTheUserClearsIt() {
        let notification = sampleNotification()
        let identity = NotificationPresentationIdentity(notification)
        var guardState = NotificationReplayGuard()

        guardState.recordPresented(key: notification.key, fingerprint: identity.fingerprint)
        // The user swipes it away on the Mac; the dismissal poller clears the reservation.
        guardState.clear(key: notification.key)

        #expect(guardState.hasPresented(
            key: notification.key,
            fingerprint: identity.fingerprint
        ))
    }

    @Test func newContentAfterDismissalIsStillPresented() {
        let seen = sampleNotification()
        let fresh = sampleNotification(body: "A later message")
        var guardState = NotificationReplayGuard()

        guardState.recordPresented(
            key: seen.key,
            fingerprint: NotificationPresentationIdentity(seen).fingerprint
        )
        guardState.clear(key: seen.key)

        #expect(!guardState.hasPresented(
            key: fresh.key,
            fingerprint: NotificationPresentationIdentity(fresh).fingerprint
        ))
    }

    @Test func withdrawalLetsIdenticalContentRingAgain() {
        // Gone from the phone means a later identical notification really is new.
        let notification = sampleNotification()
        let identity = NotificationPresentationIdentity(notification)
        var guardState = NotificationReplayGuard()

        guardState.recordPresented(key: notification.key, fingerprint: identity.fingerprint)
        guardState.forget(key: notification.key)

        #expect(!guardState.hasPresented(
            key: notification.key,
            fingerprint: identity.fingerprint
        ))
        #expect(guardState.reserve(
            key: notification.key,
            fingerprint: identity.fingerprint
        ) != nil)
    }

    @Test func presentationHistoryIsBounded() {
        var guardState = NotificationReplayGuard()
        let oldest = sampleNotification(key: "chat.0")
        guardState.recordPresented(
            key: oldest.key,
            fingerprint: NotificationPresentationIdentity(oldest).fingerprint
        )
        for index in 1...250 {
            let n = sampleNotification(key: "chat.\(index)")
            guardState.recordPresented(
                key: n.key,
                fingerprint: NotificationPresentationIdentity(n).fingerprint
            )
        }

        #expect(!guardState.hasPresented(
            key: oldest.key,
            fingerprint: NotificationPresentationIdentity(oldest).fingerprint
        ))
        let newest = sampleNotification(key: "chat.250")
        #expect(guardState.hasPresented(
            key: newest.key,
            fingerprint: NotificationPresentationIdentity(newest).fingerprint
        ))
    }

    // MARK: - Card text

    @Test func oneToOneChatLeadsWithTheSender() {
        // The complaint this fixes: "Deema / WhatsApp / Hello". The app icon is the
        // thumbnail, so the label has no business between the contact and the message.
        let card = NotificationCardText(
            sampleNotification(title: "Deema", senderName: "Deema", conversationTitle: "Deema")
        )

        #expect(card.title == "Deema")
        #expect(card.subtitle == "")
        #expect(card.body == "Hello")
    }

    @Test func groupChatKeepsTheChatNameAsSubtitle() {
        // WhatsApp titles a group card with the group, so the sender only survives in
        // MessagingStyle. Whoever spoke leads; the chat they spoke in follows.
        let card = NotificationCardText(
            sampleNotification(title: "Family", senderName: "Deema", conversationTitle: "Family")
        )

        #expect(card.title == "Deema")
        #expect(card.subtitle == "Family")
    }

    @Test func nonMessagingNotificationKeepsItsOwnTitle() {
        let card = NotificationCardText(sampleNotification(title: "Standup in 10 minutes"))

        #expect(card.title == "Standup in 10 minutes")
        #expect(card.subtitle == "")
    }

    @Test func titlelessNotificationFallsBackToTheAppLabel() {
        // Nothing else identifies it in text, so here the label genuinely is the title.
        let card = NotificationCardText(sampleNotification(title: nil))

        #expect(card.title == "WhatsApp")
        #expect(card.subtitle == "")
    }

    @Test func blankMessagingFieldsAreTreatedAsAbsent() {
        let card = NotificationCardText(
            sampleNotification(title: "Deema", senderName: "  ", conversationTitle: "")
        )

        #expect(card.title == "Deema")
        #expect(card.subtitle == "")
    }
}

private func sampleNotification(
    key: String = "whatsapp.message.1",
    pkg: String = "com.whatsapp",
    iconHash: String? = String(repeating: "a", count: 64),
    avatarHash: String? = nil,
    title: String? = "Deema",
    body: String? = "Hello",
    whenMs: Int64 = 1,
    category: String? = "msg",
    senderName: String? = nil,
    conversationTitle: String? = nil,
    actions: [NotifAction] = [NotifAction(id: 0, label: "Reply", isReply: true)]
) -> NotifPosted {
    NotifPosted(
        key: key,
        pkg: pkg,
        appLabel: "WhatsApp",
        iconHash: iconHash,
        avatarHash: avatarHash,
        title: title,
        body: body,
        when: whenMs,
        category: category,
        senderName: senderName,
        conversationTitle: conversationTitle,
        actions: actions
    )
}
