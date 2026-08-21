import SwiftUI
import AppKit

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

/// Pure search decision so filtering stays predictable and testable independently of UI.
enum InboxFilter {
    static func matches(_ thread: ConversationThread, query: String) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }

        let fields = [
            thread.title,
            thread.preview,
            thread.appLabel,
            thread.pkg,
            thread.smsAddress ?? ""
        ]
        return fields.contains { normalized($0).contains(needle) }
    }

    static func apply(_ threads: [ConversationThread], query: String) -> [ConversationThread] {
        threads.filter { matches($0, query: query) }
    }

    static func apply(tab: InboxTab,
                      messages: [ConversationThread],
                      notifications: [ConversationThread],
                      query: String) -> [ConversationThread] {
        apply(tab == .messages ? messages : notifications, query: query)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    let searchRequest: Int
    let compose: () -> Void
    @State private var tab: InboxTab = .messages
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var rows: [ConversationThread] {
        InboxFilter.apply(tab: tab,
                          messages: state.history.conversations,
                          notifications: state.history.alerts,
                          query: searchText)
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                deviceRow
                    .tag(SidebarItem.device)
                    .listRowBackground(selection == .device ? Tenna.selectionFill : .clear)
                callsRow
                    .tag(SidebarItem.calls)
                    .listRowBackground(selection == .calls ? Tenna.selectionFill : .clear)
                filesRow
                    .tag(SidebarItem.files)
                    .listRowBackground(selection == .files ? Tenna.selectionFill : .clear)
            }

            Section {
                tabs

                if rows.isEmpty {
                    sidebarEmpty
                } else {
                    ForEach(rows) { thread in
                        ConversationRow(thread: thread)
                            .tag(SidebarItem.thread(thread.id))
                            .listRowBackground(selection == .thread(thread.id)
                                               ? Tenna.selectionFill : .clear)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Tennanova")
        .searchable(text: $searchText,
                    placement: .sidebar,
                    prompt: "Search \(tab.title.lowercased())")
        .tennaSearchFocused($searchFocused)
        // The sidebar's own material would otherwise sit opaquely on top of the window's
        // gradient; hidden, the List draws only its rows and the gradient shows through.
        .scrollContentBackground(.hidden)
        .tint(Tenna.accent.opacity(0.82))
        // Selecting a thread from a Mac notification, or starting a new text, can land on
        // a conversation the other tab holds. Following it keeps the sidebar from showing
        // no selection at all while the detail pane shows a thread.
        .onChange(of: selection) { _, new in
            guard case .thread(let key) = new,
                  let thread = state.history.log[key] else { return }
            tab = thread.isChat ? .messages : .notifications
        }
        .onChange(of: searchRequest) { _, _ in focusSearch() }
    }

    /// The two-way switch, and the compose button that belongs to one side of it.
    ///
    /// `selectionDisabled` matters: without it the row holding the switch is itself a
    /// selectable sidebar item, and clicking the switch clears whichever conversation was
    /// open behind it.
    private var tabs: some View {
        VStack(spacing: 8) {
            Picker("Inbox", selection: $tab) {
                ForEach(InboxTab.allCases, id: \.self) { item in
                    Text(label(for: item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == .messages {
                Button {
                    compose()
                } label: {
                    Label("New message", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveGlassButton(prominent: true)
                .disabled(!state.supportsSms)
                .help("Text someone new")
                .accessibilityLabel("New text message")
            }
        }
        .padding(.vertical, 6)
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
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No \(tab.title.lowercased()) match “\(searchText)”."
        }
        guard state.status.isConnected else {
            return "Connect your phone to start mirroring what it shows you."
        }
        return tab == .messages
            ? "Texts and chats from your phone will appear here."
            : "Everything else your phone shows you — deliveries, backups, app alerts — "
              + "will appear here."
    }

    private func focusSearch() {
        if #available(macOS 15.0, *) {
            searchFocused = true
        } else {
            // `searchFocused` arrived after our macOS 14 deployment target. The
            // searchable modifier still installs an NSSearchField there, so focus that
            // native control directly for the same Command-F behaviour.
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow,
                      let search = window.contentView?.firstDescendant(of: NSSearchField.self)
                else { return }
                window.makeFirstResponder(search)
            }
        }
    }

    private var sidebarEmpty: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.title3)
                .foregroundStyle(Tenna.accent)
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .selectionDisabled()
    }

    /// The way in to the Calls pane, and the only place a ringing phone shows in the
    /// sidebar — the banner, the menu bar and the Notification Center card do the shouting.
    private var filesRow: some View {
        let moving = state.transfers.running.count
        return HStack(spacing: 10) {
            SurfaceIcon(symbol: moving > 0 ? "arrow.up.arrow.down.circle.fill" : "folder.fill",
                        tint: moving > 0 ? Tenna.accent : .secondary,
                        size: 34)
                .symbolEffect(.pulse, isActive: moving > 0)
            VStack(alignment: .leading, spacing: 1) {
                Text("Files")
                Text(filesSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if state.transfers.unseen > 0 {
                UnreadBadge(count: state.transfers.unseen)
            }
        }
    }

    private var filesSubtitle: String {
        let moving = state.transfers.running.count
        if moving == 1 { return "1 transfer running" }
        if moving > 1 { return "\(moving) transfers running" }
        if !state.supportsFileTransfer { return "Not supported by this phone" }
        return "Drop files here to send them"
    }

    private var callsRow: some View {
        HStack(spacing: 10) {
            SurfaceIcon(symbol: state.calls.isRinging
                        ? "phone.badge.waveform.fill" : "phone.fill",
                        tint: state.calls.isRinging ? Tenna.accent : .secondary,
                        size: 34)
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
        if !state.supportsCalls { return "Off on your phone" }
        return "Ready when your phone rings"
    }

    private var deviceRow: some View {
        HStack(spacing: 10) {
            SurfaceIcon(symbol: state.status.isConnected ? "iphone" : "iphone.slash",
                        tint: state.status.isConnected ? Tenna.accent : .secondary,
                        size: 34)
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

private struct SearchFocusCompatibility: ViewModifier {
    let focus: FocusState<Bool>.Binding

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused(focus)
        } else {
            content
        }
    }
}

private extension View {
    func tennaSearchFocused(_ focus: FocusState<Bool>.Binding) -> some View {
        modifier(SearchFocusCompatibility(focus: focus))
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for child in subviews {
            if let match = child.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

struct ConversationRow: View {
    @Environment(AppState.self) private var state
    let thread: ConversationThread

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(image: state.icons[thread.latest?.avatarHash] ?? state.icons[thread.iconHash],
                   monogram: thread.title.monogram,
                   size: 36)

            VStack(alignment: .leading, spacing: 3) {
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
                        .lineLimit(1)
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
        .padding(.vertical, 5)
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
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "New text message",
                       subtitle: "Start an SMS conversation through your phone.",
                       symbol: "message.fill")
            Caption("Texts go out through your phone's radio. Picture messages are not "
                    + "supported — those stay on the phone.")

            TextField("Phone number", text: $address)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .adaptiveGlass(cornerRadius: 14)
                .focused($focused)
                .onSubmit(start)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                    .adaptiveGlassButton(prominent: true)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(TennaBackdrop())
        .onAppear { focused = true }
    }

    private func start() {
        guard canStart else { return }
        onStart(address.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}
