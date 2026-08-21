import SwiftUI

/// What the sidebar can be showing. The phone sits in the same list as the conversations
/// rather than behind a mode switch, because it is where pairing, addresses and battery
/// live and those are needed most often precisely when there are no conversations yet.
enum SidebarItem: Hashable {
    case device
    /// Calls get a pane of their own rather than a row in the inbox. A call has no
    /// transcript and cannot be replied to; see `MirroredCall`.
    case calls
    /// Files get a pane of their own for the same reason calls do: a transfer has no
    /// transcript and belongs to no conversation.
    case files
    case thread(ConversationKey)
}

struct MainWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .device
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            ConversationList(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
        } detail: {
            detail
                // Above the pane, not inside it: a ringing phone is the one thing here
                // that cannot wait for someone to go and find it, and it must be answerable
                // from whichever conversation happens to be open.
                .overlay(alignment: .top) { banner }
        }
        .frame(minWidth: 700, minHeight: 420)
        // The whole window, not just the Files pane. Dropping onto whichever pane happens
        // to be open is the gesture people actually make, and a drop target that only
        // works somewhere else is a drop target that looks broken.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            guard !files.isEmpty, state.supportsFileTransfer else { return false }
            state.sendFiles(files)
            selection = .files
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted, state.supportsFileTransfer {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Tenna.accent, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.12), value: dropTargeted)
        // The same backdrop the phone and the site draw. Everything above it is either a
        // material or transparent, so the gradient is what shows through.
        .background(Tenna.backdrop.ignoresSafeArea())
        .navigationTitle("Tennanova")
        // Captured once, from the only place SwiftUI hands it out, and used from the app
        // delegate when the Dock icon is clicked with no window on screen.
        .task { MainWindowOpener.reopen = { openWindow(id: AppScene.mainWindow) } }
    }

    /// The live call, unless the Calls pane is already showing it in full.
    @ViewBuilder
    private var banner: some View {
        if let call = state.calls.current, selection != .calls {
            CallBanner(call: call) { selection = .calls }
                .animation(.snappy, value: call.id)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .calls:
            CallsView()
        case .files:
            TransfersView()
        case .thread(let key):
            // A fresh view per conversation, not one reused across them: a half-typed
            // draft, the focus ring and the scroll anchor all belong to the thread they
            // were made in, and reuse carries every one of them into the next.
            ThreadView(key: key).id(key)
        case .device, nil:
            DeviceView()
        }
    }
}
