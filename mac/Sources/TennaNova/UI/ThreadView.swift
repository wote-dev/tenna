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
                transcript(thread)
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer(thread) }
                    .navigationTitle(thread.title)
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
        .toolbar {
            if let thread {
                ToolbarItem(placement: .principal) { toolbarIdentity(thread) }
                ToolbarItem(placement: .primaryAction) { conversationMenu(thread) }
            }
        }
    }

    // MARK: - Header

    private func toolbarIdentity(_ thread: ConversationThread) -> some View {
        HStack(spacing: 10) {
            Avatar(image: state.icons[thread.iconHash],
                   monogram: thread.title.monogram, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title).font(.headline).lineLimit(1)
                Text(headerSubtitle(thread))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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

    @ViewBuilder
    private func conversationMenu(_ thread: ConversationThread) -> some View {
        if !key.isSms && hasConversationActions(thread) {
            Menu {
                if thread.isLiveOnPhone || state.supportsOfflineReply {
                    ForEach(thread.latestActions.filter { !$0.isReply }, id: \.id) { action in
                        Button(action.label) { state.invoke(action: action, in: key) }
                    }
                }
                if thread.isLiveOnPhone {
                    Divider()
                    Button("Clear on phone", systemImage: "bell.slash") {
                        state.dismissOnPhone(key)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Conversation actions")
        } else {
            EmptyView()
        }
    }

    private func hasConversationActions(_ thread: ConversationThread) -> Bool {
        let hasNotificationButtons = (thread.isLiveOnPhone || state.supportsOfflineReply)
            && thread.latestActions.contains { !$0.isReply }
        return hasNotificationButtons || thread.isLiveOnPhone
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
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tennaScrollEdge([.top, .bottom])
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
        VStack(alignment: .leading, spacing: 8) {
            if let reason = unavailableReason(thread) {
                StatusRow(reason, symbol: "info.circle")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentSurface(.inset, cornerRadius: 14)
            } else {
                HStack(spacing: 8) {
                    TextField("Message \(thread.title)", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .padding(.leading, 4)
                        .focused($composerFocused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 20, height: 20)
                    }
                    .adaptiveGlassButton(prominent: true)
                    .disabled(!canSend)
                    .help("Send message")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .adaptiveGlass(cornerRadius: 18)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    // Not `.controlBackgroundColor`: in dark mode that is within a
                    // percent of the window's own background, and the incoming bubbles
                    // simply vanished. A tint of the foreground reads in both appearances.
                    .background(isOurs ? Tenna.accentFill : Tenna.incomingBubble,
                                in: .rect(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(isOurs ? Color.white : Color.primary)
                    .overlay {
                        if !isOurs {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Tenna.surfaceBorder, lineWidth: 0.6)
                        }
                    }

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
        .animation(reduceMotion ? nil : .snappy(duration: 0.20), value: message.delivery)
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
