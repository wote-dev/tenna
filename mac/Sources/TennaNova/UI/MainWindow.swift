import SwiftUI

/// What the sidebar can be showing. The phone sits in the same list as the conversations
/// rather than behind a mode switch, because it is where pairing, addresses and battery
/// live and those are needed most often precisely when there are no conversations yet.
enum SidebarItem: Hashable {
    case device
    case thread(ConversationKey)
}

struct MainWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .device

    var body: some View {
        NavigationSplitView {
            ConversationList(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
        } detail: {
            detail
        }
        .frame(minWidth: 700, minHeight: 420)
        .navigationTitle("Tennanova")
        // Captured once, from the only place SwiftUI hands it out, and used from the app
        // delegate when the Dock icon is clicked with no window on screen.
        .task { MainWindowOpener.reopen = { openWindow(id: AppScene.mainWindow) } }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
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
