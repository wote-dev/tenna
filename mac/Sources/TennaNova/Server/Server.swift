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

    /// Only one phone is paired at a time in v1, but the listener tolerates a
    /// replacement connection (e.g. after the phone's network flapped).
    private(set) var session: PeerSession?

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
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Tennanova Mac",
            type: Proto.bonjourType
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
        session?.close()
        listener?.cancel()
        listener = nil
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
        // A new connection supersedes the old one — the phone reconnecting after a
        // network change would otherwise leave a zombie session behind.
        if let existing = session {
            Log.info("replacing existing session")
            existing.close()
        }

        let peer = PeerSession(connection: conn, queue: queue)
        peer.onMessage = { [weak self, weak peer] env, data in
            guard let self, let peer else { return }
            self.onMessage?(peer, env, data)
        }
        peer.onBinary = { [weak self, weak peer] data in
            guard let self, let peer else { return }
            self.onBinary?(peer, data)
        }
        peer.onClosed = { [weak self, weak peer] _ in
            guard let self else { return }
            // Only clear if this is still the current session.
            if self.session?.id == peer?.id {
                self.session = nil
                self.onSessionChanged?(nil)
            }
        }
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.onSessionChanged?(peer)
        }

        session = peer
        peer.start()
    }
}
