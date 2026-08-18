import SwiftUI

struct MenuBarView: View {
    @Bindable var state: AppState
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if state.status.isConnected {
                connectedBody
            } else {
                pairingBody
            }

            Divider()

            HStack {
                if state.status.isConnected {
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
                Text(state.status.label)
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

    private var pairingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan this with Tennanova on your phone")
                .font(.caption)
                .foregroundStyle(.secondary)

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
