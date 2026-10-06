import AppKit
import LauncherCore
import SwiftUI

/// Recipe of an app, edited in place in the window's detail.
struct ProjectEditor: View {
    @EnvironmentObject var model: LauncherModel
    @State var project: Project
    let onSave: (Project) throws -> Void
    let onCancel: () -> Void
    @State private var message: String?
    @State private var removal = false

    private var saved: Project? { model.projects.first { $0.id == project.id } }

    var body: some View {
        Form {
            if saved != nil {
                Section {
                    Toggle("Show in Launcher", isOn: Binding(
                        get: { !model.hiddenProjectIDs.contains(project.id) },
                        set: { model.setHidden(project, !$0) }
                    )).disabled(model.busyID == project.id)
                    Toggle("Pin to Favorites", isOn: Binding(
                        get: { model.favorites.contains(project.id) },
                        set: { model.setFavorite(project, $0) }
                    ))
                }
            }
            Section("Recipe") {
                TextField("Name", text: $project.name)
                Picker("Platform", selection: Binding(get: { project.ios != nil }, set: { mobile in
                    project.ios = mobile ? IOSProject() : nil
                    project.buildCommand = ""
                    if mobile, !project.appPath.isEmpty { project.appPath = project.appURL.lastPathComponent }
                })) {
                    Text("macOS").tag(false)
                    Text("iOS / iPadOS").tag(true)
                }.pickerStyle(.segmented)
                LabeledContent("Project Folder") {
                    HStack {
                        TextField("/path/to/project", text: $project.directory).labelsHidden()
                        Button("Choose…") { chooseDirectory() }
                    }
                }
                LabeledContent(project.ios == nil ? "Built App" : "Bundle Name") {
                    TextField(project.ios == nil ? "dist/My App.app" : "MyApp.app", text: $project.appPath).labelsHidden()
                }
            }
            if project.ios != nil {
                Section {
                    LabeledContent("Project or Workspace") {
                        HStack {
                            TextField("MyApp.xcodeproj", text: iosField(\.container)).labelsHidden()
                            Button("Choose…") { chooseContainer() }
                        }
                    }
                    TextField("Scheme", text: iosField(\.scheme))
                    TextField("Configuration", text: iosField(\.configuration))
                    if let saved, saved.ios != nil {
                        LabeledContent("Destination") {
                            Button {
                                model.destinationRequest = DestinationRequest(projectID: saved.id)
                                Task { await model.refreshDestinations() }
                            } label: {
                                Label(model.destination(for: saved)?.label ?? String(localized: "Choose…"),
                                      systemImage: model.destination(for: saved)?.symbol ?? "iphone")
                            }.disabled(model.busyID != nil)
                        }
                    }
                } header: { Text("iOS / iPadOS Project") }
                footer: { Text("The simulator or device is remembered for this app. On iPhone/iPad, signing must be set up in Xcode.") }
            }
            Section {
                TextEditor(text: $project.buildCommand).font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 70, maxHeight: 110)
                    .accessibilityLabel(project.ios == nil ? "Build Command" : "Optional Preparation")
            } header: { Text(project.ios == nil ? "Build Command" : "Optional Preparation") }
            footer: { Text(project.ios == nil ? "Runs in the project folder, only when its files have changed. The command must produce the app without opening it." : "For example: xcodegen generate. Runs before a build, in the project folder. Appothèque then builds for the chosen destination.") }
            Section {
                DisclosureGroup("Advanced Watching") {
                    TextField("Excluded Paths", text: Binding(get: { project.exclusions.joined(separator: "\n") }, set: { project.exclusions = lines($0) }), axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Other Paths to Watch", text: Binding(get: { project.extraWatchPaths.joined(separator: "\n") }, set: { project.extraWatchPaths = lines($0) }), axis: .vertical)
                        .lineLimit(2...5)
                    Text("One path per line, relative to the project, or absolute for external dependencies. Build folders and downloaded dependencies are excluded by default; their lockfiles stay watched.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let message {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            }
            if saved != nil {
                Section {
                    Button("Remove from List…", role: .destructive) { removal = true }
                        .disabled(model.busyID == project.id)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(saved == nil ? "New App" : "Edit \(saved?.name ?? project.name)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do { try onSave(project); message = nil } catch { message = error.localizedDescription }
                }.buttonStyle(.tinted).disabled(model.busyID != nil).keyboardShortcut("s")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .alert("Remove this app from the launcher?", isPresented: $removal) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let saved { model.editing = nil; model.remove(saved) }
            }
        } message: { Text("The project and its files stay on your Mac.") }
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func iosField(_ keyPath: WritableKeyPath<IOSProject, String>) -> Binding<String> {
        Binding(get: { project.ios?[keyPath: keyPath] ?? "" }, set: { project.ios?[keyPath: keyPath] = $0 })
    }

    private func chooseContainer() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false; panel.prompt = String(localized: "Choose Xcode Project")
        panel.directoryURL = project.directoryURL
        if panel.runModal() == .OK, let url = panel.url, ["xcodeproj", "xcworkspace"].contains(url.pathExtension) {
            let prefix = project.directoryURL.path + "/"
            project.ios?.container = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = String(localized: "Choose Project")
        if panel.runModal() == .OK, let url = panel.url { project.directory = url.path }
    }
}

// MARK: - Build log

/// End of the build log, read again every second while it is shown.
/// An NSTextView rather than Text: Xcode logs have lines thousands of characters long,
/// too wide for a SwiftUI layer, which then rendered empty.
struct BuildLogText: View {
    let url: URL?
    var size: CGFloat = 11
    @State private var content = ""

    var body: some View {
        LogTextView(text: content, font: .monospacedSystemFont(ofSize: size, weight: .regular))
            .task(id: url) {
                while !Task.isCancelled {
                    let next = Self.tail(of: url, limit: 160_000)
                    if next != content { content = next }
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                }
            }
    }

    static func tail(of url: URL?, limit: UInt64) -> String {
        guard let url, let file = try? FileHandle(forReadingFrom: url) else { return String(localized: "No build recorded for this app.") }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: size > limit ? size - limit : 0)
        return (size > limit && limit >= 160_000 ? String(localized: "… End of the log (last 160 KB)") + "\n\n" : "") +
            String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self)
    }
}

/// Last line of the log, to follow a build from the launcher.
struct LastLogLine: View {
    let url: URL
    @State private var line = ""

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .task(id: url) {
                while !Task.isCancelled {
                    let next = BuildLogText.tail(of: url, limit: 4_096)
                        .split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if next != line { line = next }
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                }
            }
    }
}

private struct LogTextView: NSViewRepresentable {
    let text: String
    let font: NSFont

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.font = font
        guard view.string != text else { return }
        // Follow the end only when the reader is already there, so scrolling back up stays put.
        let atEnd = scroll.contentView.bounds.maxY >= view.bounds.maxY - 24
        view.string = text
        view.textColor = .labelColor
        if atEnd || context.coordinator.first { view.scrollToEndOfDocument(nil) }
        context.coordinator.first = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var first = true }
}
