import Foundation
import Network

enum RelayStatus: Equatable {
    case disabled
    case connecting
    case online
    case offline(String)

    var label: String {
        switch self {
        case .disabled:            return "Relay off — this Mac is LAN and USB only"
        case .connecting:          return "Reaching the relay…"
        case .online:              return "Relay ready — reachable from any network"
        case .offline(let reason): return "Relay unavailable — \(reason)"
        }
    }

    var isOnline: Bool { self == .online }
}

/// Keeps this Mac reachable from networks that refuse to carry traffic between their
/// own clients.
///
/// The trick that keeps it small: this bridge never speaks the Tennanova protocol. When
/// a phone arrives through the relay, it opens a plain TCP connection to the Mac's own
/// listener on loopback and pumps bytes between the two. Everything above — TLS, the
/// pinned certificate, `hello`, the pairing token — happens end to end between phone and
/// listener exactly as it does on a LAN, and is as opaque to this file as it is to the
/// relay server. Nothing in `Server.swift` had to change to gain a second transport.
final class RelayBridge {

    var onStatus: ((RelayStatus) -> Void)?

    private let queue = DispatchQueue(label: "com.tennanova.relay")
    private let secret: String
    private var control: NWConnection?
    private var streams: Set<RelayStream> = []
    private var localPort: UInt16 = Proto.defaultPort
    private var running = false
    private var retryDelay: TimeInterval = 1
    private var retryPending = false
    private var status: RelayStatus = .disabled

    /// Room name the phone is given. Public by design; see `Relay.roomId`.
    let roomId: String

    init(secret: String) {
        self.secret = secret
        self.roomId = Relay.roomId(for: secret)
    }

    func start(localPort: UInt16) {
        queue.async {
            self.localPort = localPort
            guard Relay.isEnabled else {
                self.emit(.disabled)
                return
            }
            guard !self.running else { return }
            self.running = true
            self.retryDelay = 1
            self.openControl()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.control?.cancel()
            self.control = nil
            self.streams.forEach { $0.close() }
            self.streams.removeAll()
            self.emit(.disabled)
        }
    }

    // MARK: - Control channel

    private func openControl() {
        guard running, let url = Relay.controlURL(secret: secret) else { return }
        Log.info("relay: dialling \(url.scheme ?? "wss")://\(Relay.host)")
        emit(.connecting)

        let connection = NWConnection(to: .url(url), using: Self.webSocketParameters())
        control = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.control === connection else { return }
            switch state {
            case .ready:
                // Deliberately not `.online` yet: the socket being up says nothing about
                // whether the relay accepted us. The `ready` message does.
                self.receiveControl(on: connection)
            case .failed(let error):
                self.controlEnded(reason: error.localizedDescription)
            case .cancelled:
                self.controlEnded(reason: "connection closed")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveControl(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, self.control === connection else { return }
            if let error {
                self.controlEnded(reason: error.localizedDescription)
                return
            }
            if Self.isClose(context) {
                self.controlEnded(reason: "the relay closed the channel")
                return
            }
            if let data, !data.isEmpty { self.handleControl(data) }
            self.receiveControl(on: connection)
        }
    }

    private func handleControl(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String else { return }
        switch type {
        case "ready":
            retryDelay = 1
            Log.info("relay ready, room \(roomId.prefix(8))")
            emit(.online)
        case "open":
            guard let sid = object["sid"] as? String else { return }
            openStream(sid: sid)
        default:
            break
        }
    }

    private func controlEnded(reason: String) {
        guard running else { return }
        Log.warn("relay control channel down: \(reason)")
        control?.cancel()
        control = nil
        emit(.offline(reason))
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard running, !retryPending else { return }
        retryPending = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryPending = false
            guard self.running else { return }
            self.openControl()
        }
    }

    // MARK: - Streams

    private func openStream(sid: String) {
        guard let url = Relay.acceptURL(secret: secret, sid: sid) else { return }
        let stream = RelayStream(
            relay: NWConnection(to: .url(url), using: Self.webSocketParameters()),
            local: NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: localPort) ?? .any,
                using: .tcp
            ),
            queue: queue
        )
        streams.insert(stream)
        stream.onFinished = { [weak self] in
            self?.streams.remove(stream)
        }
        Log.info("relay stream opening")
        stream.start()
    }

    // MARK: - Helpers

    private func emit(_ next: RelayStatus) {
        guard status != next else { return }
        status = next
        onStatus?(next)
    }

    private static func webSocketParameters() -> NWParameters {
        // The scheme and the protocol stack have to agree. Handing TLS options to a
        // connection aimed at a plain `ws://` relay produces a handshake against a server
        // that speaks none, which fails in a way that looks exactly like the relay being
        // down — the whole point of the local-testing mode is to not chase that.
        let params: NWParameters
        if Relay.isInsecureLocal {
            params = .tcp
        } else {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv12
            )
            params = NWParameters(tls: tls)
        }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    fileprivate static func isClose(_ context: NWConnection.ContentContext?) -> Bool {
        guard let metadata = context?.protocolMetadata(
            definition: NWProtocolWebSocket.definition
        ) as? NWProtocolWebSocket.Metadata else { return false }
        return metadata.opcode == .close
    }
}

/// One phone's session: relay WebSocket on one side, the Mac's own listener on the other.
private final class RelayStream: Hashable {

    var onFinished: (() -> Void)?

    private let relay: NWConnection
    private let local: NWConnection
    private let queue: DispatchQueue
    private var readyCount = 0
    private var finished = false

    init(relay: NWConnection, local: NWConnection, queue: DispatchQueue) {
        self.relay = relay
        self.local = local
        self.queue = queue
    }

    func start() {
        for connection in [relay, local] {
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    self.readyCount += 1
                    // Neither direction may start early: bytes read from the phone before
                    // the loopback socket exists have nowhere to go but the floor.
                    if self.readyCount == 2 {
                        Log.info("relay stream ready on both sides")
                        self.pump()
                    }
                case .failed(let error):
                    self.finish(reason: error.localizedDescription)
                case .cancelled:
                    self.finish(reason: nil)
                default:
                    break
                }
                _ = connection
            }
            connection.start(queue: queue)
        }
    }

    func close() { finish(reason: nil) }

    private func pump() {
        readFromRelay()
        readFromLocal()
    }

    /// Phone → Mac. Each chunk is fully written to the listener before the next is read,
    /// so a slow local socket cannot make this process buffer a whole clipboard image.
    private func readFromRelay() {
        relay.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.finished else { return }
            if let error {
                self.finish(reason: error.localizedDescription)
                return
            }
            if RelayBridge.isClose(context) {
                self.finish(reason: nil)
                return
            }
            guard let data, !data.isEmpty else {
                self.readFromRelay()
                return
            }
            self.local.send(content: data, completion: .contentProcessed { sendError in
                if let sendError {
                    self.finish(reason: sendError.localizedDescription)
                } else {
                    self.readFromRelay()
                }
            })
        }
    }

    /// Mac → phone, with the same one-chunk-in-flight rule in the other direction.
    private func readFromLocal() {
        local.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let error {
                self.finish(reason: error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(
                    identifier: "relay", metadata: [metadata]
                )
                self.relay.send(
                    content: data,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { sendError in
                        if let sendError {
                            self.finish(reason: sendError.localizedDescription)
                        } else if isComplete {
                            self.finish(reason: nil)
                        } else {
                            self.readFromLocal()
                        }
                    }
                )
                return
            }
            if isComplete {
                self.finish(reason: nil)
            } else {
                self.readFromLocal()
            }
        }
    }

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        if let reason { Log.warn("relay stream ended: \(reason)") }
        relay.cancel()
        local.cancel()
        onFinished?()
        onFinished = nil
    }

    static func == (lhs: RelayStream, rhs: RelayStream) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
