import Foundation
import Network
import Observation

enum ConnectionStatus: Equatable {
    case starting
    case waitingForPhone
    case connected(deviceName: String)
    case failed(String)

    var label: String {
        switch self {
        case .starting:            return "Starting…"
        case .waitingForPhone:     return "Waiting for phone"
        case .connected(let name): return "Connected — \(name)"
        case .failed(let msg):     return "Error: \(msg)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Central coordinator: owns the server, routes protocol messages to the
/// notification and clipboard subsystems, and holds the state the UI renders.
@Observable
final class AppState {

    private(set) var status: ConnectionStatus = .starting
    private(set) var serverActivity: ServerActivity = .idle
    private(set) var pairedDevice: DeviceInfo?
    private(set) var battery: Int?
    private(set) var charging: Bool = false
    private(set) var lastTransferStatus: String?
    private(set) var usbStatus: USBBridgeStatus = .searching
    private(set) var relayStatus: RelayStatus = .disabled

    /// Whether a phone is paired at all. Distinct from `pairedDevice`, which is cleared
    /// on every disconnect — this is what lets the menu bar offer Unpair while offline.
    private(set) var isPaired: Bool = false

    /// The paired phone's name, surviving disconnect. `pairedDevice` does not, so without
    /// this the menu bar cannot say *which* phone it is waiting for.
    private(set) var pairedDeviceName: String?

    /// Shown as a QR until the phone pairs. Regenerated each launch while unpaired.
    private(set) var pairingPayload: String = ""

    /// Every address the phone is currently told to try, best first.
    private(set) var advertisedHosts: [String] = []

    /// Main-thread mirror of `peerCapabilities`, which lives on the server queue and must
    /// not be read from the UI. Lets a view grey out what this phone build cannot do.
    private(set) var capabilities: Set<String> = []

    var supportsImageClipboard: Bool { capabilities.contains(Proto.imageClipboardCapability) }

    /// Whether this phone can still reply to a conversation it is no longer showing.
    /// Almost every mirrored chat is in that state within moments of arriving, so this is
    /// what decides whether the window's composer is offered at all.
    var supportsOfflineReply: Bool { capabilities.contains(Proto.offlineReplyCapability) }

    /// Whether this phone is mirroring its SMS store. False also means "switched off or
    /// not permitted on the phone", which is why the window points at the phone's own
    /// toggle rather than offering to fix anything itself.
    var supportsSms: Bool { capabilities.contains(Proto.smsCapability) }

    /// Whether this phone mirrors calls at all. False means an older phone build or a
    /// user who has switched calls off there — either way the Calls pane says so rather
    /// than sitting permanently empty with no explanation.
    var supportsCalls: Bool { capabilities.contains(Proto.callCapability) }

    /// Everything the phone has mirrored, grouped into conversations.
    let history = NotificationStore()

    /// Calls, which are deliberately not conversations. See `MirroredCall`.
    let calls = CallCenter()

    /// App icons and contact photos, in a form the window can draw and observe.
    let icons: IconCatalog

    @ObservationIgnored private var server: Server?
    @ObservationIgnored private var notifications: NotificationPresenter?
    @ObservationIgnored private var clipboard: PasteboardBridge?
    @ObservationIgnored private let usbBridge = ADBBridge()
    @ObservationIgnored private var relayBridge: RelayBridge?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let pathQueue = DispatchQueue(label: "com.tennanova.path")
    @ObservationIgnored private let store = PairingStore()
    @ObservationIgnored private var authenticatedSessionID: UUID?
    @ObservationIgnored private var peerCapabilities = Set<String>()
    @ObservationIgnored private var pendingBinary: PendingBinary?
    /// Shared with `NotificationPresenter` so the cards and the window read one store.
    @ObservationIgnored private let iconCache: IconCache
    @ObservationIgnored private var iconRequests = IconRequestPolicy()

    init(iconCache: IconCache = IconCache()) {
        self.iconCache = iconCache
        self.icons = IconCatalog(cache: iconCache)
    }

    private enum PendingBinary {
        case icon(sessionID: UUID, hash: String, bytes: Int)
        case image(sessionID: UUID, header: ClipImage)
    }

    func start() {
        do {
            let server = try Server()
            self.server = server

            let presenter = NotificationPresenter(icons: iconCache)
            presenter.onReply = { [weak self] key, actionId, text in
                self?.send(NotifReply(key: key, actionId: actionId, text: text))
            }
            presenter.onAction = { [weak self] key, actionId in
                self?.send(NotifActionInvoke(key: key, actionId: actionId))
            }
            presenter.onDismissed = { [weak self] key in
                self?.send(NotifDismiss(key: key))
            }
            presenter.onIconNeeded = { [weak self] hash in
                self?.send(IconRequest(hash: hash))
            }
            presenter.onCallAction = { [weak self] callId, action in
                Task { @MainActor in self?.perform(action, onCallId: callId) }
            }
            self.notifications = presenter

            let clip = PasteboardBridge()
            clip.onLocalCopy = { [weak self] payload, seq in
                guard let self else { return }
                switch payload {
                case .text(let text):
                    self.send(ClipUpdate(body: text, origin: "mac", seq: seq))
                case .image(let data, let mime, let hash, let name):
                    self.sendImage(data: data, mime: mime, sha256: hash,
                                   name: name, seq: seq)
                }
            }
            clip.onTransferStatus = { [weak self] message in
                Task { @MainActor in self?.lastTransferStatus = message }
            }
            self.clipboard = clip

            server.onSessionChanged = { [weak self] session in
                guard let self, session == nil else { return }
                // Server-queue state, cleared on the server queue. Doing this inside the
                // MainActor hop below raced every read of it in `handle`, which runs on
                // that same server queue.
                self.authenticatedSessionID = nil
                self.peerCapabilities.removeAll()
                self.pendingBinary = nil
                self.iconRequests.reset()
                self.clipboard?.setPeerSupportsImages(false)
                // A call this Mac can no longer act on must not keep a live card on
                // screen: every button on it would now go nowhere.
                self.calls.dropLiveCalls()
                Task { @MainActor in
                    self.capabilities = []
                    self.status = .waitingForPhone
                    self.pairedDevice = nil
                }
            }
            server.onActivityChanged = { [weak self] activity in
                Task { @MainActor in self?.serverActivity = activity }
            }
            server.onMessage = { [weak self] session, env, data in
                self?.handle(env: env, data: data, session: session)
            }
            server.onBinary = { [weak self] session, data in
                self?.handleBinary(data, session: session)
            }

            try server.start()
            usbBridge.onStatus = { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    let wasReady = self.usbStatus.isReady
                    self.usbStatus = status
                    // The QR only advertises usbPort while the tunnel is genuinely up,
                    // so it has to be rebuilt when that changes in either direction — and
                    // a phone that is already connected over LAN is told too, so plugging
                    // in starts working without anyone rescanning anything.
                    if wasReady != status.isReady {
                        self.rebuildPairingPayload()
                        self.sendHostsUpdate()
                    }
                }
            }
            usbBridge.start(port: Int(server.port))

            // The relay's room name belongs in the QR, and a relay that comes up later
            // has to reach phones that are already paired — hence the payload rebuild
            // and the mid-session address update, exactly as USB does above.
            let relay = RelayBridge(secret: store.relaySecret)
            relay.onStatus = { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    let wasOnline = self.relayStatus.isOnline
                    self.relayStatus = status
                    if wasOnline != status.isOnline {
                        self.rebuildPairingPayload()
                        self.sendHostsUpdate()
                    }
                }
            }
            self.relayBridge = relay
            relay.start(localPort: server.port)
            // Same queue every ingest hops through, so the restore cannot land on top of
            // a message that arrived first. Off the launch path because it reads a file.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.icons.warm(self.history.restore())
                }
            }

            isPaired = store.paired != nil
            pairedDeviceName = store.paired?.name
            rebuildPairingPayload()
            startPathMonitor()
            status = .waitingForPhone
            presenter.requestAuthorization()
            clip.start()
        } catch {
            Log.error("failed to start: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        // Called from `applicationWillTerminate`, i.e. the main thread, and there is no
        // "in two seconds" left to debounce into.
        MainActor.assumeIsolated { history.flush() }
        pathMonitor.cancel()
        usbBridge.stop()
        relayBridge?.stop()
        clipboard?.stop()
        server?.stop()
    }

    /// Forgets the paired phone so a new one can be paired.
    func unpair() {
        store.clear()
        store.rotatePairingToken()
        rebuildPairingPayload()
        server?.session?.close()
        isPaired = false
        pairedDeviceName = nil
        pairedDevice = nil
        status = .waitingForPhone
        // A different phone's conversations must not survive into the next pairing.
        history.clearAll()
        calls.clearAll()
        icons.clearAll()
    }

    // MARK: - Message routing

    private func handle(env: Envelope, data: Data, session: PeerSession) {
        if env.type != "hello", authenticatedSessionID != session.id {
            Log.warn("closing peer that sent \(env.type) before authentication")
            session.close()
            return
        }

        switch env.type {
        case "hello":
            handleHello(data: data, session: session)

        case "device.state":
            if let m = try? Wire.decode(DeviceState.self, from: data) {
                Task { @MainActor in
                    if let b = m.battery { self.battery = b }
                    self.charging = m.charging ?? false
                }
            }

        case "notif.posted":
            if let m = try? Wire.decode(NotifPosted.self, from: data) {
                // The store ingests even when the presenter suppresses a resync replay —
                // that is exactly what repopulates a Mac that restarted while the phone
                // stayed connected.
                history.ingest(m)
                requestAssets(for: m)
                notifications?.present(m)
            }

        case "call.state":
            if let m = try? Wire.decode(CallStateMessage.self, from: data) {
                requestAssets(iconHash: m.iconHash, avatarHash: m.avatarHash)
                calls.apply(m) { [weak self] change in
                    self?.present(change)
                }
            }

        case "call.action.result":
            if let m = try? Wire.decode(CallActionResult.self, from: data) {
                guard !m.ok, let error = m.error else { return }
                Log.warn("phone refused \(m.action) on a call: \(error)")
                Task { @MainActor in self.calls.noteFailure(m.id, error) }
            }

        case "notif.removed":
            if let m = try? Wire.decode(NotifRemoved.self, from: data) {
                // Withdraw the card, keep the transcript.
                history.markRemovedOnPhone(key: m.key)
                notifications?.withdraw(key: m.key)
            }

        case "icon.data":
            if let m = try? Wire.decode(IconData.self, from: data) {
                guard m.hasValidMetadata, pendingBinary == nil else {
                    Log.warn("rejected invalid icon.data header")
                    session.close()
                    return
                }
                pendingBinary = .icon(sessionID: session.id, hash: m.hash, bytes: m.bytes)
            }

        case "sms.threads":
            if let m = try? Wire.decode(SmsThreads.self, from: data) {
                Log.info("phone mirrored \(m.threads.count) SMS conversation(s)")
                history.applySmsThreads(m.threads)
            }

        case "sms.messages":
            if let m = try? Wire.decode(SmsMessages.self, from: data) {
                history.applySmsMessages(threadId: m.threadId, messages: m.messages)
            }

        case "sms.received":
            if let m = try? Wire.decode(SmsReceived.self, from: data) {
                history.ingest(m.message)
            }

        case "sms.send.result":
            if let m = try? Wire.decode(SmsSendResult.self, from: data) {
                if let error = m.error, !m.ok {
                    Log.warn("phone could not send an SMS: \(error)")
                }
                if let id = UUID(uuidString: m.clientId) {
                    history.applyReplyResult(id, ok: m.ok, error: m.error)
                }
            }

        case "notif.reply.keys":
            if let m = try? Wire.decode(NotifReplyKeys.self, from: data) {
                Log.info("phone can reply to \(m.keys.count) conversation(s)")
                history.applyReplyableKeys(Set(m.keys))
            }

        case "notif.reply.result":
            if let m = try? Wire.decode(NotifReplyResult.self, from: data) {
                if let error = m.error, !m.ok {
                    Log.warn("phone refused reply on \(m.key): \(error)")
                }
                // No clientId means an older Mac sent the reply, which cannot happen here
                // — but a malformed one must not take the message down with it.
                if let raw = m.clientId, let id = UUID(uuidString: raw) {
                    history.applyReplyResult(id, ok: m.ok, error: m.error)
                }
            }

        case "clip.update":
            if let m = try? Wire.decode(ClipUpdate.self, from: data) {
                clipboard?.applyRemote(text: m.body, seq: m.seq)
            }

        case "clip.image":
            guard peerCapabilities.contains(Proto.imageClipboardCapability),
                  let m = try? Wire.decode(ClipImage.self, from: data),
                  m.hasValidMetadata(expectedOrigin: "android"), pendingBinary == nil else {
                Log.warn("rejected invalid clip.image header")
                session.close()
                return
            }
            pendingBinary = .image(sessionID: session.id, header: m)

        default:
            Log.warn("unhandled message type: \(env.type)")
        }
    }

    private func handleHello(data: Data, session: PeerSession) {
        guard let hello = try? Wire.decode(Hello.self, from: data) else {
            server?.noteAuthenticationFailure(
                session, message: "Pairing failed — the phone sent invalid pairing data."
            )
            session.send(HelloNack(reason: "bad_hello")) { session.close() }
            return
        }

        let known = store.deviceToken(for: hello.device.id)
        var issued: String?

        if let known, hello.deviceToken == known {
            // Returning device — fine.
        } else if let offered = hello.token, offered == store.pairingToken {
            // First pair: mint a long-lived token and burn the pairing token.
            issued = TLSIdentity.randomToken()
            store.save(deviceId: hello.device.id, name: hello.device.name, token: issued!)
            store.rotatePairingToken()
            // A newly paired phone has none of our clipboard history.
            clipboard?.resetPeerState()
            Log.info("paired with \(hello.device.name)")
        } else {
            Log.warn("rejecting \(hello.device.name): bad token")
            server?.noteAuthenticationFailure(
                session,
                message: "Pairing rejected — scan the current code shown by this Mac."
            )
            session.send(HelloNack(reason: "bad_token")) { session.close() }
            return
        }

        authenticatedSessionID = session.id
        server?.activate(session)
        let caps = Set(hello.capabilities ?? [])
        peerCapabilities = caps
        pendingBinary = nil
        clipboard?.setPeerSupportsImages(
            peerCapabilities.contains(Proto.imageClipboardCapability)
        )

        let macPort = Int(server?.port ?? Proto.defaultPort)
        session.send(HelloAck(
            deviceToken: issued,
            macName: Host.current().localizedName ?? "Mac",
            hosts: advertisedHosts,
            port: macPort,
            usbPort: usbStatus.isReady ? macPort : nil,
            relayHost: relayHostIfOnline,
            relayRoom: relayRoomIfOnline
        ))

        let didPair = issued != nil
        Task { @MainActor in
            self.pairedDevice = hello.device
            self.battery = hello.device.battery
            self.status = .connected(deviceName: hello.device.name)
            self.isPaired = true
            self.pairedDeviceName = hello.device.name
            self.capabilities = caps
            // The pairing token was just spent and rotated. Without rebuilding here the
            // menu bar keeps rendering a QR for the dead one, and the next scan — which
            // is exactly what a user does when the phone drops — fails with bad_token.
            if didPair { self.rebuildPairingPayload() }
        }

        // Push our current clipboard so the phone starts in sync.
        clipboard?.sendCurrentIfAny()
    }

    private func handleBinary(_ data: Data, session: PeerSession) {
        guard authenticatedSessionID == session.id, let pending = pendingBinary else {
            Log.warn("received binary data with no authenticated header")
            return
        }
        pendingBinary = nil

        switch pending {
        case .icon(let sessionID, let hash, let bytes):
            guard sessionID == session.id, data.count == bytes,
                  PasteboardBridge.sha256(data) == hash else {
                Log.warn("icon binary validation failed")
                return
            }
            notifications?.receiveIconBytes(data, hash: hash)
            // The hash starts fresh if it is ever needed again, and the window is told so
            // rows holding this icon or avatar can redraw.
            iconRequests.received(hash)
            icons.received(data, hash: hash)

        case .image(let sessionID, let header):
            guard sessionID == session.id, data.count == header.bytes,
                  PasteboardBridge.sha256(data) == header.sha256 else {
                Log.warn("clipboard image binary validation failed")
                Task { @MainActor in self.lastTransferStatus = "Rejected invalid image from phone" }
                return
            }
            clipboard?.applyRemoteImage(data: data, mime: header.mime,
                                        sha256: header.sha256, name: header.name)
        }
    }

    /// Returns false when there is no authenticated session, so a caller that owes the
    /// user feedback — a reply typed into the window — can say so instead of dropping it.
    // MARK: - Actions from the window

    /// Sends a reply into a conversation and echoes it into the transcript immediately.
    ///
    /// `.sent` is set once the frame reaches the socket. A phone advertising
    /// `notif.reply.offline.v1` then answers with `notif.reply.result`, which is the only
    /// thing that can report a *failure* — before it, a reply the phone could not deliver
    /// sat at "Sent" forever. Success still does not earn `.confirmed`: firing the intent
    /// is not the app accepting it, and only the phone mirroring the message back is.
    @MainActor
    func reply(to conversation: ConversationKey, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        // SMS goes out through the phone's radio, not through a notification's action.
        if case .sms = conversation {
            sendSms(body, to: conversation)
            return
        }

        guard let target = history.replyTarget(for: conversation,
                                               allowingWithdrawn: supportsOfflineReply)
        else { return }
        guard let id = history.appendOutgoing(body, to: conversation) else { return }

        let queued = send(
            NotifReply(key: target.key, actionId: target.actionId, text: body,
                       clientId: id.uuidString)
        ) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.history.markDelivery(id, .sent) }
            }
        }
        if !queued { history.markDelivery(id, .failed("Phone not connected")) }
    }

    /// Sends a text, and puts it in the transcript before the phone has confirmed it.
    ///
    /// `.confirmed` is genuinely earned here, unlike a notification reply: the provider
    /// row the phone writes comes back through `sms.received` and reconciles the bubble.
    @MainActor
    private func sendSms(_ body: String, to conversation: ConversationKey) {
        guard let address = history.log[conversation]?.smsAddress else { return }
        guard let id = history.appendOutgoing(body, to: conversation) else { return }

        let queued = send(
            SmsSend(address: address, body: body, clientId: id.uuidString)
        ) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.history.markDelivery(id, .sent) }
            }
        }
        if !queued { history.markDelivery(id, .failed("Phone not connected")) }
    }

    /// Asks the phone for a thread's history. Called when a conversation is opened, and
    /// again with `beforeId` to page further back.
    @MainActor
    func loadSmsThread(_ conversation: ConversationKey, beforeId: Int64? = nil) {
        guard case let .sms(threadId) = conversation, threadId > 0 else { return }
        send(SmsThreadRequest(threadId: threadId, beforeId: beforeId, limit: 100))
    }

    /// Starts a conversation with a number that has none yet.
    @MainActor
    func startSmsConversation(address: String) -> ConversationKey? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsSms, !trimmed.isEmpty else { return nil }
        return history.draftSmsThread(address: trimmed, title: trimmed)
    }

    /// Presses one of the notification's own non-reply buttons — "Mark as read", "Archive".
    @MainActor
    func invoke(action: NotifAction, in conversation: ConversationKey) {
        guard let thread = history.log[conversation], let key = thread.latestKey else { return }
        send(NotifActionInvoke(key: key, actionId: action.id))
    }

    // MARK: - Calls

    /// Answers, declines or hangs up, and says so on the card when the frame could not
    /// even be sent. The phone's own verdict arrives later as `call.action.result`.
    ///
    /// **The audio does not move.** Android lets no third-party app carry voice-call audio,
    /// so this presses the phone's button from here; the sound stays on the phone or on
    /// whatever headset the phone is already using. Every call surface says so out loud.
    @MainActor
    func perform(_ action: CallActionKind, on call: MirroredCall) {
        perform(action, onCallId: call.id)
    }

    @MainActor
    func perform(_ action: CallActionKind, onCallId id: String) {
        let queued = send(CallActionInvoke(id: id, action: action,
                                           clientId: UUID().uuidString))
        if !queued {
            calls.noteFailure(id, "Not sent — the phone is not connected.")
        }
    }

    /// One of the dialer's own extra buttons — "Message", "Remind me". These travel on the
    /// existing `notif.action` channel, whose key is the call's id, so calls needed no
    /// second action protocol of their own.
    @MainActor
    func invoke(action: NotifAction, on call: MirroredCall) {
        send(NotifActionInvoke(key: call.id, actionId: action.id))
    }

    @MainActor
    func dismissOnPhone(_ conversation: ConversationKey) {
        guard let thread = history.log[conversation], let key = thread.latestKey else { return }
        send(NotifDismiss(key: key))
    }

    /// Rings, or stops ringing, on the strength of what the call log just decided.
    ///
    /// A card is withdrawn the moment the call stops needing an answer — whether it was
    /// answered here, answered on the phone, or given up on — because a Notification
    /// Center card offering to answer a call that is already in progress is worse than no
    /// card at all.
    @MainActor
    private func present(_ change: CallChange) {
        switch change {
        case .started(let call):
            guard call.state == .ringing else { return }
            notifications?.presentCall(call)
        case .updated(let call):
            if call.state != .ringing { notifications?.withdrawCall(id: call.id) }
        case .ended(let call):
            notifications?.withdrawCall(id: call.id)
        case .ignored:
            break
        }
    }

    /// Asks the phone for any PNG this notification references that we do not already have.
    ///
    /// Both hashes, not just the icon: the window shows sender photos, and `avatarHash` has
    /// travelled on the wire since the beginning without anyone ever requesting it.
    private func requestAssets(for n: NotifPosted) {
        requestAssets(iconHash: n.iconHash, avatarHash: n.avatarHash)
    }

    /// Shared with calls, whose card is drawn from the same two pictures.
    private func requestAssets(iconHash: String?, avatarHash: String?) {
        // Already on disk from an earlier session or an earlier message: nothing to ask
        // for, but the window has not decoded it yet.
        icons.warm([iconHash, avatarHash])
        for hash in [iconHash, avatarHash].compactMap({ $0 }) where !iconCache.has(hash) {
            guard iconRequests.shouldRequest(hash) else { continue }
            send(IconRequest(hash: hash))
        }
    }

    @discardableResult
    func send<T: Encodable>(_ message: T, then: (() -> Void)? = nil) -> Bool {
        guard let session = server?.session,
              authenticatedSessionID == session.id else { return false }
        session.send(message, then: then)
        return true
    }

    private func sendImage(data: Data, mime: String, sha256: String,
                           name: String?, seq: Int) {
        guard peerCapabilities.contains(Proto.imageClipboardCapability),
              data.count <= Proto.maxImageBytes,
              let session = server?.session,
              authenticatedSessionID == session.id else { return }
        let header = ClipImage(origin: "mac", seq: seq, mime: mime,
                               bytes: data.count, sha256: sha256, name: name)
        session.sendBinary(header: header, data: data)
        Task { @MainActor in self.lastTransferStatus = "Image sent to phone" }
    }

    /// The set of addresses this Mac answers on changes whenever it joins or leaves a
    /// network — a phone hotspot included. Republishing keeps the QR honest, and while a
    /// session is live it hands the phone the new address *before* it needs it.
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.republishAddresses() }
        }
        pathMonitor.start(queue: pathQueue)
    }

    @MainActor
    private func republishAddresses() {
        guard server != nil else { return }
        let before = advertisedHosts
        rebuildPairingPayload()
        guard advertisedHosts != before else { return }
        Log.info("reachable on \(advertisedHosts.isEmpty ? "no address" : advertisedHosts.joined(separator: ", "))")
        sendHostsUpdate()
    }

    /// Hands a live session the Mac's complete account of where it can be reached.
    ///
    /// Separate from `republishAddresses` because USB readiness changes without any LAN
    /// address changing, and that early-returns on an unchanged host list.
    @MainActor
    private func sendHostsUpdate() {
        guard let server else { return }
        send(MacHosts(hosts: advertisedHosts,
                      port: Int(server.port),
                      usbPort: usbStatus.isReady ? Int(server.port) : nil,
                      relayHost: relayHostIfOnline,
                      relayRoom: relayRoomIfOnline))
    }

    private var relayHostIfOnline: String? {
        relayStatus.isOnline ? Relay.host : nil
    }

    private var relayRoomIfOnline: String? {
        relayStatus.isOnline ? relayBridge?.roomId : nil
    }

    /// Rebuilds the QR from the live server identity, addresses, token and USB state.
    ///
    /// Must be called whenever any of those change. The token in particular: it rotates
    /// the moment a pair succeeds, and a QR left showing the spent one is indistinguishable
    /// from a working one until the phone is already being rejected.
    private func rebuildPairingPayload() {
        guard let server else { return }
        advertisedHosts = NetworkInterface.allIPv4()
        // `host` stays the single best guess so an older phone build still pairs; `hosts`
        // is the additive list every current build actually walks.
        var payload: [String: Any] = [
            "v": Proto.version,
            "host": advertisedHosts.first ?? "0.0.0.0",
            "hosts": advertisedHosts,
            "port": Int(server.port),
            "spki": server.spkiHash,
            "token": store.pairingToken
        ]
        // Only while the reverse tunnel is actually up. `usbBridge.isAvailable` just means
        // the adb binary is bundled, so it stayed true with no phone attached — and the
        // phone then spent its first connection attempt on a loopback port nothing served.
        if usbStatus.isReady { payload["usbPort"] = Int(server.port) }
        // Only while the relay has actually accepted us. Advertising a room no Mac is
        // hosting would cost the phone a doomed round trip on every reconnect.
        if let host = relayHostIfOnline, let room = relayRoomIfOnline {
            payload["relayHost"] = host
            payload["relayRoom"] = room
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            pairingPayload = str
        }
    }

}
