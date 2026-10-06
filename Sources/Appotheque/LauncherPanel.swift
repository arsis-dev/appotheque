import AppKit
import LauncherCore
import SwiftUI

/// Quick launch: search, list, detail of the selected app, one main action. Everything else opens the main window.
struct LauncherPanel: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool
    @State private var selectedID: UUID?
    var floating = false

    private var favorites: [Project] { model.searchResults.filter { model.favorites.contains($0.id) } }
    private var others: [Project] { model.searchResults.filter { !model.favorites.contains($0.id) } }
    private var selectedProject: Project? { model.searchResults.first { $0.id == selectedID } }
    // The panel keeps the size it opened with: the list and the detail get fixed heights so that
    // selecting another app or typing a search never pushes content under the footer.
    private var listHeight: CGFloat {
        let visible = model.visibleProjects, favoriteCount = visible.filter { model.favorites.contains($0.id) }.count
        return CGFloat(min(visible.count, 8)) * 40 + 8 +
            (favoriteCount == 0 ? 0 : 22) + (favoriteCount == 0 || favoriteCount == visible.count ? 0 : 31)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            search.padding(.horizontal, 12).padding(.bottom, 6)
            errorBanner
            if model.visibleProjects.isEmpty { emptyState }
            else {
                Group {
                    if model.searchResults.isEmpty { noResults } else { projectList }
                }.frame(height: listHeight, alignment: .top)
                Group {
                    if let project = selectedProject { PanelDetail(project: project) }
                    else {
                        Text("Click an app or use the arrow keys.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 186, alignment: .top).clipped()
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 10)
            }
            footer
        }
        .frame(width: 384)
        .background {
            if floating { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 26)) }
        }
        .onAppear {
            searchFocused = true
            retainSelection()
            model.discover()
            Task { await model.refreshStatus() }
        }
        .onChange(of: model.focusSearchToken) { _, _ in
            searchFocused = true
            selectedID = model.searchResults.first?.id
        }
        .onChange(of: model.searchQuery) { _, _ in selectedID = model.searchResults.first?.id }
        .onChange(of: model.searchResults.map(\.id)) { _, _ in retainSelection() }
        .onChange(of: model.busyID) { _, id in if let id { selectedID = id } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in model.refreshRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in model.refreshRunning() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Appothèque").font(.system(size: 21, weight: .semibold, design: .serif))
            Spacer()
            if model.shortcut != .disabled {
                Text(model.shortcut.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.fill.tertiary, in: Capsule())
                    .help("Global launcher shortcut")
            }
        }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search Apps", text: $model.searchQuery)
                .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                .onSubmit { launchSelection() }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.escape) {
                    guard !model.searchQuery.isEmpty else { return .ignored }
                    model.searchQuery = ""; return .handled
                }
                .accessibilityLabel("Search Apps")
            if !model.searchQuery.isEmpty {
                Button { model.searchQuery = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }.buttonStyle(.plain).accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(.fill.tertiary, in: Capsule())
        .overlay { Capsule().strokeBorder(.tint.opacity(searchFocused ? 0.6 : 0), lineWidth: 1.5) }
    }

    @ViewBuilder private var errorBanner: some View {
        if let error = model.configurationError ?? model.shortcutError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 8)
        }
    }

    private var noResults: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No Apps Found").font(.system(size: 13, weight: .medium))
            Text("Try another name.").font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !favorites.isEmpty {
                        sectionLabel("Favorites")
                        rows(favorites)
                    }
                    if !favorites.isEmpty, !others.isEmpty {
                        Divider().padding(.horizontal, 10).padding(.vertical, 4)
                        sectionLabel("Apps")
                    }
                    rows(others)
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 22)
    }

    private func rows(_ projects: [Project]) -> some View {
        ForEach(projects) { project in
            PanelRow(project: project, selected: project.id == selectedID) { selectedID = project.id }.id(project.id)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.projects.isEmpty ? "Your workshop starts here" : "All apps are hidden")
                .font(.system(size: 14, weight: .semibold))
            Text(model.projects.isEmpty ? "Add a project to launch its latest version in one click." : "Show your projects again from the Appothèque window.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button(model.projects.isEmpty ? "Discover My Projects" : "Open Window") {
                if model.projects.isEmpty { AppWindows.showDiscovery(model) } else { AppWindows.showMain(model) }
            }.buttonStyle(.tinted).padding(.top, 6)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Discover Apps…") { AppWindows.showDiscovery(model) }
                Button("Add Manually…") { AppWindows.addManually(model) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Add")
                    if !model.candidates.isEmpty {
                        Text("\(model.candidates.count)").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tint, in: Capsule())
                            .accessibilityLabel("Proposals: \(model.candidates.count)")
                    }
                }.font(.system(size: 12, weight: .medium))
            }
            .menuIndicator(.hidden).buttonStyle(.glass).fixedSize()
            .accessibilityLabel("Add an App")
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini).accessibilityLabel("Refreshing states")
            }
            Button { AppWindows.showMain(model, select: selectedProject) } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(CircleIconButtonStyle())
                .accessibilityLabel("Open the Appothèque Window").help("Appothèque Window (⌘0)")
            Menu {
                Button("Settings…") { NSApp.activate(); openSettings() }.keyboardShortcut(",")
                Button("Refresh States and Projects") { model.refreshAll() }.disabled(model.isRefreshing)
                Divider()
                Button("Quit Appothèque") { NSApp.terminate(nil) }
                    .disabled(model.busyID != nil).keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(CircleIconButtonStyle()).fixedSize()
                .accessibilityLabel("Appothèque Options")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
    }

    private func retainSelection() {
        if !model.searchResults.contains(where: { $0.id == selectedID }) { selectedID = model.searchResults.first?.id }
    }

    private func launchSelection() {
        if let project = selectedProject ?? model.searchResults.first { model.launch(project) }
    }

    private func moveSelection(_ delta: Int) {
        let results = model.searchResults
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : results.count)
        selectedID = results[min(max(current + delta, 0), results.count - 1)].id
    }
}

private struct PanelRow: View {
    @EnvironmentObject var model: LauncherModel
    let project: Project
    let selected: Bool
    let select: () -> Void
    @State private var hovered = false
    private var busy: Bool { model.busyID == project.id }

    var body: some View {
        HStack(spacing: 10) {
            ProjectIcon(project: project, size: 26)
            Text(project.name).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
            if project.ios != nil {
                Image(systemName: model.destination(for: project)?.symbol ?? "iphone")
                    .font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Spacer(minLength: 6)
            if hovered || selected {
                Menu { ProjectActions(project: project) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(.secondary).accessibilityLabel("Actions for \(project.name)")
            }
            if busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(model.steps[project.id]?.short ?? String(localized: "Working…")).lineLimit(1).fixedSize()
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.tint)
            } else {
                StatusLabel(status: model.status(for: project))
            }
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background {
            if busy {
                LaunchProgressBackground(project: project)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.primary.opacity(hovered ? 0.05 : 0)))
            }
        }
        .contentShape(Rectangle())
        // Hover only highlights: selecting on hover made the detail follow the pointer and fought scrolling.
        .onTapGesture(count: 2) { select(); if model.busyID == nil { model.launch(project) } }
        .simultaneousGesture(TapGesture().onEnded { select() })
        .onHover { hovered = $0 }
        .contextMenu { ProjectActions(project: project) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(project.name)
        .accessibilityValue(model.subtitle(for: project) + (model.favorites.contains(project.id) ? " · " + String(localized: "Favorite") : ""))
        .accessibilityAction { select() }
        .accessibilityAction(named: "Launch") { if model.busyID == nil { model.launch(project) } }
        .help(model.subtitle(for: project) + ". " + String(localized: "Double-click to launch."))
    }
}

/// Detail card under the list: where the code stands, then what a click will do.
private struct PanelDetail: View {
    @EnvironmentObject var model: LauncherModel
    let project: Project
    private var busy: Bool { model.busyID == project.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProjectIcon(project: project, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(source).lineLimit(1).truncationMode(.middle)
                        if let receipt = model.receipts[project.id] {
                            Text("·")
                            // The last build's fingerprint, as in the window.
                            FingerprintGlyphView(digest: receipt.inputDigest, size: 11)
                            Text(receipt.builtAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                .lineLimit(1).fixedSize()
                        }
                    }
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if project.ios != nil {
                Button { AppWindows.showDestinations(model, project: project) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.destination(for: project)?.symbol ?? "iphone")
                        Text(model.destination(for: project)?.label ?? String(localized: "Choose a destination")).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.tint)
                    .disabled(model.busyID != nil).accessibilityLabel("Destination for \(project.name)")
            }
            state
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { AppWindows.showMain(model, select: project, log: true) } label: { Image(systemName: "doc.text") }
                    .buttonStyle(CircleIconButtonStyle())
                    .accessibilityLabel("Log for \(project.name)").help("Log")
                Button { NSWorkspace.shared.open(project.directoryURL) } label: { Image(systemName: "folder") }
                    .buttonStyle(CircleIconButtonStyle())
                    .accessibilityLabel("Open the folder of \(project.name)").help("Project Folder")
                Spacer()
                if !busy {
                    Button { model.launch(project) } label: {
                        Label(model.primaryAction(for: project), systemImage: "play.fill").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.tinted).disabled(model.busyID != nil)
                    .accessibilityHint("Or press Return")
                }
            }
        }
        .padding(14)
    }

    private var source: String {
        guard let git = model.inspections[project.id]?.git else { return project.directoryURL.lastPathComponent }
        return git.branch + (git.isDirty ? " · " + String(localized: "modified") : "")
    }

    @ViewBuilder private var state: some View {
        if busy {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.states[project.id] ?? String(localized: "Working…")).lineLimit(1)
                    Spacer()
                    if let start = model.busySince {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(Duration.seconds(context.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }.font(.system(size: 12))
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    if let progress = model.progress(for: project, at: context.date) {
                        ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                LastLogLine(url: model.logURL(for: project.id))
            }
        } else if let error = model.error(for: project) {
            VStack(alignment: .leading, spacing: 4) {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2).help(error)
                HStack(spacing: 12) {
                    Button("Show Log") { AppWindows.showMain(model, select: project, log: true) }
                    if model.inspections[project.id]?.previous != nil {
                        Button("Last Successful Build") { model.launchPrevious(project) }
                    }
                }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.subtitle(for: project)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                if let changes = model.inspections[project.id]?.changes, changes.fileCount > 0 {
                    let paths = changes.modified + changes.added + changes.removed
                    Text(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                        .help(paths.joined(separator: "\n"))
                }
            }
        }
    }
}

/// Neutral round icon button: the tint stays reserved for the main action.
struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(.fill.opacity(configuration.isPressed ? 0.9 : 0.55), in: Circle())
            .contentShape(Circle())
    }
}
