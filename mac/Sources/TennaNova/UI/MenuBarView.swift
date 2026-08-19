import SwiftUI

/// The always-there entry point. Since the window landed this is a status summary and a
/// way in, not the whole application — the pairing QR and the connection diagnostics it
/// used to inline now have room to breathe in `DeviceView`.
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if state.status.isConnected {
                connectedBody
            } else {
                waitingBody
            }

            Divider()

            Button {
                openWindow(id: AppScene.mainWindow)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(state.isPaired ? "Open Tennanova" : "Pair a phone…",
                      systemImage: state.isPaired ? "macwindow" : "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)

            HStack {
                // Not gated on being connected: a stuck phone is exactly when unpairing
                // is needed, and unpair() is what mints a fresh token and QR.
                if state.isPaired {
                    Button("Unpair") { state.unpair() }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.status.isConnected ? Tenna.accent : Color.secondary)
                .frame(width: 8, height: 8)
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
