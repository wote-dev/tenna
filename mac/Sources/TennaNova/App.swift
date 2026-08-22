import SwiftUI
import AppKit

@main
struct TennaNovaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The window and the menu bar item are two views onto one AppState, injected
        // through the environment rather than passed down. A constructor parameter was
        // fine while `MenuBarView` was the only view; a split view whose every leaf wants
        // the state is what makes the environment the right shape.
        Window("Tennanova", id: AppScene.mainWindow) {
            MainWindow()
                .environment(delegate.state)
        }
        .defaultSize(width: 1080, height: 700)
        // Without this the window tracks the *content's* ideal size, which means switching
        // from the device pane to a transcript resizes the window under the user — and a
        // long enough transcript grew it past the bottom of the screen, taking the
        // composer with it.
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(before: .windowList) { OpenMainWindowButton() }
            TennaCommands()
        }

        Window("Phone Mirror", id: AppScene.mirrorWindow) {
            MirrorView()
                .environment(delegate.state)
        }
        .defaultSize(width: 430, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))

        MenuBarExtra {
            MenuBarView()
                .environment(delegate.state)
        } label: {
            // A ringing phone changes the menu bar itself. It is the one event in this
            // app worth taking the icon over, and it is what someone glances at when they
            // hear a phone buzzing in another room.
            Image(systemName: delegate.state.calls.isRinging
                  ? "phone.badge.waveform.fill"
                  : delegate.state.status.isConnected
                      ? "iphone.badge.play"
                      : delegate.state.serverActivity.isAttempting
                          ? "arrow.triangle.2.circlepath"
                          : "iphone.slash")
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppearanceSettingsView()
                .environment(delegate.state)
        }
        .defaultSize(width: 440, height: 220)
    }
}

enum AppScene {
    static let mainWindow = "main"
    static let mirrorWindow = "phone-mirror"
}

/// `openWindow` is handed out only inside a view, and neither the app delegate nor the
/// menu bar popover is one. The action stays valid after the window it opens is closed,
/// so capturing it once — from the window itself — is enough to reopen the scene from
/// anywhere afterwards.
@MainActor
enum MainWindowOpener {
    static var reopen: (() -> Void)?

    static func show() {
        reopen?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
enum MirrorWindowOpener {
    static var reopen: (() -> Void)?

    static func show() {
        reopen?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Tennanova Window") {
            openWindow(id: AppScene.mainWindow)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("0", modifiers: .command)
    }
}

struct NewMessageActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct InboxSearchActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newMessageAction: NewMessageActionKey.Value? {
        get { self[NewMessageActionKey.self] }
        set { self[NewMessageActionKey.self] = newValue }
    }

    var inboxSearchAction: InboxSearchActionKey.Value? {
        get { self[InboxSearchActionKey.self] }
        set { self[InboxSearchActionKey.self] = newValue }
    }
}

struct TennaCommands: Commands {
    @FocusedValue(\.newMessageAction) private var newMessage
    @FocusedValue(\.inboxSearchAction) private var searchInbox

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { newMessage?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newMessage == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Inbox") { searchInbox?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(searchInbox == nil)
        }
    }
}

/// Owns AppState and drives its lifecycle. Starting from the delegate rather than a
/// Scene modifier matters: Scene `onChange` does not reliably fire before the first
/// menu bar interaction, which left the server never started.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular Dock application that keeps its menu bar item. `.accessory` here —
        // and `LSUIElement` in Info.plist — is what used to suppress the Dock icon and
        // any main window along with it.
        NSApp.setActivationPolicy(.regular)
        // Before anything draws, so the first frame is already the appearance the user
        // asked for rather than the system's answer followed by a flip.
        state.appearance.apply()
        Log.info("TennaNova starting")
        state.start()
    }

    /// Clicking the Dock icon with every window closed. Without this the click activates
    /// an app that then shows nothing, which reads exactly like a hang.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        MainActor.assumeIsolated { MainWindowOpener.show() }
        return true
    }

    /// Files dropped on the Dock icon, or opened with `open -a Tennanova <file>`.
    ///
    /// The window's drop target covers the case where the window is on screen; this covers
    /// the case where it is not, which on macOS is the same gesture aimed at the same app.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        state.sendFiles(files)
        MainActor.assumeIsolated { MainWindowOpener.show() }
    }

    /// Closing the window leaves the phone connected. Mirrored notifications and
    /// clipboard sync are most of the value and neither needs a window on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("shutting down")
        state.stop()
    }
}
