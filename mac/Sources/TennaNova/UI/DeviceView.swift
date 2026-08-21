import SwiftUI

/// Pairing, reachability, battery and capabilities presented as a proper Mac dashboard.
/// Connection machinery remains in `AppState`; this view only gives that state hierarchy.
struct DeviceView: View {
    @Environment(AppState.self) private var state
    @State private var showPairingAnyway = false
    @State private var confirmUnpair = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero

                if showPairingAnyway {
                    pairing
                } else if state.status.isConnected {
                    connected
                } else if state.isPaired {
                    waiting
                } else {
                    pairing
                }

                footer
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .tennaScrollEdge(.top)
        .confirmationDialog("Unpair \(state.pairedDeviceName ?? "your phone")?",
                            isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { state.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tennanova will forget this phone and delete the conversations it "
                 + "mirrored. You will need to scan a new pairing code to reconnect.")
        }
        .navigationTitle(deviceName ?? "Phone")
    }

    private var deviceName: String? {
        state.pairedDevice?.name ?? state.pairedDeviceName
    }

    private var shortStatus: String {
        switch state.status {
        case .connected:        return "Connected and ready"
        case .starting:         return "Starting…"
        case .failed(let why):  return why
        case .waitingForPhone:
            return state.serverActivity.label
                ?? (state.isPaired ? "Waiting for this phone" : "No phone paired yet")
        }
    }

    private var hero: some View {
        HStack(spacing: 16) {
            SurfaceIcon(symbol: state.status.isConnected ? "iphone" : "iphone.slash",
                        tint: state.status.isConnected ? Tenna.accent : .secondary,
                        size: 62)

            VStack(alignment: .leading, spacing: 4) {
                Text(deviceName ?? "Connect your Android phone")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.status.isConnected ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(shortStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 16)

            if let battery = state.battery {
                Label("\(battery)%", systemImage: Tenna.batteryIcon(battery))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(battery < 15 ? Color.red : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.06), in: .capsule)
                    .help(state.charging ? "Charging" : "Phone battery")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface(.card, cornerRadius: 26)
    }

    private var connected: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 430), spacing: 18)],
                  alignment: .leading, spacing: 18) {
            DashboardCard(title: "Connection", symbol: "point.3.connected.trianglepath.dotted") {
                ReachabilityRows()
                if let transfer = state.lastTransferStatus {
                    StatusRow(transfer, symbol: "doc.on.clipboard")
                }
            }

            DashboardCard(title: "Phone details", symbol: "cpu") {
                if let battery = state.battery {
                    StatusRow("\(battery)%\(state.charging ? " — charging" : "")",
                              symbol: Tenna.batteryIcon(battery),
                              tint: battery < 15 ? .red : .secondary,
                              font: .callout)
                }
                if let device = state.pairedDevice {
                    if let model = device.model, model != device.name {
                        StatusRow(model, symbol: "iphone", font: .callout)
                    }
                    if let sdk = device.androidSdk {
                        StatusRow("Android \(sdk)", symbol: "gear", font: .callout)
                    }
                }
            }

            DashboardCard(title: "What works", symbol: "sparkles") {
                CapabilityRow(state.supportsImageClipboard
                              ? "Clipboard, including images" : "Clipboard, text only",
                              symbol: "doc.on.clipboard", available: true)
                CapabilityRow("Notification replies", symbol: "bell.badge", available: true)
                CapabilityRow("Call controls", symbol: "phone", available: state.supportsCalls)
                CapabilityRow("File transfer", symbol: "folder", available: state.supportsFileTransfer)
            }

            DashboardCard(title: "Pairing", symbol: "qrcode") {
                Caption("Show the code again if you need to reconnect or are setting up "
                        + "Tennanova after reinstalling the phone app.")
                Button("Show pairing code") { showPairingAnyway = true }
                    .adaptiveGlassButton()
            }
        }
    }

    private var waiting: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 440), spacing: 18)],
                  alignment: .leading, spacing: 18) {
            DashboardCard(title: "Trying to reconnect", symbol: "antenna.radiowaves.left.and.right") {
                ConnectionAttemptRow()
                ReachabilityRows()
            }

            DashboardCard(title: "If it stays offline", symbol: "lightbulb.max") {
                Caption("Your phone must be able to reach one of the listed routes. Some "
                        + "networks block device-to-device traffic; USB or the phone's "
                        + "hotspot gets around that.")
                Button("Show pairing code") { showPairingAnyway = true }
                    .adaptiveGlassButton()
            }
        }
    }

    private var pairing: some View {
        VStack(spacing: 18) {
            SurfaceIcon(symbol: "qrcode.viewfinder", size: 58)
            VStack(spacing: 5) {
                Text("Scan with Tennanova on your phone")
                    .font(.title3.weight(.semibold))
                Text("The code securely introduces this Mac and your phone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            PairingCode(size: 250)
                .frame(maxWidth: 300)

            VStack(alignment: .leading, spacing: 8) {
                PairingStep(number: 1, text: "Open Tennanova on Android.")
                PairingStep(number: 2, text: "Choose Scan pairing code.")
                PairingStep(number: 3, text: "Approve the one-time Android setup prompts.")
            }
            .frame(maxWidth: 420, alignment: .leading)

            ConnectionAttemptRow()
            ReachabilityRows()

            if state.isPaired {
                Button("Back to device") { showPairingAnyway = false }
                    .adaptiveGlassButton()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .contentSurface(.card, cornerRadius: 26)
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gear")
            }
            .adaptiveGlassButton()

            Spacer()

            if state.isPaired {
                Menu {
                    Button("Show pairing code") { showPairingAnyway = true }
                    Divider()
                    Button("Unpair this phone…", role: .destructive) { confirmUnpair = true }
                } label: {
                    Label("Device actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .contentSurface(.card, cornerRadius: 22)
    }
}

private struct CapabilityRow: View {
    let text: String
    let symbol: String
    let available: Bool

    init(_ text: String, symbol: String, available: Bool) {
        self.text = text
        self.symbol = symbol
        self.available = available
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: available ? symbol : "minus.circle")
                .foregroundStyle(available ? AnyShapeStyle(Tenna.accent)
                                           : AnyShapeStyle(.tertiary))
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundStyle(available ? AnyShapeStyle(.primary)
                                           : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
            Image(systemName: available ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(available ? AnyShapeStyle(Color.green)
                                           : AnyShapeStyle(.tertiary))
        }
    }
}

private struct PairingStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Tenna.accent)
                .frame(width: 24, height: 24)
                .background(Tenna.accent.opacity(0.13), in: .circle)
            Text(text).font(.callout)
        }
    }
}
