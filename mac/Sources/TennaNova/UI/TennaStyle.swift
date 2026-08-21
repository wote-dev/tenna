import SwiftUI

/// The handful of things every Tennanova view agrees on.
///
/// The UI folder had no shared layer at all: `MenuBarView` repeated the same
/// caption-Label-with-a-tint construction six times and the same wrapping incantation
/// eight. Two views could get away with that; a window, a sidebar, a transcript and a
/// device pane cannot. `android/.../ui/TennaTheme.kt` is the visual reference.
enum Tenna {
    /// The brand sky, matching `TennaTheme.kt`'s `primary`, so the two apps read as one
    /// product. Tints, dots and monograms only — see ``accentFill`` for anything that
    /// carries white text.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.490, green: 0.827, blue: 0.988, alpha: 1)   // #7DD3FC
            : NSColor(srgbRed: 0.008, green: 0.451, blue: 0.690, alpha: 1)   // #0273B0
    })

    /// The accent as a *fill behind white text* — message bubbles, unread badges.
    ///
    /// It does not follow the appearance, and that is the point. ``accent`` goes pale in
    /// dark mode so it stays visible as a tint on a dark ground, but white on that pale
    /// blue is about 1.6:1. Anything with white on top needs the fixed dark value, which
    /// carries white at 5.15:1.
    static let accentFill = Color(.sRGB, red: 0.008, green: 0.451, blue: 0.690, opacity: 1)

    /// Picks between two values by appearance.
    ///
    /// `Tenna.accent` and `Tenna.backdrop` above spell this out longhand because they were
    /// written before there was a second caller. Everything added since goes through here.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let canvasBase = dynamic(
        light: NSColor(srgbRed: 0.925, green: 0.949, blue: 0.980, alpha: 1),
        dark:  NSColor(srgbRed: 0.035, green: 0.051, blue: 0.086, alpha: 1)
    )

    static let skyGlow = dynamic(
        light: NSColor(srgbRed: 0.50, green: 0.80, blue: 0.98, alpha: 0.46),
        dark:  NSColor(srgbRed: 0.06, green: 0.36, blue: 0.62, alpha: 0.34)
    )

    static let lavenderGlow = dynamic(
        light: NSColor(srgbRed: 0.77, green: 0.66, blue: 0.96, alpha: 0.30),
        dark:  NSColor(srgbRed: 0.34, green: 0.20, blue: 0.58, alpha: 0.30)
    )

    static let warmGlow = dynamic(
        light: NSColor(srgbRed: 1.00, green: 0.78, blue: 0.60, alpha: 0.17),
        dark:  NSColor(srgbRed: 0.48, green: 0.22, blue: 0.20, alpha: 0.12)
    )

    static let surfaceBorder = dynamic(
        light: NSColor(srgbRed: 0.08, green: 0.12, blue: 0.20, alpha: 0.11),
        dark:  NSColor(white: 1, alpha: 0.18)
    )

    static let surfaceShadow = dynamic(
        light: NSColor(srgbRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.12),
        dark:  NSColor(white: 0, alpha: 0.30)
    )

    static let opaqueSurface = dynamic(
        light: NSColor(srgbRed: 0.965, green: 0.975, blue: 0.990, alpha: 1),
        dark:  NSColor(srgbRed: 0.090, green: 0.108, blue: 0.155, alpha: 1)
    )

    static let selectionFill = dynamic(
        light: NSColor(srgbRed: 0.12, green: 0.54, blue: 0.78, alpha: 0.18),
        dark:  NSColor(srgbRed: 0.35, green: 0.72, blue: 0.94, alpha: 0.20)
    )

    static let separator = dynamic(
        light: NSColor(srgbRed: 0.08, green: 0.12, blue: 0.20, alpha: 0.10),
        dark:  NSColor(white: 1, alpha: 0.10)
    )

    /// The fill behind a message from the other person.
    ///
    /// A flat `primary.opacity(0.09)` reads on a dark ground and all but disappears over
    /// `.ultraThinMaterial` on the light gradient, which left incoming bubbles shapeless.
    static let incomingBubble = dynamic(
        light: NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.10),
        dark:  NSColor(white: 1, alpha: 0.11)
    )

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

/// A quiet ambient canvas. The colour underneath material is what gives glass life; this
/// deliberately does not animate continuously, which keeps a utility window calm all day.
struct TennaBackdrop: View {
    var body: some View {
        ZStack {
            Tenna.canvasBase
            RadialGradient(colors: [Tenna.skyGlow, .clear],
                           center: .topLeading, startRadius: 30, endRadius: 620)
            RadialGradient(colors: [Tenna.lavenderGlow, .clear],
                           center: .bottomTrailing, startRadius: 20, endRadius: 700)
            RadialGradient(colors: [Tenna.warmGlow, .clear],
                           center: UnitPoint(x: 0.72, y: 0.10),
                           startRadius: 10, endRadius: 440)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

enum TennaSurfaceRole {
    case card
    case inset
}

/// Standard material belongs to content; Liquid Glass is reserved for controls and
/// navigation. Keeping those layers distinct prevents a screenful of equally shiny cards.
struct ContentSurface: ViewModifier {
    var role: TennaSurfaceRole = .card
    var cornerRadius: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let material = role == .card ? Material.thin : Material.ultraThin
        content
            .background(reduceTransparency ? AnyShapeStyle(Tenna.opaqueSurface)
                                           : AnyShapeStyle(material),
                        in: shape)
            .overlay(shape.strokeBorder(Tenna.surfaceBorder, lineWidth: 0.8))
            .shadow(color: Tenna.surfaceShadow,
                    radius: role == .card ? 18 : 8,
                    y: role == .card ? 8 : 3)
    }
}

/// An interactive layer. macOS 26 gets the system's optical Liquid Glass; macOS 14–15
/// receive the same geometry and hierarchy using standard material.
struct AdaptiveGlass: ViewModifier {
    var cornerRadius: CGFloat = 16
    var interactive = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(reduceTransparency ? AnyShapeStyle(Tenna.opaqueSurface)
                                               : AnyShapeStyle(Material.thin),
                            in: shape)
                .overlay(shape.strokeBorder(Tenna.surfaceBorder, lineWidth: 0.8))
                .shadow(color: Tenna.surfaceShadow, radius: 12, y: 5)
        }
    }
}

extension View {
    func contentSurface(_ role: TennaSurfaceRole = .card,
                        cornerRadius: CGFloat = 22) -> some View {
        modifier(ContentSurface(role: role, cornerRadius: cornerRadius))
    }

    func adaptiveGlass(cornerRadius: CGFloat = 16, interactive: Bool = true) -> some View {
        modifier(AdaptiveGlass(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// Kept as a source-compatible bridge while views migrate from the original modifier.
    func glassPanel(cornerRadius: CGFloat = 16) -> some View {
        contentSurface(.card, cornerRadius: cornerRadius)
    }

    @ViewBuilder
    func adaptiveGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func tennaBackgroundExtension() -> some View {
        if #available(macOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
    }

    @ViewBuilder
    func tennaScrollEdge(_ edges: Edge.Set) -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: edges)
        } else {
            self
        }
    }
}

struct SurfaceIcon: View {
    let symbol: String
    var tint: Color = Tenna.accent
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.40, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: .rect(cornerRadius: size * 0.32,
                                                       style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 0.8)
            }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint: Color = Tenna.accent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SurfaceIcon(symbol: symbol, tint: tint, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FriendlyEmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var tint: Color = Tenna.accent

    var body: some View {
        VStack(spacing: 12) {
            SurfaceIcon(symbol: symbol, tint: tint, size: 58)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .contentSurface(.card, cornerRadius: 24)
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
                    // Fixed white in both appearances, deliberately: a QR needs its light
                    // modules light and its quiet zone white, or a camera cannot read it.
                    .background(Color.white)
                    .padding(10)
                    .background(Color.white, in: .rect(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                    }
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
            .adaptiveGlassButton()
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
        .clipShape(.rect(cornerRadius: size * 0.32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .strokeBorder(Tenna.surfaceBorder, lineWidth: 0.7)
        }
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
