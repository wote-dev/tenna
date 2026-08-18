import SwiftUI
import AppKit

@main
struct TennaNovaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: delegate.state)
        } label: {
            Image(systemName: delegate.state.status.isConnected
                  ? "iphone.badge.play"
                  : "iphone.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns AppState and drives its lifecycle. Starting from the delegate rather than a
/// Scene modifier matters: Scene `onChange` does not reliably fire before the first
/// menu bar interaction, which left the server never started.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        Log.info("TennaNova starting")
        state.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("shutting down")
        state.stop()
    }
}
