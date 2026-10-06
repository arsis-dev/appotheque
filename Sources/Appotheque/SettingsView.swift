import AppKit
import LauncherCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Appearance", systemImage: "circle.lefthalf.filled") { AppearanceSettings() }
            Tab("Icon", systemImage: "app.badge") { IconSettings() }
        }
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: LauncherModel
    @ObservedObject private var presence = PresenceStore.shared

    var body: some View {
        Form {
            Section {
                // The last remaining entry point cannot be switched off.
                Toggle("Show in Menu Bar", isOn: Binding(get: { presence.presence.menuBar }, set: { presence.setMenuBar($0) }))
                    .disabled(presence.presence.menuBar && !presence.presence.dock)
                Toggle("Show in Dock", isOn: Binding(get: { presence.presence.dock }, set: { presence.setDock($0) }))
                    .disabled(presence.presence.dock && !presence.presence.menuBar)
                Toggle("Open at Login", isOn: Binding(get: { model.startAtLogin }, set: { model.setLogin($0) }))
            } header: { Text("Access") }
            footer: { Text("At least one of the Dock and the menu bar stays on. The Dock adds the app to ⌘-Tab and opens the window on click.") }

            Section {
                Picker("Global Shortcut", selection: Binding(get: { model.shortcut }, set: { model.setShortcut($0) })) {
                    ForEach(LauncherShortcut.allCases) { Text($0.label).tag($0) }
                }
                if let error = model.shortcutError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } footer: { Text("Opens the launcher above your windows, ready to type a search.") }

            Section {
                ForEach(model.discoveryRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((root as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { model.setDiscoveryRoots(model.discoveryRoots.filter { $0 != root }) } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).accessibilityLabel("Stop searching \(root)")
                    }
                }
                HStack {
                    Button("Add Folder…") { chooseRoot() }
                    Spacer()
                    Button("Show Ignored Proposals Again") { model.resetIgnoredDiscoveries() }
                }
            } header: { Text("Folders to Search") }
            footer: { Text("Reads Xcode, XcodeGen, Swift, Tauri and Electron manifests. No script runs during the search.") }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 520)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true; panel.prompt = String(localized: "Search")
        if panel.runModal() == .OK {
            let roots = panel.urls.map(\.path).filter { !model.discoveryRoots.contains($0) }
            model.setDiscoveryRoots(model.discoveryRoots + roots)
        }
    }
}

private struct AppearanceSettings: View {
    @ObservedObject private var appearance = AppearanceStore.shared

    var body: some View {
        Form {
            Section("Mode") {
                HStack(spacing: 14) {
                    ForEach(AppearanceMode.allCases) { mode in modeButton(mode) }
                }.padding(.vertical, 4)
            }
            Section {
                HStack(spacing: 12) {
                    ForEach(AppTint.allCases) { tint in tintButton(tint) }
                }.padding(.vertical, 4)
            } header: { Text("Tint") }
            footer: { Text(appearance.preferences.tint.label) }
            Section("Preview") {
                HStack(spacing: 10) {
                    Image(systemName: "app.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text("My App").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    StatusLabel(status: ProjectStatus(short: String(localized: "Running"), tone: .active))
                    Label("Launch", systemImage: "play.fill").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(appearance.preferences.tint.labelColor).padding(.horizontal, 12).frame(height: 28)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                .padding(.horizontal, 10).frame(height: 44)
                .background(.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine).accessibilityLabel("Tint preview")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 470)
    }

    private func modeButton(_ mode: AppearanceMode) -> some View {
        let selected = appearance.preferences.mode == mode
        return Button { appearance.set(mode: mode) } label: {
            VStack(spacing: 7) {
                HStack(spacing: 0) {
                    miniature(dark: mode == .dark)
                    miniature(dark: mode != .light)
                }
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: selected ? 3 : 1)
                }
                Text(mode.label).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func miniature(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(dark ? Color.white.opacity(0.25) : Color.black.opacity(0.15)).frame(width: 34, height: 6)
            Capsule().fill(.tint.opacity(0.5)).frame(height: 10)
            Capsule().fill(dark ? Color.white.opacity(0.25) : Color.black.opacity(0.15)).frame(width: 44, height: 6)
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dark ? Color(white: 0.16) : Color(white: 0.96))
    }

    private func tintButton(_ tint: AppTint) -> some View {
        let selected = appearance.preferences.tint == tint
        return Button { appearance.set(tint: tint) } label: {
            Circle()
                .fill(tint == .system
                      ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                      : AnyShapeStyle(tint.color))
                .frame(width: 26, height: 26)
                .overlay { Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                .padding(3)
                .overlay { Circle().strokeBorder(selected ? AnyShapeStyle(tint.color) : AnyShapeStyle(.clear), lineWidth: 2) }
        }
        .buttonStyle(.plain).help(tint.label)
        .accessibilityLabel(tint.label).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct IconSettings: View {
    @ObservedObject private var icons = AppIconStore.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(AppIconChoice.allCases) { choice in iconButton(choice) }
                }
            } header: { Text("App Icon") }
            footer: { Text("The Finder shows the chosen icon on the installed app; after a reinstall, it is applied again at launch.") }
            Section("Menu Bar") {
                Picker("Glyph", selection: Binding(get: { icons.menuBarSymbol }, set: { icons.select($0) })) {
                    Text("Stack").tag(MenuBarSymbol.system)
                    Text("Matching Icon").tag(MenuBarSymbol.matching)
                }.pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 330)
    }

    private func iconButton(_ choice: AppIconChoice) -> some View {
        let selected = icons.choice == choice
        return Button { icons.select(choice) } label: {
            VStack(spacing: 6) {
                Group {
                    if let image = icons.icon(for: choice) { Image(nsImage: image).resizable() }
                    else { RoundedRectangle(cornerRadius: 14).fill(.fill.tertiary) }
                }.frame(width: 64, height: 64)
                Text(choice.name).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(8).frame(maxWidth: .infinity)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Icon \(choice.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
