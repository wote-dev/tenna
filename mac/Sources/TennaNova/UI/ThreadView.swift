import SwiftUI

/// One conversation: its transcript, and a composer that goes through the same
/// `AppState.reply(to:text:)` a notification's Reply button does.
struct ThreadView: View {
    @Environment(AppState.self) private var state
    let key: ConversationKey

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var thread: ConversationThread? { state.history.log[key] }

    var body: some View {
        Group {
            if let thread {
                VStack(spacing: 0) {
                    header(thread)
                    Divider()
                    transcript(thread)
                    Divider()
                    composer(thread)
                }
            } else {
                // The log evicts the oldest threads past its cap, so a selection can
                // outlive what it points at.
                ContentUnavailableView("Conversation gone",
                                       systemImage: "bubble.left.and.exclamationmark.bubble.right",
                                       description: Text("This conversation is no longer in the history."))
            }
        }
        .task {
            state.history.markRead(key)
            // Summaries carry a snippet, not a transcript, so a thread opened for the
            // first time has to ask for its history.
            state.loadSmsThread(key)
        }
        // Messages arriving while the thread is open are being read as they land, so the
        // badge must not start climbing behind the reader's back. Converges immediately —
        // `markRead` sets the count to zero and a zero count changes nothing.
        .onChange(of: thread?.messages.count) { _, _ in
            if thread?.unreadCount ?? 0 > 0 { state.history.markRead(key) }
        }
    }

    // MARK: - Header

    private func header(_ thread: ConversationThread) -> some View {
        HStack(spacing: 10) {
            Avatar(image: state.icons[thread.iconHash],
                   monogram: thread.title.monogram, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title).font(.headline)
                Text(headerSubtitle(thread))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actionButtons(thread)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// SMS threads say the number, which is the useful thing when a contact has several
    /// or when there is no contact at all. Everything else says which app it came from.
    private func headerSubtitle(_ thread: ConversationThread) -> String {
        if key.isSms {
            guard let address = thread.smsAddress else { return "Text message" }
            return address == thread.title ? "Text message" : address
        }
        return Tenna.appName(thread.pkg, fallback: thread.appLabel)
    }

    /// The notification's own non-reply buttons — "Mark as read", "Archive". They are
    /// positional indices into the latest post, which is why they come from the thread
    /// rather than from any message.
    @ViewBuilder
    private func actionButtons(_ thread: ConversationThread) -> some View {
        // An SMS thread has no notification behind it, so none of this applies to one.
        if key.isSms {
            EmptyView()
        } else {
            notificationActionButtons(thread)
        }
    }

    @ViewBuilder
    private func notificationActionButtons(_ thread: ConversationThread) -> some View {
        // These fire the same retained PendingIntents the composer does, so they keep
        // working after the notification is gone. Clearing one that is already gone does
        // not, which is why the bell is the only thing still gated on it.
        if thread.isLiveOnPhone || state.supportsOfflineReply {
            ForEach(thread.latestActions.filter { !$0.isReply }, id: \.id) { action in
                Button(action.label) { state.invoke(action: action, in: key) }
                    .controlSize(.small)
            }
        }
        if thread.isLiveOnPhone {
            Button {
                state.dismissOnPhone(key)
            } label: {
                Image(systemName: "bell.slash")
            }
            .controlSize(.small)
            .help("Clear this notification on the phone")
        }
    }

    // MARK: - Transcript

    private func transcript(_ thread: ConversationThread) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(thread.messages) { message in
                        MessageBubble(message: message, threadTitle: thread.title)
                            .id(message.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: thread.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                // Unanimated, and after the rows exist: `scrollTo` during the same pass
                // that builds the LazyVStack is scrolling to an anchor that is not there.
                guard let id = thread.messages.last?.id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    // MARK: - Composer

    @ViewBuilder
    private func composer(_ thread: ConversationThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = unavailableReason(thread) {
                StatusRow(reason, symbol: "info.circle")
            } else {
                HStack(spacing: 8) {
                    TextField("Message \(thread.title)", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? Tenna.accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.status.isConnected
    }

    /// Why the composer is missing, in the user's terms. Silence would read as a bug.
    ///
    /// Ordered from the most permanent reason to the most temporary, so the message names
    /// the thing the user would actually have to change.
    private func unavailableReason(_ thread: ConversationThread) -> String? {
        if key.isSms {
            guard state.supportsSms else {
                return "Turn on Text messages in Tennanova on your phone to send from here."
            }
            guard thread.smsAddress != nil else {
                return "This conversation has no number to reply to."
            }
            return state.status.isConnected
                ? nil
                : "Waiting for the phone — texts are sent by its radio."
        }
        guard thread.latestActions.contains(where: { $0.isReply }) else {
            return "\(Tenna.appName(thread.pkg, fallback: thread.appLabel)) does not offer "
                 + "an inline reply on this notification."
        }
        if state.history.replyTarget(for: key,
                                     allowingWithdrawn: state.supportsOfflineReply) == nil {
            guard state.supportsOfflineReply else {
                return "This notification has been cleared on the phone, and the Tennanova "
                     + "build on it can only reply while a notification is still showing. "
                     + "The next message in this chat restores it."
            }
            // The phone holds the reply intent in its listener process, so restarting the
            // Android app loses every conversation the user had already cleared.
            return "This chat was cleared on the phone before Tennanova last restarted "
                 + "there, so the phone no longer holds a way to reply to it. The next "
                 + "message in this chat restores it."
        }
        if !state.status.isConnected {
            return "Waiting for the phone — replies need a live connection."
        }
        return nil
    }

    private func send() {
        guard canSend else { return }
        state.reply(to: key, text: draft)
        draft = ""
        composerFocused = true
    }
}

/// One message. Ours on the right in brand teal, the phone's on the left.
struct MessageBubble: View {
    @Environment(AppState.self) private var state
    let message: MirroredMessage
    let threadTitle: String

    private var isOurs: Bool { message.origin == .mac }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOurs { Spacer(minLength: 60) }

            if !isOurs {
                Avatar(image: state.icons[message.avatarHash],
                       monogram: (message.senderName ?? threadTitle).monogram, size: 26)
            }

            VStack(alignment: isOurs ? .trailing : .leading, spacing: 2) {
                // Only worth naming when it is not simply the other half of a 1:1 chat.
                if let sender = message.senderName, !isOurs, sender != threadTitle {
                    Text(sender)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    // Not `.controlBackgroundColor`: in dark mode that is within a
                    // percent of the window's own background, and the incoming bubbles
                    // simply vanished. A tint of the foreground reads in both appearances.
                    .background(isOurs ? Tenna.accentFill : Color.primary.opacity(0.09),
                                in: .rect(cornerRadius: 12))
                    .foregroundStyle(isOurs ? Color.white : Color.primary)

                HStack(spacing: 4) {
                    Text(message.when.formatted(date: .omitted, time: .shortened))
                    if let receipt = Self.receipt(message.delivery) {
                        Image(systemName: receipt.symbol)
                        Text(receipt.label)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Self.isFailure(message.delivery) ? Color.red : .secondary)
            }

            if !isOurs { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: isOurs ? .trailing : .leading)
    }

    /// `sent` and `confirmed` are deliberately different words. The protocol has no ack
    /// for `notif.reply`, so "Sent" is the strongest honest claim until the phone mirrors
    /// the message back — which is what earns "Delivered".
    static func receipt(_ state: DeliveryState) -> (symbol: String, label: String)? {
        switch state {
        case .incoming:          return nil
        case .sending:           return ("clock", "Sending")
        case .sent:              return ("checkmark", "Sent")
        case .confirmed:         return ("checkmark.circle.fill", "Delivered")
        case .failed(let why):   return ("exclamationmark.triangle.fill", why)
        }
    }

    static func isFailure(_ state: DeliveryState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
