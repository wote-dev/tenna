import SwiftUI

/// The handful of things every Tennanova view agrees on.
///
/// The UI folder had no shared layer at all: `MenuBarView` repeated the same
/// caption-Label-with-a-tint construction six times and the same wrapping incantation
/// eight. Two views could get away with that; a window, a sidebar, a transcript and a
/// device pane cannot. `android/.../ui/TennaTheme.kt` is the visual reference.
enum Tenna {
    /// The brand teal, matching `TennaTheme.kt`'s seed. Light and dark values are the
    /// Material scheme's `primary` in each, so the two apps read as one product.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.424, green: 0.847, blue: 0.737, alpha: 1)   // #6CD8BC
            : NSColor(srgbRed: 0.000, green: 0.420, blue: 0.353, alpha: 1)   // #006B5A
    })

    static func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<15:  return "battery.25"
        case ..<50:  return "battery.50"
        case ..<85:  return "battery.75"
        default:     return "battery.100"
        }
    }

    /// Sidebar timestamps: a time for today, a word for yesterday, a date beyond that.
    /// A relative style ("2 hours ago") reads worse in a narrow column and re-renders
    /// every minute for no gain.
    static func shortStamp(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Android package name → something a person recognises, for the rare thread whose
    /// notifications never carried an app label.
    static func appName(_ pkg: String, fallback: String) -> String {
        fallback.isEmpty ? (pkg.split(separator: ".").last.map(String.init) ?? pkg) : fallback
    }
}

/// One line of status: a symbol, a sentence, a tint.
///
/// The `fixedSize` is not decoration — without it these truncate to a single line inside a
/// 280pt popover, and the sentence explaining what went wrong is the half that disappears.
///
/// The line cap is not decoration either, and it is the more expensive lesson. `fixedSize`
/// makes a view report the height its text needs *at its ideal width*, and inside a
/// `NavigationSplitView` that width is not yet resolved when the split view measures its
/// panes. A 140-character sentence measured at a near-zero width is a hundred-odd lines
/// tall, and the split view believed it: it sized its panes to 1636pt inside a 640pt
/// window, drawing the sidebar and the transcript entirely above the visible area. The
/// cap bounds that measurement. It is generous enough that nothing here truncates at any
/// width these views are actually drawn at.
struct StatusRow: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary
    var font: Font = .caption

    static let maxLines = 6

    init(_ text: String, symbol: String, tint: Color = .secondary, font: Font = .caption) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.font = font
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(font)
            .foregroundStyle(tint)
            .lineLimit(Self.maxLines)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Explanatory prose, which wraps rather than truncating. Line-capped for the reason
/// described on `StatusRow`.
struct Caption: View {
    let text: String

    static let maxLines = 8

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(Self.maxLines)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Where this Mac can be reached, in the order the phone will try. Shared because the
/// menu bar and the Device pane must never disagree about it.
struct ReachabilityRows: View {
    @Environment(AppState.self) private var state
    var showHosts = true

    var body: some View {
        if showHosts {
            StatusRow(
                state.advertisedHosts.isEmpty
                    ? "Waiting for a local network address."
                    : "Ready on \(state.advertisedHosts.joined(separator: ", "))",
                symbol: "network"
            )
        }

        StatusRow(state.usbStatus.label,
                  symbol: state.usbStatus.isReady ? "cable.connector" : "wifi",
                  tint: state.usbStatus.isReady ? Tenna.accent : .secondary)

        // The relay is what makes "any network" true rather than aspirational, so its
        // state is reported plainly rather than hidden until something fails.
        StatusRow(state.relayStatus.label,
                  symbol: state.relayStatus.isOnline ? "globe" : "globe.badge.chevron.backward",
                  tint: state.relayStatus.isOnline ? Tenna.accent : .secondary)
    }
}

/// What the server is doing right now, or that it is doing nothing and waiting.
struct ConnectionAttemptRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let attempt = state.serverActivity.label {
            StatusRow(attempt,
                      symbol: state.serverActivity.isAttempting
                          ? "arrow.triangle.2.circlepath"
                          : "exclamationmark.triangle",
                      tint: state.serverActivity.isAttempting ? .orange : .red)
        } else {
            StatusRow("Listening for a phone connection…",
                      symbol: "antenna.radiowaves.left.and.right")
        }
    }
}

/// The pairing QR and its copy-to-clipboard escape hatch.
struct PairingCode: View {
    @Environment(AppState.self) private var state
    var size: CGFloat = 200
    @State private var copied = false

    var body: some View {
        VStack(spacing: 10) {
            if let img = QRCode.image(from: state.pairingPayload) {
                Image(nsImage: img)
                    // Nearest-neighbour: a QR is the one image that interpolation makes
                    // measurably harder for a camera to read.
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
                    .background(Color.white)
                    .cornerRadius(6)
            } else {
                Text("Could not generate the pairing code.")
                    .font(.caption)
                    .foregroundStyle(.red)
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
        .frame(maxWidth: .infinity)
    }
}

/// A thread's picture: the sender's photo when the phone has sent one, the app's icon
/// otherwise, and a tinted monogram when neither has arrived yet.
///
/// The fallback matters more than it looks. Icons are requested only after the message
/// they belong to is already on screen, so the first sighting of any app or contact is
/// always drawn without one.
struct Avatar: View {
    let image: NSImage?
    let monogram: String
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Tenna.accent.opacity(0.18)
                    .overlay(
                        Text(monogram)
                            .font(.system(size: size * 0.42, weight: .medium))
                            .foregroundStyle(Tenna.accent)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.28))
    }
}

extension String {
    /// First letter of the first two words — "Sam Whitfield" → "SW", "WhatsApp" → "W".
    var monogram: String {
        let words = split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
