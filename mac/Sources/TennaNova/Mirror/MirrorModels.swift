import Foundation
import CoreGraphics
import Observation

enum MirrorPhase: String, Codable, CaseIterable {
    case idle
    case approvalRequired = "approval_required"
    case starting
    case streaming
    case stopping
    case stopped
    case error

    var isActive: Bool {
        switch self {
        case .approvalRequired, .starting, .streaming, .stopping: true
        case .idle, .stopped, .error: false
        }
    }
}

enum MirrorRoute: String, Codable {
    case lan, usb, relay

    var isLocal: Bool { self == .lan || self == .usb }
}

enum MirrorInteraction {
    case tap(x: Double, y: Double)
    case swipe(points: [MirrorPoint], durationMs: Int)
}

struct MirrorVideoPacket: Equatable {
    static let headerSize = 20
    let keyframe: Bool
    let generation: Int
    let sequence: UInt32
    let presentationTimeUs: UInt64
    let accessUnit: Data

    static func parse(_ data: Data) -> MirrorVideoPacket? {
        guard data.count > headerSize, data.count <= 8 * 1024 * 1024 else { return nil }
        let bytes = [UInt8](data.prefix(headerSize))
        guard bytes[0...3].elementsEqual([0x54, 0x4e, 0x4d, 0x56]), bytes[4] == 1,
              bytes[5] & 0xfe == 0 else { return nil }
        let generation = Int(bytes[6]) << 8 | Int(bytes[7])
        let sequence = bytes[8...11].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let timestamp = bytes[12...19].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return MirrorVideoPacket(
            keyframe: bytes[5] & 1 != 0,
            generation: generation,
            sequence: sequence,
            presentationTimeUs: timestamp,
            accessUnit: data.dropFirst(headerSize)
        )
    }
}

enum MirrorStreamAuthentication {
    static func accepts(
        _ hello: MirrorStreamHello,
        expectedToken: String?,
        announcedSessionId: String?,
        localRoute: Bool,
        peerSupportsVideo: Bool,
        primaryAuthenticated: Bool
    ) -> Bool {
        localRoute && peerSupportsVideo && primaryAuthenticated &&
        !hello.deviceId.isEmpty && expectedToken == hello.deviceToken &&
        announcedSessionId == hello.sessionId
    }
}

enum H264AnnexB {
    static func units(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            let length: Int
            if index + 3 < bytes.count && bytes[index] == 0 && bytes[index + 1] == 0 &&
                bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                length = 4
            } else if bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 {
                length = 3
            } else {
                index += 1
                continue
            }
            starts.append((index, length))
            index += length
        }
        return starts.enumerated().compactMap { item, start in
            let first = start.offset + start.length
            let last = item + 1 < starts.count ? starts[item + 1].offset : bytes.count
            guard first < last else { return nil }
            return Data(bytes[first..<last])
        }
    }

    static func avcc(_ accessUnit: Data) -> Data? {
        let nalUnits = units(accessUnit)
        guard !nalUnits.isEmpty else { return nil }
        var output = Data()
        output.reserveCapacity(accessUnit.count + nalUnits.count)
        for unit in nalUnits {
            guard unit.count <= Int(UInt32.max) else { return nil }
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }
}

enum MirrorViewport {
    static func videoRect(container: CGSize, video: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0,
              video.width > 0, video.height > 0 else { return .zero }
        let scale = min(container.width / video.width, container.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// AppKit points have a bottom-left origin; Android's normalized display has a top-left one.
    static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(
            x: ((point.x - rect.minX) / rect.width).clamped(to: 0...1),
            y: (1 - (point.y - rect.minY) / rect.height).clamped(to: 0...1)
        )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

@Observable
final class MirrorCenter {
    private(set) var phase: MirrorPhase = .idle
    private(set) var requestId: String?
    private(set) var sessionId: String?
    private(set) var controlAvailable = false
    private(set) var reason: String?
    private(set) var route: MirrorRoute?
    private(set) var videoSize: CGSize = .zero
    private(set) var generation: Int?
    private(set) var lastInputError: String?
    private(set) var windowVisible = false
    @ObservationIgnored let renderer = MirrorVideoRenderer()

    var canMirror: Bool { route?.isLocal == true }

    var statusText: String {
        switch phase {
        case .idle: "Ready to mirror"
        case .approvalRequired: "Approve screen sharing on your phone"
        case .starting: "Starting video…"
        case .streaming: controlAvailable ? "Connected" : "Connected — view only"
        case .stopping: "Stopping…"
        case .stopped: stoppedText
        case .error: errorText
        }
    }

    func updateRoute(_ value: String?) { route = value.flatMap(MirrorRoute.init(rawValue:)) }

    func prepareMacRequest(_ id: String) {
        requestId = id
        sessionId = nil
        reason = nil
        controlAvailable = false
        phase = .approvalRequired
        renderer.reset()
    }

    /// Returns false for Android approval that arrived after this Mac cancelled the request.
    func apply(_ message: MirrorStateMessage) -> Bool {
        guard let next = MirrorPhase(rawValue: message.state) else { return false }
        if let pending = requestId, let incoming = message.requestId, pending != incoming,
           next != .approvalRequired { return false }
        requestId = message.requestId ?? requestId
        sessionId = message.sessionId ?? sessionId
        phase = next
        controlAvailable = message.controlAvailable
        reason = message.reason
        if next == .stopped || next == .error { renderer.reset() }
        return true
    }

    func apply(_ config: MirrorConfig) {
        guard config.isValid, config.sessionId == sessionId else { return }
        generation = config.generation
        videoSize = CGSize(width: config.width, height: config.height)
        renderer.configure(config)
    }

    func receive(_ packet: MirrorVideoPacket) {
        guard packet.generation == generation else { return }
        renderer.enqueue(packet)
    }

    func noteInputResult(_ result: MirrorInputResult) {
        guard result.sessionId == sessionId, !result.ok else { return }
        lastInputError = result.error ?? "Phone rejected the control input"
    }

    func windowAppeared() { windowVisible = true }
    func windowDisappeared() { windowVisible = false }

    func cancelledLocally() {
        phase = .stopping
        requestId = nil
        controlAvailable = false
        renderer.reset()
    }

    func disconnected() {
        if phase.isActive {
            phase = .error
            reason = "transport_lost"
        }
        controlAvailable = false
        renderer.reset()
    }

    private var stoppedText: String {
        switch reason {
        case "phone_locked": "Stopped because the phone locked"
        case "projection_stopped": "Screen sharing was stopped on the phone"
        case "window_closed": "Mirror window closed"
        default: "Screen sharing stopped"
        }
    }

    private var errorText: String {
        switch reason {
        case "not_local": "Mirroring requires local Wi-Fi or USB"
        case "permission_denied": "Screen sharing was not approved"
        case "transport_lost": "The direct video connection was lost"
        case "encoder_failed": "The phone could not encode its screen"
        default: "Screen mirroring could not start"
        }
    }
}
