import AppKit
import LauncherCore
import SwiftUI

@main
struct AppothequeApp: App {
    @NSApplicationDelegateAdaptor(LauncherDelegate.self) private var delegate
    @StateObject private var model = LauncherModel.shared
    @StateObject private var icons = AppIconStore.shared
    @StateObject private var presence = PresenceStore.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { presence.presence.menuBar }, set: { presence.setMenuBar($0) })) {
            ThemedRoot { LauncherPanel().environmentObject(model) }
        } label: {
            if model.busyID == nil, let glyph = icons.menuBarGlyph {
                Image(nsImage: glyph).accessibilityLabel("Appothèque")
            } else {
                Label("Appothèque", systemImage: model.busyID == nil ? "square.stack.3d.up" : "hammer")
            }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(before: .windowList) {
                Button("Appothèque Window") { AppWindows.showMain(model) }.keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            ThemedRoot { SettingsView().environmentObject(model) }
        }
    }
}

@MainActor
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LauncherModel.shared.activateShortcut()
        AppIconStore.shared.apply()
        PresenceStore.shared.applyActivationPolicy()
        if PresenceStore.shared.presence.dock { AppWindows.showMain(LauncherModel.shared) }
        else if !UserDefaults.standard.bool(forKey: "hasShownLauncher") {
            AppWindows.showLauncher(LauncherModel.shared)
            UserDefaults.standard.set(true, forKey: "hasShownLauncher")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if PresenceStore.shared.presence.dock { AppWindows.showMain(LauncherModel.shared) }
        else if !flag { AppWindows.showLauncher(LauncherModel.shared) }
        else { NSApp.activate() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Two surfaces besides Settings: the launcher (menu bar, or floating for the shortcut) and one main window.
@MainActor
enum AppWindows {
    private static var launcher: LauncherFloatingPanel?
    private static var main: NSWindow?

    /// The global shortcut cannot open the menu bar extra (no public API), so it shows the same view in a floating panel.
    static func showLauncher(_ model: LauncherModel, resetSearch: Bool = false) {
        if launcher == nil { launcher = LauncherFloatingPanel(model: model) }
        guard let launcher else { return }
        let shouldReset = resetSearch || !launcher.isVisible
        launcher.present()
        NSApp.activate()
        if shouldReset {
            model.searchQuery = ""
            model.focusSearchToken = UUID()
        }
        model.discover()
        Task { await model.refreshStatus() }
    }

    static func hideLauncher() { launcher?.orderOut(nil) }

    static func showMain(_ model: LauncherModel, select project: Project? = nil, edit: Bool = false, log: Bool = false) {
        if main == nil { main = makeMainWindow(model) }
        if let project {
            model.sidebarSelection = .project(project.id)
            model.editing = edit ? project : nil
        }
        if log { model.showLog = true }
        hideLauncher()
        main?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.discover()
        Task { await model.refreshStatus() }
    }

    static func showDiscovery(_ model: LauncherModel) {
        showMain(model)
        model.editing = nil
        if let first = model.candidates.first { model.sidebarSelection = .candidate(first.id) }
        model.discover(force: true)
    }

    static func addManually(_ model: LauncherModel) {
        showMain(model)
        model.editing = Project()
    }

    /// Asked before any build when an iOS app has no destination yet; also offered from the detail.
    static func showDestinations(_ model: LauncherModel, project: Project, launch: Bool = false, force: Bool = false) {
        showMain(model, select: project)
        model.destinationRequest = DestinationRequest(projectID: project.id, launch: launch, force: force)
        Task { await model.refreshDestinations() }
    }

    private static func makeMainWindow(_ model: LauncherModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let controller = NSHostingController(rootView: ThemedRoot { MainWindowView().environmentObject(model) })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.title = "Appothèque"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 820, height: 500)
        window.setContentSize(NSSize(width: 1060, height: 680))
        window.center()
        window.setFrameAutosaveName("AppothequeMain")
        return window
    }
}

/// Spotlight-like panel for the global shortcut: no title bar, closes when it loses focus or with Escape.
final class LauncherFloatingPanel: NSPanel {
    init(model: LauncherModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        let controller = NSHostingController(rootView: ThemedRoot { LauncherPanel(floating: true).environmentObject(model) })
        controller.sizingOptions = [.preferredContentSize]
        contentViewController = controller
        // A borderless window is rectangular: round its content so the corners and the shadow follow the glass.
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 26
        controller.view.layer?.cornerCurve = .continuous
        controller.view.layer?.masksToBounds = true
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    /// Upper third of the screen under the pointer, like Spotlight.
    func present() {
        // Lay out first so the frame has the content's size before placing its top edge.
        contentViewController?.view.layoutSubtreeIfNeeded()
        if let size = contentViewController?.preferredContentSize, size != .zero { setContentSize(size) }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            let size = frame.size
            setFrameTopLeftPoint(NSPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.18))
        }
        makeKeyAndOrderFront(nil)
        invalidateShadow()
    }
}
