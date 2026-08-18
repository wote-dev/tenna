import Foundation
import CryptoKit
import UserNotifications

/// The stable, visible identity of a mirrored notification. Android can post the same
/// StatusBarNotification repeatedly (especially after a reconnect), so its opaque key
/// alone is not enough to decide whether the user should be alerted again.
struct NotificationPresentationIdentity: Equatable {
    static let fingerprintUserInfoKey = "tenna.presentationFingerprint.v1"

    let threadIdentifier: String
    let fingerprint: String

    init(_ notification: NotifPosted) {
        // Cards from one chat share a thread so macOS stacks them the way it stacks its
        // own conversations. Everything else keeps a thread of its own — otherwise macOS
        // would collapse every notification from the same Android package into one pile.
        // Reposts still share a request identifier and are handled by the replay guard.
        if let conversation = notification.conversationTitle, !conversation.isEmpty {
            threadIdentifier = "\(notification.pkg)#\(conversation)"
        } else {
            threadIdentifier = notification.key
        }

        // `avatarHash` is deliberately absent: a contact photo that arrives after the
        // first card must not change the identity, or the next post would re-alert.
        let payload = FingerprintPayload(
            pkg: notification.pkg,
            appLabel: notification.appLabel,
            iconHash: notification.iconHash,
            title: notification.title,
            body: notification.body,
            category: notification.category,
            senderName: notification.senderName,
            actions: notification.actions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        // All fields in FingerprintPayload are directly JSON-encodable. If that ever
        // changes, a one-off identity is safer than accidentally suppressing an alert.
        guard let data = try? encoder.encode(payload) else {
            fingerprint = UUID().uuidString
            return
        }
        fingerprint = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct FingerprintPayload: Encodable {
        let pkg: String
        let appLabel: String
        let iconHash: String?
        let title: String?
        let body: String?
        let category: String?
        let senderName: String?
        let actions: [NotifAction]
    }
}

/// The text macOS actually draws for a mirrored card.
///
/// The app label deliberately does not sit between the sender and the message: the
/// attachment thumbnail is the app icon, so the name would only be repeating what the
/// picture already says. It survives as the title only when nothing better exists.
struct NotificationCardText: Equatable {
    let title: String
    let subtitle: String
    let body: String

    init(_ n: NotifPosted) {
        let sender = Self.clean(n.senderName)
        let ownTitle = Self.clean(n.title)
        title = sender ?? ownTitle ?? n.appLabel

        // Only a group chat has a conversation distinct from whoever just spoke; for a
        // one-to-one chat the two are the same string and a subtitle would just echo.
        if let conversation = Self.clean(n.conversationTitle), conversation != title {
            subtitle = conversation
        } else {
            subtitle = ""
        }
        body = n.body ?? ""
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Tracks the last presentation reserved for each Android notification key. A
/// reservation is made before handing content to macOS so two identical posts cannot
/// race each other. Failed deliveries roll back to the previously delivered identity.
struct NotificationReplayGuard {
    struct Reservation {
        let key: String
        let fingerprint: String
        fileprivate let previousFingerprint: String?
    }

    private var fingerprints: [String: String] = [:]

    /// Everything presented recently, keyed by notification. Unlike `fingerprints` this
    /// survives dismissal: the phone replays all of its active notifications after every
    /// reconnect, and a card the user has already read and cleared must not ring again
    /// just because the socket flapped.
    private var presented: [String: String] = [:]
    private var presentedOrder: [String] = []
    private let presentedLimit = 200

    mutating func seed(key: String, fingerprint: String) {
        fingerprints[key] = fingerprint
        recordPresented(key: key, fingerprint: fingerprint)
    }

    mutating func recordPresented(key: String, fingerprint: String) {
        if presented.updateValue(fingerprint, forKey: key) == nil {
            presentedOrder.append(key)
        }
        while presentedOrder.count > presentedLimit {
            presented.removeValue(forKey: presentedOrder.removeFirst())
        }
    }

    func hasPresented(key: String, fingerprint: String) -> Bool {
        presented[key] == fingerprint
    }

    mutating func reserve(key: String, fingerprint: String) -> Reservation? {
        let previous = fingerprints[key]
        guard previous != fingerprint else { return nil }
        fingerprints[key] = fingerprint
        return Reservation(
            key: key,
            fingerprint: fingerprint,
            previousFingerprint: previous
        )
    }

    mutating func rollBack(_ reservation: Reservation) {
        guard fingerprints[reservation.key] == reservation.fingerprint else { return }
        if let previous = reservation.previousFingerprint {
            fingerprints[reservation.key] = previous
        } else {
            fingerprints.removeValue(forKey: reservation.key)
        }
    }

    /// The card left Notification Center. Genuinely new content for this key may show
    /// again, but the presentation history stays so replays stay quiet.
    mutating func clear(key: String) {
        fingerprints.removeValue(forKey: key)
    }

    /// The notification is gone from the phone too, so identical content arriving later
    /// really is new.
    mutating func forget(key: String) {
        fingerprints.removeValue(forKey: key)
        if presented.removeValue(forKey: key) != nil {
            presentedOrder.removeAll { $0 == key }
        }
    }
}

/// Renders mirrored Android notifications in macOS Notification Center, and reports
/// what the user does with them back to the phone.
///
/// Two macOS constraints shape this:
///  - The primary notification icon is always TennaNova's. An Android app's icon can
///    only appear as an attachment thumbnail.
///  - There is no callback for a *user-dismissed* notification — the delegate only
///    fires on click. Dismissal is therefore detected by polling.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    var onReply: ((_ key: String, _ actionId: Int, _ text: String) -> Void)?
    var onAction: ((_ key: String, _ actionId: Int) -> Void)?
    var onDismissed: ((_ key: String) -> Void)?
    var onIconNeeded: ((_ hash: String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let icons: IconCache

    /// Notifications we have shown and still believe are on screen.
    private var live = Set<String>()
    /// Keys withdrawn by the phone — so the dismissal poller doesn't echo them back.
    private var withdrawnByPhone = Set<String>()
    private var dismissTimer: Timer?

    /// Presentation events wait here until the existing Notification Center state has
    /// been loaded, and are then processed one at a time. Serial delivery makes the
    /// replay reservation and its rollback deterministic even when macOS completes
    /// notification requests asynchronously.
    private enum PresentationEvent {
        case present(NotifPosted)
        case withdraw(String)
    }
    private var presentationEvents: [PresentationEvent] = []
    private var isPresentationEventInFlight = false
    private var hasHydratedDeliveredNotifications = false
    private var replayGuard = NotificationReplayGuard()
    /// Compatibility for notifications delivered by an older build before the stable
    /// fingerprint was embedded in userInfo. This is consumed on the first replay.
    private var legacyDeliveredPresentations: [String: LegacyDeliveredPresentation] = [:]

    private struct LegacyDeliveredPresentation {
        let pkg: String?
        let title: String
        let subtitle: String
        let body: String
        let iconHash: String?
        let hasActions: Bool

        init(content: UNNotificationContent) {
            pkg = content.userInfo["pkg"] as? String
            title = content.title
            subtitle = content.subtitle
            body = content.body
            iconHash = content.attachments.first?.identifier
            hasActions = !content.categoryIdentifier.isEmpty
        }

        func matches(_ notification: NotifPosted) -> Bool {
            let iconMatches = iconHash.map { $0 == notification.iconHash } ?? true
            guard pkg == notification.pkg, iconMatches,
                  body == (notification.body ?? ""),
                  hasActions == !notification.actions.isEmpty else { return false }

            let current = NotificationCardText(notification)
            if title == current.title, subtitle == current.subtitle { return true }
            // Cards delivered before the card-text change put the app label in the
            // subtitle. Accept that layout too, or upgrading re-alerts what is on screen.
            let legacyTitle = notification.title ?? notification.appLabel
            let legacySubtitle = notification.title == nil ? "" : notification.appLabel
            return title == legacyTitle && subtitle == legacySubtitle
        }
    }

    private let lock = NSLock()

    /// The cache is injected so the presenter and the window read one store. Defaulted
    /// so the tests, which do not care, keep constructing this with no arguments.
    init(icons: IconCache = IconCache()) {
        self.icons = icons
        super.init()
        center.delegate = self
        hydrateDeliveredNotifications()
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Log.error("notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                Log.warn("notification permission denied — nothing will be shown")
            } else {
                Log.info("notification permission granted")
                DispatchQueue.main.async { self.startDismissWatcher() }
            }
        }
    }

    // MARK: - Presenting

    func present(_ n: NotifPosted) {
        enqueue(.present(n))
    }

    /// The notification went away on the phone — take it off the Mac too.
    func withdraw(key: String) {
        enqueue(.withdraw(key))
    }

    private func hydrateDeliveredNotifications() {
        center.getDeliveredNotifications { [weak self] delivered in
            guard let self else { return }

            self.lock.lock()
            for notification in delivered {
                let request = notification.request
                let content = request.content
                guard let key = content.userInfo["key"] as? String else { continue }

                self.live.insert(key)
                if let fingerprint = content.userInfo[
                    NotificationPresentationIdentity.fingerprintUserInfoKey
                ] as? String {
                    self.replayGuard.seed(key: key, fingerprint: fingerprint)
                } else {
                    self.legacyDeliveredPresentations[key] =
                        LegacyDeliveredPresentation(content: content)
                }
            }
            self.hasHydratedDeliveredNotifications = true
            self.lock.unlock()

            self.processNextPresentationEvent()
        }
    }

    private func enqueue(_ event: PresentationEvent) {
        lock.lock()
        presentationEvents.append(event)
        lock.unlock()
        processNextPresentationEvent()
    }

    private func processNextPresentationEvent() {
        lock.lock()
        guard hasHydratedDeliveredNotifications,
              !isPresentationEventInFlight,
              !presentationEvents.isEmpty else {
            lock.unlock()
            return
        }
        isPresentationEventInFlight = true
        let event = presentationEvents.removeFirst()
        lock.unlock()

        switch event {
        case .present(let notification):
            processPresent(notification)
        case .withdraw(let key):
            processWithdraw(key: key)
        }
    }

    private func finishPresentationEvent() {
        lock.lock()
        isPresentationEventInFlight = false
        lock.unlock()
        processNextPresentationEvent()
    }

    private func processPresent(_ n: NotifPosted) {
        let identity = NotificationPresentationIdentity(n)

        lock.lock()
        if legacyDeliveredPresentations.removeValue(forKey: n.key)?.matches(n) == true {
            replayGuard.seed(key: n.key, fingerprint: identity.fingerprint)
            lock.unlock()
            Log.info("suppressed legacy replay: [\(n.appLabel)] \(n.title ?? "") — \(n.body ?? "")")
            finishPresentationEvent()
            return
        }
        // A resync is the phone replaying what it still has on screen after a reconnect,
        // not news. Anything already shown once stays quiet even if the user cleared it.
        if n.resync == true,
           replayGuard.hasPresented(key: n.key, fingerprint: identity.fingerprint) {
            replayGuard.seed(key: n.key, fingerprint: identity.fingerprint)
            lock.unlock()
            Log.info("suppressed resync: [\(n.appLabel)] \(n.title ?? "") — \(n.body ?? "")")
            finishPresentationEvent()
            return
        }
        guard let reservation = replayGuard.reserve(
            key: n.key,
            fingerprint: identity.fingerprint
        ) else {
            lock.unlock()
            Log.info("suppressed duplicate: [\(n.appLabel)] \(n.title ?? "") — \(n.body ?? "")")
            finishPresentationEvent()
            return
        }
        lock.unlock()

        let card = NotificationCardText(n)
        let content = UNMutableNotificationContent()
        content.title = card.title
        content.body = card.body
        content.subtitle = card.subtitle
        content.sound = .default
        content.threadIdentifier = identity.threadIdentifier
        content.userInfo = [
            "key": n.key,
            "pkg": n.pkg,
            NotificationPresentationIdentity.fingerprintUserInfoKey: identity.fingerprint
        ]

        // The app icon is the thumbnail. macOS always draws Tennanova's own icon in the
        // header, so this square is the only place a card can say which app it came from
        // — which is what lets the app label leave the text. A missing icon is requested
        // and the card shows anyway; the bytes arrive in time for the next one.
        if let hash = n.iconHash {
            if !icons.has(hash) { onIconNeeded?(hash) }
            if let tmp = icons.temporaryCopy(of: hash),
               let att = try? UNNotificationAttachment(identifier: hash, url: tmp) {
                content.attachments = [att]
            }
        }

        if !n.actions.isEmpty {
            let categoryId = registerCategory(for: n)
            content.categoryIdentifier = categoryId
        }

        let request = UNNotificationRequest(identifier: n.key, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            guard let self else { return }

            self.lock.lock()
            if let error {
                self.replayGuard.rollBack(reservation)
                self.lock.unlock()
                Log.error("failed to show notification from \(n.appLabel): \(error.localizedDescription)")
            } else {
                self.live.insert(n.key)
                self.withdrawnByPhone.remove(n.key)
                self.replayGuard.recordPresented(
                    key: n.key,
                    fingerprint: identity.fingerprint
                )
                self.lock.unlock()
                Log.info("shown: [\(n.appLabel)] \(n.title ?? "") — \(n.body ?? "")")
            }
            self.finishPresentationEvent()
        }
    }

    private func processWithdraw(key: String) {
        lock.lock()
        live.remove(key)
        withdrawnByPhone.insert(key)
        replayGuard.forget(key: key)
        legacyDeliveredPresentations.removeValue(forKey: key)
        lock.unlock()
        center.removeDeliveredNotifications(withIdentifiers: [key])
        finishPresentationEvent()
    }

    // MARK: - Icons

    func receiveIconBytes(_ data: Data, hash: String) {
        icons.store(data, hash: hash)
        Log.info("cached icon \(hash.prefix(8)) (\(data.count) bytes)")
    }

    // MARK: - Categories

    /// macOS needs a registered category to draw action buttons. Categories are keyed by
    /// the shape of the action set, so apps with identical actions share one.
    private func registerCategory(for n: NotifPosted) -> String {
        let signature = n.actions.map { "\($0.id):\($0.isReply ? "r" : "a"):\($0.label)" }
            .joined(separator: "|")
        let categoryId = "tenna.\(abs(signature.hashValue))"

        var actions: [UNNotificationAction] = []
        for a in n.actions {
            if a.isReply {
                actions.append(UNTextInputNotificationAction(
                    identifier: "reply.\(a.id)",
                    title: a.label,
                    options: [],
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: "Reply"
                ))
            } else {
                actions.append(UNNotificationAction(
                    identifier: "action.\(a.id)",
                    title: a.label,
                    options: []
                ))
            }
        }

        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        center.getNotificationCategories { existing in
            var set = existing
            set.insert(category)
            self.center.setNotificationCategories(set)
        }
        return categoryId
    }

    // MARK: - Dismissal watching

    /// macOS never tells us the user swiped a notification away, so diff the delivered
    /// list against what we believe is live.
    private func startDismissWatcher() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkDismissals()
        }
    }

    private func checkDismissals() {
        center.getDeliveredNotifications { [weak self] delivered in
            guard let self else { return }
            let onScreen = Set(delivered.map { $0.request.identifier })

            self.lock.lock()
            let vanished = self.live.subtracting(onScreen)
            self.live.formIntersection(onScreen)
            let toReport = vanished.subtracting(self.withdrawnByPhone)
            self.withdrawnByPhone.subtract(vanished)
            for key in vanished {
                self.replayGuard.clear(key: key)
                self.legacyDeliveredPresentations.removeValue(forKey: key)
            }
            self.lock.unlock()

            for key in toReport {
                Log.info("dismissed on Mac: \(key)")
                self.onDismissed?(key)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show even when TennaNova is the frontmost app.
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.identifier
        let id = response.actionIdentifier

        if let textResponse = response as? UNTextInputNotificationResponse,
           id.hasPrefix("reply."),
           let actionId = Int(id.dropFirst("reply.".count)) {
            onReply?(key, actionId, textResponse.userText)
        } else if id.hasPrefix("action."),
                  let actionId = Int(id.dropFirst("action.".count)) {
            onAction?(key, actionId)
        } else if id == UNNotificationDismissActionIdentifier {
            lock.lock()
            live.remove(key)
            replayGuard.clear(key: key)
            legacyDeliveredPresentations.removeValue(forKey: key)
            lock.unlock()
            onDismissed?(key)
        }

        completionHandler()
    }
}
