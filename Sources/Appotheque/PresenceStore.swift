import AppKit
import LauncherCore

/// Applies the Dock / menu bar settings without relaunching.
@MainActor
final class PresenceStore: ObservableObject {
    static let shared = PresenceStore()
    @Published private(set) var presence: AppPresence
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presence = AppPresence.load(from: defaults)
    }

    func setDock(_ value: Bool) { update(presence.with(dock: value)) }
    func setMenuBar(_ value: Bool) { update(presence.with(menuBar: value)) }

    /// With the Dock the app is a regular one (⌘-Tab, menus); otherwise it stays a menu bar accessory.
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(presence.dock ? .regular : .accessory)
        // The Dock icon follows the icon chosen in Settings.
        if presence.dock { NSApp.applicationIconImage = AppIconStore.shared.icon(for: AppIconStore.shared.choice) }
    }

    private func update(_ next: AppPresence) {
        guard next != presence else { return }
        let showWindow = next.dock && !presence.dock
        presence = next
        next.save(to: defaults)
        applyActivationPolicy()
        if showWindow { AppWindows.showMain(LauncherModel.shared) }
    }
}
