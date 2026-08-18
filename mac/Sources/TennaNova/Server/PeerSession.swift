import Foundation
import Network

/// One connected Android device. Wraps an NWConnection and speaks the v1 wire protocol:
/// JSON in text frames, icon PNG bytes in binary frames.
final class PeerSession {

    let id = UUID()
    private let conn: NWConnection
    private let queue: DispatchQueue

    /// A decoded text message: the envelope plus the raw bytes so the handler can
    /// decode the concrete type it wants.
    var onMessage: ((Envelope, Data) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onClosed: ((Error?) -> Void)?

    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.conn = connection
        self.queue = queue
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("peer \(self.id.uuidString.prefix(8)) ready")
                self.receiveLoop()
                self.onReady?()
            case .failed(let err):
                self.finish(err)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func close() {
        guard !closed else { return }
        conn.cancel()
    }

    // MARK: - Sending

    func send<T: Encodable>(_ message: T) {
        do {
            let data = try Wire.encode(message)
            queue.async { [weak self] in
                self?.sendFrame(data, opcode: .text)
            }
        } catch {
            Log.error("encode failed: \(error.localizedDescription)")
        }
    }

    func sendBinary(_ data: Data) {
        queue.async { [weak self] in
            self?.sendFrame(data, opcode: .binary)
        }
    }

    /// Queues a metadata frame and its binary body as one indivisible pair. Other
    /// producers (notification icons and clipboard images) cannot interleave them.
    func sendBinary<T: Encodable>(header: T, data: Data) {
        do {
            let encoded = try Wire.encode(header)
            queue.async { [weak self] in
                guard let self else { return }
                self.sendFrame(encoded, opcode: .text)
                self.sendFrame(data, opcode: .binary)
            }
        } catch {
            Log.error("binary header encode failed: \(error.localizedDescription)")
        }
    }

    private func sendFrame(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let meta = NWProtocolWebSocket.Metadata(opcode: opcode)
        let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true,
                  completion: .contentProcessed { [weak self] error in
            if let error {
                Log.warn("send failed: \(error.localizedDescription)")
                self?.finish(error)
            }
        })
    }

    // MARK: - Receiving

    private func receiveLoop() {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.finish(error)
                return
            }

            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                          as? NWProtocolWebSocket.Metadata)?.opcode

            // Only a close frame means the peer is done. Control frames legitimately
            // carry no payload — treating any empty frame as a close tore the socket
            // down on every keepalive ping, once per ping interval, forever.
            if opcode == .close {
                self.finish(nil)
                return
            }

            switch opcode {
            case .ping, .pong:
                break   // autoReplyPing answers pings for us

            case .text:
                guard let data else { break }
                if let env = Wire.peek(data) {
                    guard env.v == Proto.version else {
                        Log.warn("dropping message with unsupported version \(env.v)")
                        break
                    }
                    self.onMessage?(env, data)
                } else {
                    Log.warn("received a text frame that isn't valid protocol JSON")
                }
            case .binary:
                guard let data else { break }
                self.onBinary?(data)
            default:
                break
            }

            self.receiveLoop()
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        if let error {
            Log.warn("peer \(id.uuidString.prefix(8)) closed: \(error.localizedDescription)")
        } else {
            Log.info("peer \(id.uuidString.prefix(8)) closed")
        }
        conn.cancel()
        onClosed?(error)
    }
}
