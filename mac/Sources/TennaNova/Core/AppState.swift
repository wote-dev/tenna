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
    private(set) var pairedDevice: DeviceInfo?
    private(set) var battery: Int?
    private(set) var charging: Bool = false
    private(set) var lastTransferStatus: String?
    private(set) var usbStatus: USBBridgeStatus = .searching

    /// Shown as a QR until the phone pairs. Regenerated each launch while unpaired.
    private(set) var pairingPayload: String = ""

    /// Every address the phone is currently told to try, best first.
    private(set) var advertisedHosts: [String] = []

    @ObservationIgnored private var server: Server?
    @ObservationIgnored private var notifications: NotificationPresenter?
    @ObservationIgnored private var clipboard: PasteboardBridge?
    @ObservationIgnored private let usbBridge = ADBBridge()
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let pathQueue = DispatchQueue(label: "com.tennanova.path")
    @ObservationIgnored private let store = PairingStore()
    @ObservationIgnored private var authenticatedSessionID: UUID?
    @ObservationIgnored private var peerCapabilities = Set<String>()
    @ObservationIgnored private var pendingBinary: PendingBinary?

    private enum PendingBinary {
        case icon(sessionID: UUID, hash: String, bytes: Int)
        case image(sessionID: UUID, header: ClipImage)
    }

    func start() {
        do {
            let server = try Server()
            self.server = server

            let presenter = NotificationPresenter()
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
                Task { @MainActor in
                    guard let self else { return }
                    if session == nil {
                        self.authenticatedSessionID = nil
                        self.peerCapabilities.removeAll()
                        self.pendingBinary = nil
                        self.clipboard?.setPeerSupportsImages(false)
                        self.status = .waitingForPhone
                        self.pairedDevice = nil
                    }
                }
            }
            server.onMessage = { [weak self] session, env, data in
                self?.handle(env: env, data: data, session: session)
            }
            server.onBinary = { [weak self] session, data in
                self?.handleBinary(data, session: session)
            }

            try server.start()
            usbBridge.onStatus = { [weak self] status in
                Task { @MainActor in self?.usbStatus = status }
            }
            usbBridge.start(port: Int(server.port))
            rebuildPairingPayload(
                spki: server.spkiHash,
                port: server.port,
                usbPort: usbBridge.isAvailable ? Int(server.port) : nil
            )
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
        pathMonitor.cancel()
        usbBridge.stop()
        clipboard?.stop()
        server?.stop()
    }

    /// Forgets the paired phone so a new one can be paired.
    func unpair() {
        store.clear()
        store.rotatePairingToken()
        if let server {
            rebuildPairingPayload(
                spki: server.spkiHash,
                port: server.port,
                usbPort: usbBridge.isAvailable ? Int(server.port) : nil
            )
        }
        server?.session?.close()
        pairedDevice = nil
        status = .waitingForPhone
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
                notifications?.present(m)
            }

        case "notif.removed":
            if let m = try? Wire.decode(NotifRemoved.self, from: data) {
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
            session.send(HelloNack(reason: "bad_hello"))
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
            session.send(HelloNack(reason: "bad_token"))
            session.close()
            return
        }

        authenticatedSessionID = session.id
        peerCapabilities = Set(hello.capabilities ?? [])
        pendingBinary = nil
        clipboard?.setPeerSupportsImages(
            peerCapabilities.contains(Proto.imageClipboardCapability)
        )

        session.send(HelloAck(
            deviceToken: issued,
            macName: Host.current().localizedName ?? "Mac",
            hosts: advertisedHosts,
            port: Int(server?.port ?? Proto.defaultPort)
        ))

        Task { @MainActor in
            self.pairedDevice = hello.device
            self.battery = hello.device.battery
            self.status = .connected(deviceName: hello.device.name)
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

    private func send<T: Encodable>(_ message: T) {
        guard let session = server?.session,
              authenticatedSessionID == session.id else { return }
        session.send(message)
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
        guard let server else { return }
        let before = advertisedHosts
        rebuildPairingPayload(
            spki: server.spkiHash,
            port: server.port,
            usbPort: usbBridge.isAvailable ? Int(server.port) : nil
        )
        guard advertisedHosts != before else { return }
        Log.info("reachable on \(advertisedHosts.isEmpty ? "no address" : advertisedHosts.joined(separator: ", "))")
        send(MacHosts(hosts: advertisedHosts, port: Int(server.port)))
    }

    private func rebuildPairingPayload(spki: String, port: UInt16, usbPort: Int?) {
        advertisedHosts = NetworkInterface.allIPv4()
        // `host` stays the single best guess so an older phone build still pairs; `hosts`
        // is the additive list every current build actually walks.
        var payload: [String: Any] = [
            "v": Proto.version,
            "host": advertisedHosts.first ?? "0.0.0.0",
            "hosts": advertisedHosts,
            "port": Int(port),
            "spki": spki,
            "token": store.pairingToken
        ]
        if let usbPort { payload["usbPort"] = usbPort }
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            pairingPayload = str
        }
    }

}
