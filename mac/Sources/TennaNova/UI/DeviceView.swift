import SwiftUI

/// The phone pane: pairing, reachability, battery, and what this build of the phone app
/// can actually do. Everything here used to be inlined in the 280pt menu bar popover,
/// where the QR had to compete with the connection diagnostics for room.
struct DeviceView: View {
    @Environment(AppState.self) private var state
    @State private var showPairingAnyway = false
    @State private var confirmUnpair = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if state.status.isConnected {
                    connected
                } else if state.isPaired && !showPairingAnyway {
                    // Not the QR. A paired phone that is merely offline used to land here
                    // and be shown a pairing code, which reads as "you are not paired" and
                    // sends people off to re-pair a pairing that was never the problem.
                    waiting
                } else {
                    pairing
                }

                if state.isPaired {
                    Divider()
                    Button("Unpair this phone…", role: .destructive) { confirmUnpair = true }
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Unpair \(state.pairedDeviceName ?? "your phone")?",
                            isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { state.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tennanova will forget this phone and delete the conversations it "
                 + "mirrored. You will need to scan a new pairing code to reconnect.")
        }
        .navigationTitle(state.pairedDeviceName ?? "Phone")
    }

    private var deviceName: String? {
        state.pairedDevice?.name ?? state.pairedDeviceName
    }

    private var shortStatus: String {
        switch state.status {
        case .connected:        return "Connected"
        case .starting:         return "Starting…"
        case .failed(let why):  return why
        case .waitingForPhone:
            return state.serverActivity.label
                ?? (state.isPaired ? "Waiting for this phone" : "No phone paired yet")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: state.status.isConnected ? "iphone" : "iphone.slash")
                .font(.system(size: 30))
                .foregroundStyle(state.status.isConnected ? Tenna.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(deviceName ?? "No phone paired")
                    .font(.title2.weight(.semibold))
                // `status.label` names the device, which the line above already does.
                Text(shortStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let battery = state.battery {
                StatusRow("\(battery)%\(state.charging ? " — charging" : "")",
                          symbol: Tenna.batteryIcon(battery),
                          tint: battery < 15 ? .red : .secondary,
                          font: .callout)
            }
            if let device = state.pairedDevice {
                // Most phones report the model as their name, and repeating it is noise.
                if let model = device.model, model != device.name {
                    StatusRow(model, symbol: "cpu", font: .callout)
                }
                if let sdk = device.androidSdk {
                    StatusRow("Android \(sdk)", symbol: "gear", font: .callout)
                }
            }

            Divider()

            Text("Connection").font(.headline)
            ReachabilityRows()

            if let transfer = state.lastTransferStatus {
                StatusRow(transfer, symbol: "doc.on.clipboard")
            }

            Divider()

            Text("This phone supports").font(.headline)
            StatusRow(state.supportsImageClipboard
                        ? "Clipboard sync, including images"
                        : "Clipboard sync, text only",
                      symbol: "doc.on.clipboard",
                      tint: Tenna.accent)
            StatusRow("Mirrored notifications, with replies",
                      symbol: "bell.badge",
                      tint: Tenna.accent)

            Button("Show pairing code") { showPairingAnyway = true }
                .padding(.top, 4)
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConnectionAttemptRow()
            ReachabilityRows()

            if !state.usbStatus.isReady && !state.relayStatus.isOnline {
                Caption("Your phone must be able to reach one of those addresses. Many "
                        + "networks block device-to-device traffic — a USB cable or the "
                        + "phone's hotspot gets around that.")
            }

            Button("Show pairing code") { showPairingAnyway = true }
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scan this with Tennanova on your phone")
                .font(.headline)

            ConnectionAttemptRow()

            PairingCode(size: 260)
                .frame(maxWidth: 300)

            StatusRow(state.relayStatus.isOnline
                        ? "Works on any local network, and over the internet when a "
                          + "network blocks device-to-device traffic."
                        : "Works on any local network shared by this Mac and your phone.",
                      symbol: "network")

            ReachabilityRows()

            if state.isPaired {
                Button("Back") { showPairingAnyway = false }
            }
        }
    }
}
