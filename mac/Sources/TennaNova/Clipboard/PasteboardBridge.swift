import Foundation
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum ClipboardPayload {
    case text(String)
    case image(data: Data, mime: String, sha256: String, name: String?)
}

/// What the phone is known to be holding, and therefore what it must not be sent again.
///
/// Content the phone *sent us* counts every bit as much as content we sent it, and that is
/// the whole reason this is a type rather than a stray `String?`. Every push makes Android
/// raise its own "Copied" panel, so re-pushing a clip that started on the phone — which a
/// reconnect used to do, because `hello` re-pushes the pasteboard — shows the user a second
/// panel for one copy.
struct PeerClipboardState {

    private var fingerprint: String?

    /// True when this content is new to the phone; records it as sent.
    mutating func shouldSend(_ candidate: String) -> Bool {
        guard candidate != fingerprint else { return false }
        fingerprint = candidate
        return true
    }

    /// Records content that arrived from the phone, which by definition already has it.
    mutating func note(_ candidate: String) {
        fingerprint = candidate
    }

    /// A different phone has paired, so nothing has been sent to *this* peer yet.
    mutating func reset() {
        fingerprint = nil
    }
}

/// Mirrors text and one image at a time between NSPasteboard and the phone.
final class PasteboardBridge {

    var onLocalCopy: ((_ payload: ClipboardPayload, _ seq: Int) -> Void)?
    var onTransferStatus: ((String) -> Void)?

    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var timer: Timer?
    private var seq = 0
    private var peerSupportsImages = false
    private var peer = PeerClipboardState()

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                [weak self] _ in self?.poll()
            }
            Log.info("clipboard watcher started")
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    func setPeerSupportsImages(_ supported: Bool) {
        DispatchQueue.main.async { [weak self] in self?.peerSupportsImages = supported }
    }

    /// Pushes the current pasteboard to a phone that has just said hello. Skips content the
    /// phone already has, so a flapping socket doesn't spam it once per reconnect.
    func sendCurrentIfAny() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.emitCurrentPasteboard()
            // The poll compares against this; leaving it stale would let the next tick emit
            // the very clip we just considered.
            self.lastChangeCount = self.pasteboard.changeCount
        }
    }

    /// A different phone has paired, so nothing has been sent to *this* peer yet.
    func resetPeerState() {
        DispatchQueue.main.async { [weak self] in self?.peer.reset() }
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        emitCurrentPasteboard()
    }

    /// Emits the pasteboard unless the phone already has exactly this content.
    ///
    /// The check is unconditional rather than reconnect-only. Suppressing an *identical
    /// consecutive* emission costs nothing — the phone's clipboard already holds it — while
    /// letting one through costs a duplicate system panel, and a `hello` landing just before
    /// a poll tick made that a routine race rather than an edge case.
    private func emitCurrentPasteboard() {
        if peerSupportsImages, let image = imagePayload() {
            guard peer.shouldSend("image:\(image.sha256)") else { return }
            seq += 1
            Log.info("image copied on Mac (\(image.data.count) bytes) -> phone")
            onTransferStatus?("Sending image to phone…")
            onLocalCopy?(.image(data: image.data, mime: image.mime,
                                sha256: image.sha256, name: image.name), seq)
            return
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard peer.shouldSend("text:\(text)") else { return }
        seq += 1
        Log.info("clipboard copied on Mac (\(text.count) chars) -> phone")
        onLocalCopy?(.text(text), seq)
    }

    func applyRemote(text: String, seq remoteSeq: Int) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Recorded before the early return as well: the phone demonstrably has this text
            // either way, and forgetting that is what used to send it straight back on the
            // next reconnect.
            self.peer.note("text:\(text)")
            if self.pasteboard.string(forType: .string) == text { return }
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
            self.lastChangeCount = self.pasteboard.changeCount
            self.onTransferStatus?("Text received from phone")
            Log.info("clipboard from phone applied (\(text.count) chars)")
        }
    }

    func applyRemoteImage(data: Data, mime: String, sha256: String, name: String?) {
        guard data.count <= Proto.maxImageBytes, Self.sha256(data) == sha256,
              Self.isSafeImageData(data), let image = NSImage(data: data) else {
            Log.warn("rejected invalid clipboard image from phone")
            onTransferStatus?("Couldn’t apply image from phone")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pasteboard.clearContents()
            var written: Data?
            if mime == "image/png", self.pasteboard.setData(data, forType: .png) {
                written = data
            }
            if written == nil, let png = Self.pngData(for: image),
               self.pasteboard.setData(png, forType: .png) {
                written = png
            }
            if let tiff = image.tiffRepresentation {
                _ = self.pasteboard.setData(tiff, forType: .tiff)
            }
            guard let written else {
                self.onTransferStatus?("Couldn’t write image to the Mac clipboard")
                return
            }
            // The hash of what actually landed, not of what arrived. A phone JPEG is
            // re-encoded to PNG on the way in, so noting the phone's hash would leave the
            // pasteboard holding bytes we had no record of sending — and the next reconnect
            // would push them back as a "new" image.
            self.peer.note("image:\(Self.sha256(written))")
            self.lastChangeCount = self.pasteboard.changeCount
            self.onTransferStatus?("Image received from phone")
            Log.info("clipboard image from phone applied (\(data.count) bytes)")
        }
    }

    // MARK: - Image extraction and optimization

    private struct LocalImage {
        let data: Data
        let mime: String
        let sha256: String
        let name: String?
    }

    private func imagePayload() -> LocalImage? {
        if let file = firstImageFile(), Self.isSafeSourceFile(file),
           let raw = try? Data(contentsOf: file, options: .mappedIfSafe),
           raw.count <= Self.maxSourceBytes,
           Self.isSafeImageData(raw), let image = NSImage(data: raw) {
            let type = UTType(filenameExtension: file.pathExtension)
            let mime = type?.preferredMIMEType ?? "image/png"
            return prepared(raw: raw, mime: mime, image: image,
                            name: file.lastPathComponent)
        }

        if let png = pasteboard.data(forType: .png), let image = NSImage(data: png) {
            return prepared(raw: png, mime: "image/png", image: image, name: nil)
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let png = Self.pngData(for: image) else { return nil }
        return prepared(raw: png, mime: "image/png", image: image, name: nil)
    }

    private func firstImageFile() -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first { url in
            guard url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
    }

    private func prepared(raw: Data, mime: String, image: NSImage, name: String?) -> LocalImage? {
        if raw.count <= Proto.maxImageBytes, Self.androidDecodableMIMEs.contains(mime.lowercased()) {
            return LocalImage(data: raw, mime: mime, sha256: Self.sha256(raw), name: name)
        }

        for edge in [4096, 3072, 2048, 1536, 1024] {
            guard let optimized = Self.optimizedData(for: image, maxEdge: edge) else { continue }
            if optimized.data.count <= Proto.maxImageBytes {
                onTransferStatus?("Large image optimized for transfer")
                return LocalImage(data: optimized.data, mime: optimized.mime,
                                  sha256: Self.sha256(optimized.data), name: name)
            }
        }
        onTransferStatus?("Image is too large to sync")
        return nil
    }

    private static let maxSourceBytes = 100 * 1024 * 1024
    private static let maxImageEdge = 32_768
    private static let maxImagePixels = 100_000_000
    private static let androidDecodableMIMEs: Set<String> = [
        "image/png", "image/jpeg", "image/jpg", "image/webp", "image/gif",
        "image/heic", "image/heif", "image/avif", "image/bmp", "image/x-ms-bmp"
    ]

    static func optimizedData(for image: NSImage, maxEdge: Int) -> (data: Data, mime: String)? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxEdge) / max(source.width, source.height))
        let width = max(1, Int(source.width * scale))
        let height = max(1, Int(source.height * scale))
        let hasAlpha = Self.hasAlpha(image)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                         pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: hasAlpha ? 4 : 3, hasAlpha: hasAlpha,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        if hasAlpha, let png = rep.representation(using: .png, properties: [:]) {
            return (png, "image/png")
        }
        guard let jpeg = rep.representation(using: .jpeg,
                                             properties: [.compressionFactor: 0.9]) else { return nil }
        return (jpeg, "image/jpeg")
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func hasAlpha(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return true
        }
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    private static func isSafeSourceFile(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return size > 0 && size <= maxSourceBytes
    }

    private static func isSafeImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maxImageEdge, height <= maxImageEdge else {
            return false
        }
        return width * height <= maxImagePixels
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
