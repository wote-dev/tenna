import Foundation
import Network

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
    private var peers: [UUID: PeerSession] = [:]

    var onSessionChanged: ((PeerSession?) -> Void)?
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
        listener?.cancel()
        listener = nil
    }

    /// Makes an authenticated candidate current, then retires the previous connection.
    /// Called from AppState on the server queue after a valid hello.
    func activate(_ peer: PeerSession) {
        guard peers[peer.id] != nil else { return }
        let previous = session
        session = peer
        onSessionChanged?(peer)
        if previous?.id != peer.id { previous?.close() }
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
        let peer = PeerSession(connection: conn, queue: queue)
        let peerID = peer.id
        peers[peerID] = peer
        peer.onMessage = { [weak self, weak peer] env, data in
            guard let self, let peer else { return }
            self.onMessage?(peer, env, data)
        }
        peer.onBinary = { [weak self, weak peer] data in
            guard let self, let peer else { return }
            self.onBinary?(peer, data)
        }
        peer.onClosed = { [weak self] _ in
            guard let self else { return }
            self.peers.removeValue(forKey: peerID)
            // A rejected or failed candidate never disturbs the authenticated session.
            if self.session?.id == peerID {
                self.session = nil
                self.onSessionChanged?(nil)
            }
        }
        peer.start()
    }
}
