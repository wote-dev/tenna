import SwiftUI

/// Which of the two lists the sidebar is showing.
///
/// A tab and not a second section, because the two do not compete for the same attention:
/// messages are read and answered, notifications are glanced at. Stacked in one scroller
/// they still share a scrollbar, and a day of deliveries, backups and promotions still
/// pushes the conversations off the bottom of it. One at a time is the only arrangement
/// where the messages list is the whole list.
enum InboxTab: Hashable, CaseIterable {
    case messages
    case notifications

    var title: String {
        switch self {
        case .messages:      return "Messages"
        case .notifications: return "Notifications"
        }
    }
}

/// The sidebar: the phone and calls pinned at the top, then one of the two inboxes.
///
/// The split between messages and notifications is not a new judgement — it is the one
/// the notifications themselves already carry. See `ConversationThread.isChat`.
///
/// `ConversationLog` sorts and counts; this only draws.
struct ConversationList: View {
    @Environment(AppState.self) private var state
    @Binding var selection: SidebarItem?
    @State private var newMessage = false
    @State private var tab: InboxTab = .messages

    private var rows: [ConversationThread] {
        tab == .messages ? state.history.conversations : state.history.alerts
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                deviceRow.tag(SidebarItem.device)
            }

            // Only once there is something to say. An empty Calls row on a phone that has
            // never rung is a permanent reminder of a feature doing nothing.
            if state.supportsCalls || !state.calls.recents.isEmpty {
                Section {
                    callsRow.tag(SidebarItem.calls)
                }
            }

            Section {
                tabs

                if rows.isEmpty {
                    Caption(emptyMessage)
                        .padding(.vertical, 4)
                } else {
                    ForEach(rows) { thread in
                        ConversationRow(thread: thread)
                            .tag(SidebarItem.thread(thread.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // The sidebar's own material would otherwise sit opaquely on top of the window's
        // gradient; hidden, the List draws only its rows and the gradient shows through.
        .scrollContentBackground(.hidden)
        // Selecting a thread from a Mac notification, or starting a new text, can land on
        // a conversation the other tab holds. Following it keeps the sidebar from showing
        // no selection at all while the detail pane shows a thread.
        .onChange(of: selection) { _, new in
            guard case .thread(let key) = new,
                  let thread = state.history.log[key] else { return }
            tab = thread.isChat ? .messages : .notifications
        }
        .sheet(isPresented: $newMessage) {
            NewMessageSheet { address in
                guard let key = state.startSmsConversation(address: address) else { return }
                selection = .thread(key)
            }
        }
    }

    /// The two-way switch, and the compose button that belongs to one side of it.
    ///
    /// `selectionDisabled` matters: without it the row holding the switch is itself a
    /// selectable sidebar item, and clicking the switch clears whichever conversation was
    /// open behind it.
    private var tabs: some View {
        HStack(spacing: 6) {
            Picker("Inbox", selection: $tab) {
                ForEach(InboxTab.allCases, id: \.self) { item in
                    Text(label(for: item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if state.supportsSms, tab == .messages {
                Button {
                    newMessage = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("Text someone new")
            }
        }
        .padding(.vertical, 4)
        .selectionDisabled()
    }

    /// The count rides in the segment's own label. A segmented control has no room for a
    /// badge view, and a tab whose unread count is only visible once you switch to it is
    /// not doing the one job a tab has.
    private func label(for item: InboxTab) -> String {
        let unread = item == .messages
            ? state.history.conversationUnread
            : state.history.alertUnread
        return unread > 0 ? "\(item.title) (\(unread > 99 ? "99+" : "\(unread)"))"
                          : item.title
    }

    private var emptyMessage: String {
        guard state.status.isConnected else {
            return "Connect your phone to start mirroring what it shows you."
        }
        return tab == .messages
            ? "Texts and chats from your phone will appear here."
            : "Everything else your phone shows you — deliveries, backups, app alerts — "
              + "will appear here."
    }

    /// The way in to the Calls pane, and the only place a ringing phone shows in the
    /// sidebar — the banner, the menu bar and the Notification Center card do the shouting.
    private var callsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: state.calls.isRinging ? "phone.badge.waveform.fill" : "phone")
                .foregroundStyle(state.calls.isRinging ? Tenna.accent : .secondary)
                .symbolEffect(.pulse, isActive: state.calls.isRinging)
            VStack(alignment: .leading, spacing: 1) {
                Text("Calls")
                Text(callsSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if state.calls.missedCount > 0 {
                UnreadBadge(count: state.calls.missedCount)
            }
        }
    }

    private var callsSubtitle: String {
        if let call = state.calls.current {
            switch call.state {
            case .ringing: return "\(call.title) is calling"
            case .active:  return "On a call with \(call.title)"
            case .ended:   break
            }
        }
        if let last = state.calls.recents.first {
            return last.isMissed ? "Missed · \(last.title)" : last.title
        }
        return "No calls yet"
    }

    private var deviceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: state.status.isConnected ? "iphone" : "iphone.slash")
                .foregroundStyle(state.status.isConnected ? Tenna.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.pairedDeviceName ?? "Phone")
                Text(deviceSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let battery = state.battery {
                Image(systemName: Tenna.batteryIcon(battery))
                    .foregroundStyle(battery < 15 ? .red : .secondary)
                    .help("\(battery)%\(state.charging ? " — charging" : "")")
            }
        }
    }

    private var deviceSubtitle: String {
        if state.status.isConnected { return "Connected" }
        if state.serverActivity.isAttempting { return "Connecting…" }
        return state.isPaired ? "Waiting" : "Not paired"
    }
}

struct ConversationRow: View {
    @Environment(AppState.self) private var state
    let thread: ConversationThread

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Avatar(image: state.icons[thread.latest?.avatarHash] ?? state.icons[thread.iconHash],
                   monogram: thread.title.monogram)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(thread.title)
                        .lineLimit(1)
                        .fontWeight(thread.unreadCount > 0 ? .semibold : .regular)
                    Spacer(minLength: 0)
                    Text(Tenna.shortStamp(thread.lastActivity))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 6) {
                    Text(thread.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if thread.unreadCount > 0 {
                        UnreadBadge(count: thread.unreadCount)
                    }
                }

                Text(thread.id.isSms
                     ? "Text message"
                     : Tenna.appName(thread.pkg, fallback: thread.appLabel))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Tenna.accentFill, in: .capsule)
    }
}

/// Starting a conversation with a number that has no thread yet — the thing a notification
/// mirror fundamentally cannot do, and the reason the SMS channel exists.
struct NewMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onStart: (String) -> Void

    @State private var address = ""
    @FocusState private var focused: Bool

    private var canStart: Bool {
        SmsAddressMatch.normalize(address).contains(where: \.isNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New text message").font(.headline)
            Caption("Texts go out through your phone's radio. Picture messages are not "
                    + "supported — those stay on the phone.")

            TextField("Phone number", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(start)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func start() {
        guard canStart else { return }
        onStart(address.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}
