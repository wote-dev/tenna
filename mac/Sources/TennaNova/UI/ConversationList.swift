import SwiftUI

/// The sidebar: the phone, then every conversation the phone has mirrored, most recent
/// first. `ConversationLog` already sorts and counts; this only draws.
struct ConversationList: View {
    @Environment(AppState.self) private var state
    @Binding var selection: SidebarItem?
    @State private var newMessage = false

    var body: some View {
        List(selection: $selection) {
            Section {
                deviceRow.tag(SidebarItem.device)
            }

            Section {
                if state.history.threads.isEmpty {
                    Caption(state.status.isConnected
                            ? "Messages your phone shows you will appear here."
                            : "Connect your phone to start mirroring its notifications.")
                        .padding(.vertical, 4)
                } else {
                    ForEach(state.history.threads) { thread in
                        ConversationRow(thread: thread)
                            .tag(SidebarItem.thread(thread.id))
                    }
                }
            } header: {
                HStack {
                    Text("Messages")
                    Spacer()
                    if state.history.totalUnread > 0 {
                        UnreadBadge(count: state.history.totalUnread)
                    }
                    if state.supportsSms {
                        Button {
                            newMessage = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .buttonStyle(.plain)
                        .help("Text someone new")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $newMessage) {
            NewMessageSheet { address in
                guard let key = state.startSmsConversation(address: address) else { return }
                selection = .thread(key)
            }
        }
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
            .background(Tenna.accent, in: .capsule)
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
