import AppKit
import LauncherCore

/// App icon and menu bar image choices, applied without relaunching.
@MainActor
final class AppIconStore: ObservableObject {
    static let shared = AppIconStore()
    @Published private(set) var choice: AppIconChoice
    @Published private(set) var menuBarSymbol: MenuBarSymbol
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = AppIconChoice.load(from: defaults)
        menuBarSymbol = MenuBarSymbol.load(from: defaults)
    }

    func select(_ next: AppIconChoice) {
        guard next != choice else { return }
        choice = next
        defaults.set(next.rawValue, forKey: AppIconChoice.defaultsKey)
        apply(clearingStandard: true)
    }

    func select(_ next: MenuBarSymbol) {
        menuBarSymbol = next
        defaults.set(next.rawValue, forKey: MenuBarSymbol.defaultsKey)
    }

    /// The Dock and alert icon change at once. For the Finder, a custom icon is set on the bundle;
    /// a new install removes it, hence applying it again at launch.
    func apply(clearingStandard: Bool = false) {
        let image = icon(for: choice)
        NSApp.applicationIconImage = image
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else { return }
        if choice != .standard { NSWorkspace.shared.setIcon(image, forFile: bundle, options: []) }
        else if clearingStandard { NSWorkspace.shared.setIcon(nil, forFile: bundle, options: []) }
    }

    func icon(for choice: AppIconChoice) -> NSImage? {
        Bundle.main.url(forResource: choice.iconResource, withExtension: "png", subdirectory: "Icons")
            .flatMap(NSImage.init(contentsOf:))
    }

    /// 18 pt template glyph (@2x file), tinted by macOS. `nil` when the bundle does not ship it.
    var menuBarGlyph: NSImage? {
        guard menuBarSymbol == .matching,
              let url = Bundle.main.url(forResource: choice.glyphResource, withExtension: "png", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}
