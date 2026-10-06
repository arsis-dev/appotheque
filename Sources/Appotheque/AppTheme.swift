import AppKit
import LauncherCore
import SwiftUI

@MainActor
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()
    @Published private(set) var preferences: AppearancePreferences
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = AppearancePreferences.load(from: defaults)
    }

    func set(mode: AppearanceMode) { update { $0.mode = mode } }
    func set(tint: AppTint) { update { $0.tint = tint } }

    private func update(_ change: (inout AppearancePreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        preferences = next
        next.save(to: defaults)
    }
}

extension AppTint {
    /// Adapts to light and dark like a system colour; the system tint follows System Settings.
    var color: Color { Self.adaptive(hex) }
    /// Label of the main button, readable on its light wash of the tint.
    var labelColor: Color { Self.adaptive(labelHex) }

    private static func adaptive(_ hex: (light: UInt32, dark: UInt32)?) -> Color {
        guard let hex else { return .accentColor }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(dark ? hex.dark : hex.light)
        })
    }

    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Applies the user's tint and light/dark choice. Surfaces, text and controls stay those of macOS.
struct ThemedRoot<Content: View>: View {
    @ObservedObject private var appearance = AppearanceStore.shared
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .tint(appearance.preferences.tint.color)
            .preferredColorScheme(appearance.preferences.mode.colorScheme)
            .background(WindowAppearanceBridge(mode: appearance.preferences.mode))
    }
}

/// `preferredColorScheme` does not reach AppKit-hosted windows on its own: their title bar and materials need the window's appearance.
private struct WindowAppearanceBridge: NSViewRepresentable {
    let mode: AppearanceMode
    func makeNSView(context: Context) -> BridgeView { BridgeView() }
    func updateNSView(_ view: BridgeView, context: Context) { view.mode = mode; view.apply() }

    final class BridgeView: NSView {
        var mode = AppearanceMode.system
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            switch mode {
            case .system: window?.appearance = nil
            case .light: window?.appearance = NSAppearance(named: .aqua)
            case .dark: window?.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }
}

// MARK: - Shared pieces

enum StatusTone { case quiet, active, warning, failure, pending }

struct ProjectStatus: Equatable {
    let short: String
    let tone: StatusTone
}

extension LauncherModel {
    func status(for project: Project) -> ProjectStatus {
        if busyID == project.id { return ProjectStatus(short: String(localized: "In progress"), tone: .active) }
        if project.ios != nil, destination(for: project) == nil { return ProjectStatus(short: String(localized: "Destination"), tone: .pending) }
        if failures[project.id] != nil { return ProjectStatus(short: String(localized: "Failed"), tone: .failure) }
        switch inspections[project.id]?.readiness {
        case .changed: return ProjectStatus(short: String(localized: "Changed"), tone: .warning)
        case .firstBuild: return ProjectStatus(short: isRunning(project) ? String(localized: "Running · needs build") : String(localized: "Needs build"), tone: .pending)
        case .upToDate: return isRunning(project) ? ProjectStatus(short: String(localized: "Running"), tone: .active) : ProjectStatus(short: String(localized: "Ready"), tone: .quiet)
        case .failed: return ProjectStatus(short: String(localized: "Failed"), tone: .failure)
        case .unavailable: return ProjectStatus(short: String(localized: "Check"), tone: .warning)
        case nil: return ProjectStatus(short: String(localized: "Checking"), tone: .pending)
        }
    }

    /// The main button says what a click will do.
    func primaryAction(for project: Project) -> String {
        if project.ios != nil, destination(for: project) == nil { return String(localized: "Choose & Launch") }
        if error(for: project) != nil { return String(localized: "Try Again") }
        switch inspections[project.id]?.readiness {
        case .changed, .firstBuild: return String(localized: "Build & Launch")
        case .upToDate where isRunning(project): return String(localized: "Show")
        default: return String(localized: "Launch")
        }
    }

    func refreshAll() {
        forgetIcons(); Task { await refreshStatus() }; discover(force: true)
    }
}

struct StatusLabel: View {
    let status: ProjectStatus
    var body: some View {
        HStack(spacing: 5) {
            switch status.tone {
            case .failure: Image(systemName: "exclamationmark.circle").font(.system(size: 10, weight: .semibold))
            case .pending: Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 6, height: 6)
            default: Circle().fill(dotStyle).frame(width: 6, height: 6)
            }
            Text(status.short).lineLimit(1).fixedSize()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(textStyle)
    }
    private var dotStyle: AnyShapeStyle {
        switch status.tone {
        case .quiet, .pending: return AnyShapeStyle(.tertiary)
        case .active: return AnyShapeStyle(.tint)
        case .warning: return AnyShapeStyle(Color.orange)
        case .failure: return AnyShapeStyle(Color.red)
        }
    }
    private var textStyle: AnyShapeStyle {
        switch status.tone {
        case .quiet, .pending: return AnyShapeStyle(.secondary)
        case .active: return AnyShapeStyle(.tint)
        case .warning: return AnyShapeStyle(Color.orange)
        case .failure: return AnyShapeStyle(Color.red)
        }
    }
}

struct ProjectIcon: View {
    @EnvironmentObject var model: LauncherModel
    let project: Project
    let size: CGFloat
    var body: some View {
        Image(nsImage: model.icon(for: project)).resizable().scaledToFit()
            .frame(width: size, height: size).foregroundStyle(.secondary).accessibilityHidden(true)
    }
}

/// Actions shared by the panel rows, the window sidebar and their context menus.
struct ProjectActions: View {
    @EnvironmentObject var model: LauncherModel
    let project: Project

    var body: some View {
        Button(model.favorites.contains(project.id) ? "Remove from Favorites" : "Add to Favorites") {
            model.setFavorite(project, !model.favorites.contains(project.id))
        }
        Button("Move Up") { model.move(project, down: false) }
        Button("Move Down") { model.move(project, down: true) }
        Divider()
        if project.ios != nil {
            Button("Choose Destination…") { AppWindows.showDestinations(model, project: project) }.disabled(model.busyID != nil)
        }
        Button("Force Build & Launch") { model.launch(project, force: true) }.disabled(model.busyID != nil)
        Button(model.receipts[project.id] == nil ? "Open Last Successful Build" : "Open Previous Build") {
            model.launchPrevious(project)
        }.disabled(model.busyID != nil || model.inspections[project.id]?.previous == nil)
        if let previous = model.inspections[project.id]?.previous {
            Text("Built \(previous.builtAt.formatted(date: .abbreviated, time: .shortened))")
        }
        Button("Show Log") { AppWindows.showMain(model, select: project, log: true) }
        Button("Open Project Folder") { NSWorkspace.shared.open(project.directoryURL) }
        Divider()
        Button("Edit…") { AppWindows.showMain(model, select: project, edit: true) }
        Button("Hide from Launcher") { model.setHidden(project, true) }.disabled(model.busyID == project.id)
    }
}

/// Main action: the tint on a light wash of itself, quieter than a filled button.
struct TintedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @ObservedObject private var appearance = AppearanceStore.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(appearance.preferences.tint.labelColor)
            .padding(.horizontal, 14).frame(minHeight: 28)
            .background(.tint.opacity(configuration.isPressed ? 0.26 : 0.15), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == TintedButtonStyle {
    static var tinted: TintedButtonStyle { TintedButtonStyle() }
}

/// A build's fingerprint as a 3×3 glyph, like the app icon: the same inputs always draw the same glyph.
struct FingerprintGlyphView: View {
    let digest: String
    var size: CGFloat = 14
    /// Orange cells: these inputs have not been built yet.
    var changed = false

    var body: some View {
        let gap = max(1, size * 0.09), cell = (size - 2 * gap) / 3
        let cells = FingerprintGlyph.cells(for: digest)
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        let index = row * 3 + column
                        RoundedRectangle(cornerRadius: cell * 0.28, style: .continuous)
                            .fill(style(lit: cells[index], centre: index == 4))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .help(Text("Fingerprint \(String(digest.prefix(8)))"))
        .accessibilityHidden(true)
    }

    private func style(lit: Bool, centre: Bool) -> AnyShapeStyle {
        if centre { return changed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint) }
        guard lit else { return AnyShapeStyle(.quaternary) }
        return changed ? AnyShapeStyle(Color.orange.opacity(0.75)) : AnyShapeStyle(.secondary)
    }
}
