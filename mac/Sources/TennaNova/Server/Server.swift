import Foundation
import Network

enum ServerActivity: Equatable {
    case idle
    case securing
    case authenticating
    case failed(String)

    var label: String? {
        switch self {
        case .idle:                 return nil
        case .securing:             return "Phone found — securing connection…"
        case .authenticating:       return "Phone connected — verifying pairing…"
        case .failed(let message):  return message
        }
    }

    var isAttempting: Bool {
        switch self {
        case .securing, .authenticating: return true
        case .idle, .failed:             return false
        }
    }
}

/// TLS + WebSocket listener, advertised over Bonjour.
///
/// Design notes proven by spike (see git history / plan):
///  - `NWListener` genuinely supports `NWProtocolWebSocket` in server mode; no HTTP
///    server dependency is needed.
///  - The TLS identity is a self-signed RSA cert; Android pins its public key.
final class Server {

    private let queue = DispatchQueue(label: "com.tennanova.server")
    private var listener: NWListener?
    private let identity: TLSIdentity.Loaded

    /// The authenticated connection. New TCP/TLS peers remain candidates until AppState
    /// validates their hello, so a port probe or a second Mac cannot knock this one off.
    private(set) var session: PeerSession?
    /// The one video-only peer. It is authenticated separately and never becomes primary.
    private(set) var mirrorSession: PeerSession?
    private var peers: [UUID: PeerSession] = [:]
    private var activityPeerID: UUID?
    private var activity: ServerActivity = .idle
    private var activityVersion = 0

    var onSessionChanged: ((PeerSession?) -> Void)?
    var onMirrorSessionChanged: ((PeerSession?) -> Void)?
    var onActivityChanged: ((ServerActivity) -> Void)?
    var onMessage: ((PeerSession, Envelope, Data) -> Void)?
    var onBinary: ((PeerSession, Data) -> Void)?

    var spkiHash: String { identity.spkiHash }
    private(set) var port: UInt16 = Proto.defaultPort

    init() throws {
        self.identity = try TLSIdentity.loadOrCreate()
    }

    func start(port desired: UInt16 = Proto.defaultPort) throws {
        let params = Self.makeParameters(identity: identity.secIdentity)
        guard let nwPort = NWEndpoint.Port(rawValue: desired) else {
            throw TLSError.message("invalid port \(desired)")
        }

        let listener = try NWListener(using: params, on: nwPort)
        self.port = desired

        // Advertise on the LAN so the phone can find us without a hardcoded IP.
        let txt = NetService.data(fromTXTRecord: [
            "spki": Data(identity.spkiHash.utf8)
        ])
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Tennanova Mac",
            type: Proto.bonjourType,
            txtRecord: txt
        )

        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.info("listening on port \(desired), advertising \(Proto.bonjourType)")
            case .failed(let err):
                Log.error("listener failed: \(err.localizedDescription)")
            default:
                break
            }
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        peers.values.forEach { $0.close() }
        peers.removeAll()
        session = nil
        mirrorSession = nil
        activityPeerID = nil
        emitActivity(.idle)
        listener?.cancel()
        listener = nil
    }

    /// Makes an authenticated candidate current, then retires the previous connection.
    /// Called from AppState on the server queue after a valid hello.
    func activate(_ peer: PeerSession) {
        guard peers[peer.id] != nil else { return }
        let previous = session
        session = peer
        activityPeerID = nil
        emitActivity(.idle)
        onSessionChanged?(peer)
        if previous?.id != peer.id { previous?.close() }
    }

    /// Retains a separately authenticated video peer without replacing control traffic.
    func activateMirror(_ peer: PeerSession) {
        guard peers[peer.id] != nil else { return }
        let previous = mirrorSession
        mirrorSession = peer
        if activityPeerID == peer.id {
            activityPeerID = nil
            emitActivity(.idle)
        }
        onMirrorSessionChanged?(peer)
        if previous?.id != peer.id { previous?.close() }
    }

    func closeMirror() {
        mirrorSession?.close()
        mirrorSession = nil
        onMirrorSessionChanged?(nil)
    }

    /// Preserves the reason long enough for the menu to explain a rejected scan.
    func noteAuthenticationFailure(_ peer: PeerSession, message: String) {
        guard activityPeerID == peer.id else { return }
        emitActivity(.failed(message), clearAfter: 12)
    }

    // MARK: - Internals

    private static func makeParameters(identity: sec_identity_t) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let params = NWParameters(tls: tls)
        params.includePeerToPeer = true

        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    private func accept(_ conn: NWConnection) {
        // The handshake starts inside `peer.start()` below, and it is the only thing that
        // needs the private key. A keychain that has locked itself since launch makes that
        // handshake fail before a byte reaches the phone, so this is the moment to check.
        TLSIdentity.ensureUnlocked()

        let peer = PeerSession(connection: conn, queue: queue)
        let peerID = peer.id
        peers[peerID] = peer
        activityPeerID = peerID
        emitActivity(.securing)
        peer.onMessage = { [weak self, weak peer] env, data in
            guard let self, let peer else { return }
            self.onMessage?(peer, env, data)
        }
        peer.onBinary = { [weak self, weak peer] data in
            guard let self, let peer else { return }
            self.onBinary?(peer, data)
        }
        peer.onReady = { [weak self] in
            guard let self, self.activityPeerID == peerID else { return }
            self.emitActivity(.authenticating)
        }
        peer.onClosed = { [weak self] error in
            guard let self else { return }
            self.peers.removeValue(forKey: peerID)
            // A rejected or failed candidate never disturbs the authenticated session.
            if self.session?.id == peerID {
                self.session = nil
                self.emitActivity(.idle)
                self.onSessionChanged?(nil)
            } else if self.mirrorSession?.id == peerID {
                self.mirrorSession = nil
                self.onMirrorSessionChanged?(nil)
            } else if self.activityPeerID == peerID {
                self.activityPeerID = nil
                if case .failed = self.activity {
                    // AppState already supplied the useful authentication reason.
                } else {
                    self.emitActivity(.failed(Self.explain(error)), clearAfter: 12)
                }
            }
        }
        peer.start()
    }

    /// Turns a dropped candidate into something a person can act on.
    ///
    /// `NWError` renders a TLS failure as "handshake failed" and a bare number, which says
    /// nothing about which side refused or what to do about it — and this is the message
    /// the menu shows when pairing does not work, so it is the one that has to be useful.
    private static func explain(_ error: Error?) -> String {
        guard let error else { return "Phone disconnected before pairing completed." }
        if let nw = error as? NWError, case .tls = nw {
            return "Couldn't secure the connection. If the phone is paired to a different "
                 + "Mac, scan the pairing code again."
        }
        return error.localizedDescription
    }

    private func emitActivity(_ next: ServerActivity, clearAfter seconds: TimeInterval? = nil) {
        activity = next
        activityVersion += 1
        let version = activityVersion
        onActivityChanged?(next)
        guard let seconds else { return }
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.activityVersion == version else { return }
            self.activity = .idle
            self.onActivityChanged?(.idle)
        }
    }
}
