import SwiftUI
import AppKit

/// Light, dark, or whatever the system is doing.
///
/// Every colour in `TennaStyle` already resolves against the current appearance, so the app
/// has always *had* a light mode — it just had no way to ask for one independently of macOS.
/// A phone mirror is a thing people leave open all day beside apps that may not follow the
/// system either, which is reason enough to let it be pinned.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Nil means "inherit", which is what `NSApp.appearance = nil` already means.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Persistence

    /// Alongside `relayHost` and friends: a preference small enough that UserDefaults is
    /// the whole story, and one a user may reasonably want to set before first launch.
    ///
    ///     defaults write com.tennanova.mac appearance light
    static let defaultsKey = "appearance"

    static var stored: AppAppearance {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// Applies this appearance to the whole application.
    ///
    /// `NSApp.appearance` rather than SwiftUI's `.preferredColorScheme`, and the difference
    /// matters here: the menu bar popover is a `MenuBarExtra` scene of its own, so a
    /// modifier on the window would leave it following macOS while the window did not. The
    /// application-level appearance reaches both.
    @MainActor
    func apply() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        NSApp.appearance = nsAppearance
    }
}
