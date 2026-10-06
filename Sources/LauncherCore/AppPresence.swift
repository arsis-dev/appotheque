import Foundation

/// Where the app can be reached: the Dock (main window) and/or the menu bar. At least one stays enabled.
public struct AppPresence: Equatable, Sendable {
    public static let dockKey = "showInDock"
    public static let menuBarKey = "showInMenuBar"

    public private(set) var dock: Bool
    public private(set) var menuBar: Bool

    public init(dock: Bool = false, menuBar: Bool = true) {
        self.dock = dock
        self.menuBar = menuBar || !dock
    }

    public static func load(from defaults: UserDefaults) -> Self {
        AppPresence(dock: defaults.bool(forKey: dockKey), menuBar: defaults.object(forKey: menuBarKey) as? Bool ?? true)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(dock, forKey: Self.dockKey)
        defaults.set(menuBar, forKey: Self.menuBarKey)
    }

    /// Removing the last entry point turns the other one back on rather than leaving the app unreachable.
    public func with(dock: Bool) -> Self { AppPresence(dock: dock, menuBar: menuBar || !dock) }
    public func with(menuBar: Bool) -> Self { AppPresence(dock: dock || !menuBar, menuBar: menuBar) }
}
