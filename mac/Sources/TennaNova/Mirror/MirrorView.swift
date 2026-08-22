import AppKit
import SwiftUI

struct MirrorView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Color.black
            MirrorSurface(
                renderer: state.mirror.renderer,
                videoSize: state.mirror.videoSize,
                controlsEnabled: state.mirror.controlAvailable && state.mirror.phase == .streaming,
                onInteraction: state.sendMirrorInteraction
            )

            if state.mirror.phase != .streaming {
                statusOverlay
            }
        }
        .frame(minWidth: 300, minHeight: 420)
        .overlay(alignment: .top) {
            if state.mirror.phase == .streaming && !state.mirror.controlAvailable {
                Text("View only — enable Tennanova Accessibility on your phone for controls")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.7), in: .capsule)
                    .padding(10)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.sendMirrorGlobal("back") } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!state.mirror.controlAvailable)
                Button { state.sendMirrorGlobal("home") } label: {
                    Label("Home", systemImage: "circle")
                }
                .disabled(!state.mirror.controlAvailable)
                Button { state.sendMirrorGlobal("recents") } label: {
                    Label("Recents", systemImage: "square.on.square")
                }
                .disabled(!state.mirror.controlAvailable)

                Divider()

                Button(role: .destructive) { state.stopMirroring() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!state.mirror.phase.isActive)
            }
        }
        .navigationTitle("Phone Mirror")
        .onAppear { state.mirrorWindowAppeared() }
        .onDisappear { state.mirrorWindowDisappeared() }
    }

    private var statusOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .opacity(state.mirror.phase == .approvalRequired || state.mirror.phase == .starting ? 1 : 0)
            Text(state.mirror.statusText)
                .font(.headline)
                .multilineTextAlignment(.center)
            if state.mirror.phase == .approvalRequired {
                Text("Approve Android's screen-capture prompt. If no notification appeared, open Tennanova on your phone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if !state.mirror.canMirror {
                Text("Connect directly over local Wi-Fi or USB. Relay connections cannot carry screen video.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: 330)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(24)
    }
}

private struct MirrorSurface: NSViewRepresentable {
    let renderer: MirrorVideoRenderer
    let videoSize: CGSize
    let controlsEnabled: Bool
    let onInteraction: (MirrorInteraction) -> Void

    func makeNSView(context: Context) -> MirrorSurfaceView {
        MirrorSurfaceView(renderer: renderer)
    }

    func updateNSView(_ view: MirrorSurfaceView, context: Context) {
        view.videoSize = videoSize
        view.controlsEnabled = controlsEnabled
        view.onInteraction = onInteraction
        view.needsLayout = true
    }
}

private final class MirrorSurfaceView: NSView {
    private let renderer: MirrorVideoRenderer
    var videoSize: CGSize = .zero
    var controlsEnabled = false
    var onInteraction: ((MirrorInteraction) -> Void)?

    private var dragSamples: [(point: CGPoint, time: TimeInterval)] = []
    private var scrollOrigin: CGPoint?
    private var scrollDelta: CGFloat = 0
    private var scrollWork: DispatchWorkItem?

    init(renderer: MirrorVideoRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(renderer.layer)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        renderer.layer.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        guard controlsEnabled, normalized(event) != nil else { return }
        window?.makeFirstResponder(self)
        dragSamples = [(convert(event.locationInWindow, from: nil), event.timestamp)]
    }

    override func mouseDragged(with event: NSEvent) {
        guard controlsEnabled, dragSamples.count < 128, normalized(event) != nil else { return }
        dragSamples.append((convert(event.locationInWindow, from: nil), event.timestamp))
    }

    override func mouseUp(with event: NSEvent) {
        guard controlsEnabled, let first = dragSamples.first else {
            dragSamples.removeAll()
            return
        }
        let finalPoint = convert(event.locationInWindow, from: nil)
        if MirrorViewport.normalized(finalPoint, in: currentVideoRect) != nil {
            dragSamples.append((finalPoint, event.timestamp))
        }
        defer { dragSamples.removeAll() }
        guard let last = dragSamples.last,
              let firstNormalized = MirrorViewport.normalized(first.point, in: currentVideoRect),
              MirrorViewport.normalized(last.point, in: currentVideoRect) != nil
        else { return }

        let movement = hypot(last.point.x - first.point.x, last.point.y - first.point.y)
        if movement < 4 {
            onInteraction?(.tap(x: Double(firstNormalized.x), y: Double(firstNormalized.y)))
            return
        }
        let duration = max(last.time - first.time, 0.08)
        let selected = evenlySampled(dragSamples, limit: 32)
        let points = selected.compactMap { sample -> MirrorPoint? in
            guard let point = MirrorViewport.normalized(sample.point, in: currentVideoRect) else {
                return nil
            }
            return MirrorPoint(
                x: Double(point.x),
                y: Double(point.y),
                t: min(max((sample.time - first.time) / duration, 0), 1)
            )
        }
        guard points.count >= 2 else { return }
        onInteraction?(.swipe(
            points: points,
            durationMs: min(max(Int(duration * 1_000), 80), 1_000)
        ))
    }

    override func scrollWheel(with event: NSEvent) {
        guard controlsEnabled, let point = normalized(event) else { return }
        scrollOrigin = point
        scrollDelta += event.scrollingDeltaY
        scrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushScroll() }
        scrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: work)
    }

    private func flushScroll() {
        guard let origin = scrollOrigin, abs(scrollDelta) > 0.5 else { return }
        let distance = min(max(abs(scrollDelta) / 500, 0.035), 0.22)
        let direction: CGFloat = scrollDelta > 0 ? -1 : 1
        let startY = min(max(origin.y - direction * distance / 2, 0.02), 0.98)
        let endY = min(max(origin.y + direction * distance / 2, 0.02), 0.98)
        onInteraction?(.swipe(points: [
            MirrorPoint(x: Double(origin.x), y: Double(startY), t: 0),
            MirrorPoint(x: Double(origin.x), y: Double(endY), t: 1)
        ], durationMs: 140))
        scrollOrigin = nil
        scrollDelta = 0
        scrollWork = nil
    }

    private var currentVideoRect: CGRect {
        MirrorViewport.videoRect(container: bounds.size, video: videoSize)
    }

    private func normalized(_ event: NSEvent) -> CGPoint? {
        MirrorViewport.normalized(convert(event.locationInWindow, from: nil), in: currentVideoRect)
    }

    private func evenlySampled<T>(_ values: [T], limit: Int) -> [T] {
        guard values.count > limit else { return values }
        return (0..<limit).map { index in
            values[index * (values.count - 1) / (limit - 1)]
        }
    }
}
