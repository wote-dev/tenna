import SwiftUI

/// The Calls pane: whatever is happening right now, then what has happened.
///
/// One sentence appears on every surface that offers a call button, and it is not
/// decoration: **the audio stays on the phone**. Android lets no third-party app capture
/// voice-call audio, so this Mac presses the phone's buttons and nothing more. Someone who
/// answers here and then hears silence has been misled by this app, and no amount of
/// otherwise-good design makes up for that.
struct CallsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Calls",
                           subtitle: "Answer and manage calls through your phone.",
                           symbol: "phone.fill",
                           tint: state.calls.isRinging ? .green : Tenna.accent)

                ForEach(state.calls.live) { call in
                    CallCard(call: call)
                }

                if state.calls.live.isEmpty {
                    idle
                }

                if !state.calls.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Recent").font(.headline)
                            Spacer()
                            Button("Clear") { state.calls.clearRecents() }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            ForEach(state.calls.recents) { call in
                                CallRow(call: call)
                                if call.id != state.calls.recents.last?.id { Divider() }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .contentSurface(.card, cornerRadius: 22)

                        Caption("Calls seen while this Mac was connected. The phone's own "
                                + "call log is not read — that would need a permission "
                                + "Tennanova does not ask for.")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .tennaScrollEdge(.top)
        .navigationTitle("Calls")
        .task { state.calls.markRecentsSeen() }
        // A call ending while this pane is open is being read as it lands, so the sidebar
        // badge must not start climbing behind the reader's back.
        .onChange(of: state.calls.recents.first?.id) { _, _ in
            state.calls.markRecentsSeen()
        }
    }

    /// Nothing ringing. Which of the three reasons it is decides what is worth saying.
    @ViewBuilder
    private var idle: some View {
        if !state.status.isConnected {
            FriendlyEmptyState(title: "Waiting for your phone",
                               message: "Calls arrive over the same secure connection as "
                                        + "your messages and notifications.",
                               symbol: "iphone.slash")
        } else if !state.supportsCalls {
            FriendlyEmptyState(title: "Calls are off on your phone",
                               message: "Turn Calls on in Tennanova on Android. It needs no "
                                        + "additional permission there.",
                               symbol: "phone.badge.waveform",
                               tint: .secondary)
        } else {
            FriendlyEmptyState(title: "Ready when your phone rings",
                               message: "Phone, WhatsApp and Signal calls can be answered or "
                                        + "declined here. Audio stays on your phone.",
                               symbol: "phone")
        }
    }
}

/// A live call, at the size something ringing deserves.
struct CallCard: View {
    @Environment(AppState.self) private var state
    let call: MirroredCall

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Avatar(image: state.icons[call.avatarHash] ?? state.icons[call.iconHash],
                       monogram: call.title.monogram, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(call.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(call.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    CallStatusLine(call: call)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                if call.canAnswer {
                    Button {
                        state.perform(.answer, on: call)
                    } label: {
                        Label("Answer", systemImage: "phone.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .adaptiveGlassButton(prominent: true)
                    .tint(.green)
                    .keyboardShortcut(.defaultAction)
                }
                if call.canDecline {
                    Button(role: .destructive) {
                        state.perform(.decline, on: call)
                    } label: {
                        Label("Decline", systemImage: "phone.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .adaptiveGlassButton()
                }
                if call.canHangUp {
                    Button(role: .destructive) {
                        state.perform(.hangup, on: call)
                    } label: {
                        Label("Hang up", systemImage: "phone.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .adaptiveGlassButton()
                }
            }

            // The dialer's own extra buttons. They fire the phone's `PendingIntent`, so
            // what they do happens on the phone — "Message" opens the phone's messaging
            // app there, not here.
            if !call.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(call.actions.filter { !$0.isReply }, id: \.id) { action in
                        Button(action.label) { state.invoke(action: action, on: call) }
                            .controlSize(.small)
                    }
                }
            }

            if let failure = call.failure {
                StatusRow(failure, symbol: "exclamationmark.triangle.fill", tint: .red)
            }

            if !call.canAnswer && !call.canDecline && !call.canHangUp {
                Caption("This call cannot be answered from the Mac: the dialer put no "
                        + "buttons in its notification. Allow call access in Tennanova on "
                        + "the phone and Tennanova can answer it itself.")
            } else {
                Caption("The audio stays on your phone — Android lets no app carry it "
                        + "away. Answering here picks up there.")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface(.card, cornerRadius: 24)
    }
}

/// "Ringing", or how long the call has been going. Its own view so the ticking clock
/// redraws one line rather than the whole card.
struct CallStatusLine: View {
    let call: MirroredCall

    var body: some View {
        switch call.state {
        case .ringing:
            Label(call.isVideo ? "Incoming video call" : "Incoming call",
                  systemImage: "phone.arrow.down.left.fill")
                .font(.caption)
                .foregroundStyle(Tenna.accent)
        case .active:
            if let answered = call.answeredAt {
                // Measured from when this Mac saw the call connect, which is the only
                // start time it can honestly claim.
                TimelineView(.periodic(from: answered, by: 1)) { context in
                    Label(Self.elapsed(since: answered, now: context.date),
                          systemImage: "waveform")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("On the phone", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ended:
            Label("Ended", systemImage: "phone.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = seconds / 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }
}

/// One finished call.
struct CallRow: View {
    @Environment(AppState.self) private var state
    let call: MirroredCall

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(call.isMissed ? Color.red : .secondary)
                .frame(width: 16)
            Avatar(image: state.icons[call.avatarHash] ?? state.icons[call.iconHash],
                   monogram: call.title.monogram, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.title)
                    .lineLimit(1)
                    .foregroundStyle(call.isMissed ? Color.red : .primary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(Tenna.shortStamp(call.endedAt ?? call.when))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    private var symbol: String {
        if call.isMissed { return "phone.down.fill" }
        return call.direction == .incoming
            ? "phone.arrow.down.left.fill"
            : "phone.arrow.up.right.fill"
    }

    private var label: String {
        let kind = call.isMissed
            ? "Missed"
            : (call.direction == .incoming ? "Incoming" : "Outgoing")
        return "\(kind) · \(Tenna.appName(call.pkg, fallback: call.appLabel))"
    }
}

/// The live call, on top of whatever else the window is showing.
///
/// A ringing phone is the one thing in this app that cannot wait for the user to go and
/// look for it, and the Notification Center card only helps when the window is not the
/// thing being looked at.
struct CallBanner: View {
    @Environment(AppState.self) private var state
    let call: MirroredCall
    /// Jumps to the Calls pane, where the whole card and the dialer's extra buttons live.
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Avatar(image: state.icons[call.avatarHash] ?? state.icons[call.iconHash],
                   monogram: call.title.monogram, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.title).fontWeight(.semibold).lineLimit(1)
                CallStatusLine(call: call)
            }
            Spacer(minLength: 8)

            if call.canAnswer {
                Button { state.perform(.answer, on: call) } label: {
                    Label("Answer", systemImage: "phone.fill")
                }
                .adaptiveGlassButton(prominent: true)
                .tint(.green)
            }
            if call.canDecline {
                Button(role: .destructive) { state.perform(.decline, on: call) } label: {
                    Image(systemName: "phone.down.fill")
                }
                .help("Decline")
            }
            if call.canHangUp {
                Button(role: .destructive) { state.perform(.hangup, on: call) } label: {
                    Image(systemName: "phone.down.fill")
                }
                .help("Hang up")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .adaptiveGlass(cornerRadius: 18)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
