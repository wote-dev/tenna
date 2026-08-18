import SwiftUI

struct MenuBarView: View {
    @Bindable var state: AppState
    @State private var copied = false
    @State private var showPairingAnyway = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if state.status.isConnected {
                connectedBody
            } else if state.isPaired && !showPairingAnyway {
                // Not the QR. A paired phone that is merely offline used to land here and
                // be shown a pairing code, which reads as "you are not paired" and sends
                // people off to re-pair a pairing that was never the problem.
                waitingBody
            } else {
                pairingBody
            }

            Divider()

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
                .fill(state.status.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tennanova").font(.headline)
                Text(state.isPaired && !state.status.isConnected
                     ? "Paired · reconnecting"
                     : state.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var connectedBody: some View {
        if let device = state.pairedDevice {
            VStack(alignment: .leading, spacing: 6) {
                Label(device.name, systemImage: "iphone")
                    .font(.callout)
                if let battery = state.battery {
                    Label("\(battery)%\(state.charging ? " — charging" : "")",
                          systemImage: batteryIcon(battery))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Paired, but nothing has connected. The useful thing to show is *where* this Mac
    /// can be reached, because the usual cause is the two devices being on networks that
    /// cannot see each other.
    private var waitingBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Paired with \(state.pairedDeviceName ?? "your phone")",
                  systemImage: "iphone")
                .font(.callout)

            Label(
                state.advertisedHosts.isEmpty
                    ? "Waiting for a local network address."
                    : "Ready on \(state.advertisedHosts.joined(separator: ", "))",
                systemImage: "network"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(state.usbStatus.label,
                  systemImage: state.usbStatus.isReady ? "cable.connector" : "wifi")
                .font(.caption)
                .foregroundStyle(state.usbStatus.isReady ? Color.green : Color.secondary)

            if !state.usbStatus.isReady {
                Text("Your phone must be able to reach one of those addresses. Many "
                     + "networks block device-to-device traffic — a USB cable or the "
                     + "phone's hotspot gets around that.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Show pairing code") { showPairingAnyway = true }
                .font(.caption)
        }
    }

    private var pairingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan this with Tennanova on your phone")
                .font(.caption)
                .foregroundStyle(.secondary)

            Label(
                "Works on any local network shared by this Mac and your phone.",
                systemImage: "network"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let img = QRCode.image(from: state.pairingPayload) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .cornerRadius(6)
            } else {
                Text("Could not generate the pairing code.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Label(
                state.usbStatus.label,
                systemImage: state.usbStatus.isReady ? "cable.connector" : "wifi"
            )
            .font(.caption)
            .foregroundStyle(state.usbStatus.isReady ? Color.green : Color.secondary)

            // Every address the phone will try, in order. Worth showing: on a hotspot
            // this is the difference between "it should work" and knowing which network
            // the Mac actually joined.
            if !state.advertisedHosts.isEmpty {
                Label(state.advertisedHosts.joined(separator: ", "), systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.pairingPayload, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy pairing code",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<15:  return "battery.25"
        case ..<50:  return "battery.50"
        case ..<85:  return "battery.75"
        default:     return "battery.100"
        }
    }
}
