import SwiftUI

/// The always-there entry point. Since the window landed this is a status summary and a
/// way in, not the whole application — the pairing QR and the connection diagnostics it
/// used to inline now have room to breathe in `DeviceView`.
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // First, and above the connection detail: someone reaching for the menu bar
            // while their phone is ringing wants one of two buttons and nothing else.
            if let call = state.calls.current {
                liveCall(call)
                    .padding(14)
                    .contentSurface(.card, cornerRadius: 20)
            }

            Group {
                if state.status.isConnected {
                    connectedBody
                } else {
                    waitingBody
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentSurface(.inset, cornerRadius: 18)

            Button {
                openWindow(id: AppScene.mainWindow)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(state.isPaired ? "Open Tennanova" : "Pair a phone…",
                      systemImage: state.isPaired ? "macwindow" : "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .adaptiveGlassButton(prominent: true)

            HStack {
                // Not gated on being connected: a stuck phone is exactly when unpairing
                // is needed, and unpair() is what mints a fresh token and QR.
                if state.isPaired {
                    Button("Unpair") { state.unpair() }
                }
                SettingsLink()
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(18)
        .frame(width: 310)
        .background(TennaBackdrop())
    }

    /// The ringing or in-progress call, answerable without opening the window.
    @ViewBuilder
    private func liveCall(_ call: MirroredCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(image: state.icons[call.avatarHash] ?? state.icons[call.iconHash],
                       monogram: call.title.monogram, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(call.title).fontWeight(.semibold).lineLimit(1)
                    CallStatusLine(call: call)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if call.canAnswer {
                    Button {
                        state.perform(.answer, on: call)
                    } label: {
                        Label("Answer", systemImage: "phone.fill")
                            .frame(maxWidth: .infinity)
                }
                .adaptiveGlassButton(prominent: true)
                .tint(.green)
                }
                if call.canDecline {
                    Button(role: .destructive) {
                        state.perform(.decline, on: call)
                    } label: {
                        Label("Decline", systemImage: "phone.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                if call.canHangUp {
                    Button(role: .destructive) {
                        state.perform(.hangup, on: call)
                    } label: {
                        Label("Hang up", systemImage: "phone.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            // Repeated here for the same reason it is repeated everywhere else: this is a
            // surface someone can answer a call from without ever seeing the window.
            Caption("Audio stays on your phone.")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            SurfaceIcon(symbol: state.status.isConnected ? "iphone.badge.play" : "iphone.slash",
                        tint: state.status.isConnected ? Tenna.accent : .secondary,
                        size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tennanova").font(.headline)
                Text(headerStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if state.history.totalUnread > 0 {
                UnreadBadge(count: state.history.totalUnread)
            }
        }
    }

    private var headerStatus: String {
        if state.status.isConnected { return state.status.label }
        if let attempt = state.serverActivity.label { return attempt }
        return state.isPaired
            ? "Paired · listening for phone"
            : "Listening · no phone attempt yet"
    }

    @ViewBuilder
    private var connectedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let device = state.pairedDevice {
                StatusRow(device.name, symbol: "iphone", tint: .primary, font: .callout)
            }
            if let battery = state.battery {
                StatusRow("\(battery)%\(state.charging ? " — charging" : "")",
                          symbol: Tenna.batteryIcon(battery),
                          tint: battery < 15 ? .red : .secondary)
            }
            if let latest = state.history.threads.first, let message = latest.latest {
                StatusRow("\(latest.title): \(message.body)", symbol: "bubble.left")
            }
            if state.supportsMirroring {
                Button {
                    state.beginMirroring()
                } label: {
                    Label("Mirror Phone", systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveGlassButton()
                .disabled(!state.mirror.canMirror)
                .padding(.top, 6)
            }
        }
    }

    /// Paired but nothing has connected, or never paired at all. Either way the useful
    /// thing to show is *where* this Mac can be reached — the usual cause is the two
    /// devices being on networks that cannot see each other.
    private var waitingBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isPaired {
                StatusRow("Paired with \(state.pairedDeviceName ?? "your phone")",
                          symbol: "iphone", tint: .primary, font: .callout)
            }
            ConnectionAttemptRow()
            ReachabilityRows()
        }
    }
}
