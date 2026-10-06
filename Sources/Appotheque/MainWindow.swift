import AppKit
import LauncherCore
import SwiftUI

/// The one window: apps and proposals in the sidebar, the selected one in the detail, its build log in the inspector.
struct MainWindowView: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .inspector(isPresented: $model.showLog) {
            LogInspector().inspectorColumnWidth(min: 280, ideal: 360, max: 560)
        }
        .sheet(item: $model.destinationRequest) { request in
            if let project = model.projects.first(where: { $0.id == request.projectID }) {
                DestinationPicker(project: project, request: request)
            }
        }
        .alert("Appothèque", isPresented: Binding(get: { model.configurationError != nil }, set: { if !$0 { model.configurationError = nil } })) {
            Button("OK") { model.configurationError = nil }
        } message: { Text(model.configurationError ?? "") }
        .onChange(of: model.sidebarSelection) { _, item in
            // Picking something else in the sidebar leaves the recipe being edited, unless it is that app.
            if case .project(let id) = item, model.editing?.id == id { return }
            model.editing = nil
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in model.refreshRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in model.refreshRunning() }
    }

    @ViewBuilder private var detail: some View {
        if let editing = model.editing {
            ProjectEditor(project: editing, onSave: { project in
                try model.save(project)
                model.editing = nil
            }, onCancel: { model.editing = nil }).id(editing.id)
        } else {
            switch model.sidebarSelection {
            case .project(let id):
                if let project = model.projects.first(where: { $0.id == id }) { ProjectDetailView(project: project).id(id) }
                else { EmptyDetail() }
            case .candidate(let id):
                if let candidate = model.candidates.first(where: { $0.id == id }) { CandidateDetailView(candidate: candidate).id(id) }
                else { EmptyDetail() }
            case nil:
                EmptyDetail()
            }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var model: LauncherModel
    @State private var showHidden = false

    private var favorites: [Project] { model.searchResults.filter { model.favorites.contains($0.id) } }
    private var others: [Project] { model.searchResults.filter { !model.favorites.contains($0.id) } }
    private var hidden: [Project] {
        ProjectList.search(model.orderedProjects.filter { model.hiddenProjectIDs.contains($0.id) }, query: model.searchQuery)
    }

    var body: some View {
        List(selection: $model.sidebarSelection) {
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { SidebarRow(project: $0).tag(SidebarItem.project($0.id)) }
                        .onMove { model.move(fromOffsets: $0, toOffset: $1, in: favorites) }
                }
            }
            if !others.isEmpty {
                Section("Apps") {
                    ForEach(others) { SidebarRow(project: $0).tag(SidebarItem.project($0.id)) }
                        .onMove { model.move(fromOffsets: $0, toOffset: $1, in: others) }
                }
            }
            if !hidden.isEmpty {
                Section("Hidden", isExpanded: $showHidden) {
                    ForEach(hidden) { SidebarRow(project: $0).tag(SidebarItem.project($0.id)) }
                }
            }
            Section {
                ForEach(model.candidates) { candidate in
                    Label {
                        HStack {
                            Text(candidate.project.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(candidate.kind).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "plus.app").foregroundStyle(.secondary)
                    }.tag(SidebarItem.candidate(candidate.id))
                }
                if model.candidates.isEmpty {
                    Text(model.isDiscovering ? "Searching for projects…" : "No new apps found")
                        .font(.system(size: 12)).foregroundStyle(.secondary).selectionDisabled()
                }
                ForEach(model.discoveryIssues, id: \.self) { issue in
                    Text(issue).font(.system(size: 11)).foregroundStyle(.orange).selectionDisabled()
                }
            } header: {
                HStack {
                    Text("Proposals")
                    Spacer()
                    if model.isDiscovering { ProgressView().controlSize(.mini) }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "Search")
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if items.count == 1, case .project(let id) = items.first, let project = model.projects.first(where: { $0.id == id }) {
                if model.hiddenProjectIDs.contains(id) {
                    Button("Show in Launcher") { model.setHidden(project, false) }
                } else {
                    Button("Launch") { model.launch(project) }.disabled(model.busyID != nil)
                    ProjectActions(project: project)
                }
            } else if items.count == 1, case .candidate(let id) = items.first, let candidate = model.candidates.first(where: { $0.id == id }) {
                Button("Configure…") { model.sidebarSelection = .candidate(id); model.editing = candidate.project }
                Button("Ignore") { model.ignore(candidate) }
            }
        } primaryAction: { items in
            guard items.count == 1 else { return }
            switch items.first {
            case .project(let id):
                if let project = model.projects.first(where: { $0.id == id }), model.busyID == nil { model.launch(project) }
            case .candidate(let id):
                if let candidate = model.candidates.first(where: { $0.id == id }) { model.editing = candidate.project }
            case nil: break
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Discover Apps") { AppWindows.showDiscovery(model) }
                    Button("Add Manually…") { model.editing = Project() }
                } label: { Label("Add", systemImage: "plus") }
                    .help("Add an App")
            }
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject var model: LauncherModel
    let project: Project

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(project.name).lineLimit(1)
                if project.ios != nil {
                    Image(systemName: model.destination(for: project)?.symbol ?? "iphone")
                        .font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                if model.busyID == project.id { ProgressView().controlSize(.mini) }
                else { StatusDot(status: model.status(for: project)) }
            }
        } icon: {
            ProjectIcon(project: project, size: 20)
        }
        .opacity(model.hiddenProjectIDs.contains(project.id) ? 0.55 : 1)
        .accessibilityValue(model.subtitle(for: project))
        .help(model.subtitle(for: project))
    }
}

/// Compact state for the sidebar: the full wording is in the detail and the tooltip.
private struct StatusDot: View {
    let status: ProjectStatus
    var body: some View {
        switch status.tone {
        case .quiet: Circle().fill(.tertiary).frame(width: 6, height: 6)
        case .pending: Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 6, height: 6)
        case .active: Circle().fill(.tint).frame(width: 6, height: 6)
        case .warning: Circle().fill(.orange).frame(width: 6, height: 6)
        case .failure: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
        }
    }
}

// MARK: - Detail

private struct ProjectDetailView: View {
    @EnvironmentObject var model: LauncherModel
    let project: Project
    @State private var choosingDestination: DestinationRequest?

    private var busy: Bool { model.busyID != nil }
    private var inspection: ProjectInspection? { model.inspections[project.id] }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ProjectIcon(project: project, size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project.name).font(.system(size: 24, weight: .bold))
                        HStack(spacing: 8) {
                            if model.busyID == project.id {
                                Label(model.states[project.id] ?? String(localized: "Working…"), systemImage: "hammer")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.tint)
                            } else {
                                StatusLabel(status: model.status(for: project))
                                    .padding(.horizontal, 9).padding(.vertical, 3)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                            Text(project.ios == nil ? "macOS" : "iOS / iPadOS").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 4)
                if model.busyID == project.id {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView().progressViewStyle(.linear)
                        LastLogLine(url: model.logURL(for: project.id))
                    }
                } else if let error = model.error(for: project) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).textSelection(.enabled)
                        HStack {
                            if !model.showLog { Button("Show Log") { model.showLog = true } }
                            if inspection?.previous != nil {
                                Button("Open Last Successful Build") { model.launchPrevious(project) }.disabled(busy)
                            }
                        }
                    }
                } else {
                    Text(model.subtitle(for: project)).foregroundStyle(.secondary)
                }
            }

            if let changes = inspection?.changes {
                ChangesSection(changes: changes, now: inspection?.inputDigest, built: inspection?.receipt?.inputDigest)
            }

            Section("Source") {
                if let git = inspection?.git {
                    LabeledContent("Branch") {
                        Text(git.branch + (git.isDirty ? " · " + String(localized: "uncommitted changes") : ""))
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text((project.directory as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button { NSWorkspace.shared.open(project.directoryURL) } label: { Image(systemName: "arrow.right.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Open Folder").help("Open Folder")
                    }
                }
            }

            if project.ios != nil {
                Section("Destination") {
                    LabeledContent("Launch On") {
                        Button {
                            choosingDestination = DestinationRequest(projectID: project.id)
                            Task { await model.refreshDestinations() }
                        } label: {
                            Label(model.destination(for: project)?.label ?? String(localized: "Choose…"),
                                  systemImage: model.destination(for: project)?.symbol ?? "iphone")
                        }
                        .disabled(busy)
                        .popover(item: $choosingDestination, arrowEdge: .bottom) { request in
                            DestinationPicker(project: project, request: request)
                        }
                    }
                }
            }

            Section("Builds") {
                LabeledContent("Current") {
                    HStack(spacing: 8) {
                        if let digest = model.receipts[project.id]?.inputDigest { FingerprintGlyphView(digest: digest) }
                        Text(model.receipts[project.id].map { $0.builtAt.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "None"))
                    }
                }
                LabeledContent("Previous") {
                    HStack(spacing: 8) {
                        if let digest = inspection?.previous?.inputDigest { FingerprintGlyphView(digest: digest) }
                        Text(inspection?.previous.map { $0.builtAt.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "None"))
                        if inspection?.previous != nil {
                            Button("Open") { model.launchPrevious(project) }.disabled(busy)
                        }
                    }
                }
                Button("Force Build & Launch") { model.launch(project, force: true) }.disabled(busy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.setFavorite(project, !model.favorites.contains(project.id))
                } label: {
                    Label(model.favorites.contains(project.id) ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: model.favorites.contains(project.id) ? "star.fill" : "star")
                }
                Button { NSWorkspace.shared.open(project.directoryURL) } label: { Label("Open Folder", systemImage: "folder") }
                Button { model.editing = project } label: { Label("Edit", systemImage: "pencil") }
                    .keyboardShortcut("e")
                Button { model.showLog.toggle() } label: { Label("Log", systemImage: "sidebar.right") }
                    .keyboardShortcut("l")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { model.launch(project) } label: {
                    Label(model.primaryAction(for: project), systemImage: "play.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.tinted).disabled(busy)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Launch (⌘↩)")
            }
            // The toolbar's own glass capsule would frame the tinted button in grey.
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// Why the next launch builds: the two fingerprints side by side, then what differs.
private struct ChangesSection: View {
    let changes: InputChanges
    let now: String?
    let built: String?
    private let shown = 8

    private var files: [(path: String, kind: LocalizedStringKey, color: Color)] {
        changes.modified.map { ($0, "Modified", Color.orange) }
            + changes.added.map { ($0, "Added", Color.green) }
            + changes.removed.map { ($0, "Removed", Color.red) }
    }

    var body: some View {
        Section("Since the Last Build") {
            if let now, let built, now != built {
                HStack(spacing: 18) {
                    glyph(now, caption: "Now", changed: true)
                    Image(systemName: "notequal").font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
                    glyph(built, caption: "Last Build", changed: false)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("The fingerprint of the files differs from the last build.")
            }
            ForEach(files.prefix(shown), id: \.path) { file in
                HStack(spacing: 8) {
                    Text(file.path).font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(file.kind).font(.system(size: 11, weight: .medium)).foregroundStyle(file.color)
                }
            }
            if files.count > shown {
                Text("And \(files.count - shown) more").foregroundStyle(.secondary)
            }
            if changes.settingsChanged {
                Label("The recipe or the selected Xcode changed.", systemImage: "slider.horizontal.3")
            }
            if changes.appChanged {
                Label("The built app was modified or removed.", systemImage: "shippingbox")
            }
            if changes.profileRenewal {
                Label("The provisioning profile of the installed build needs renewal.", systemImage: "checkmark.seal")
            }
            if !changes.detailsAvailable {
                Text("The list of changed files appears after the next build.").foregroundStyle(.secondary)
            }
        }
    }

    private func glyph(_ digest: String, caption: LocalizedStringKey, changed: Bool) -> some View {
        VStack(spacing: 6) {
            FingerprintGlyphView(digest: digest, size: 30, changed: changed)
            Text(caption).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
        }
    }
}

private struct CandidateDetailView: View {
    @EnvironmentObject var model: LauncherModel
    let candidate: DiscoveredProject

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 64, height: 64)
                        .overlay { Image(systemName: "plus").font(.system(size: 22)).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.project.name).font(.system(size: 24, weight: .bold))
                        Text("Proposal · \(candidate.kind)").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                Text(candidate.note).foregroundStyle(.secondary)
            }
            Section("Source") {
                LabeledContent("Folder") {
                    Text((candidate.project.directory as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                LabeledContent(candidate.project.ios == nil ? "Built App" : "Bundle Name") {
                    Text(candidate.project.appPath).font(.system(size: 12, design: .monospaced))
                }
            }
            Section {
                Text("Nothing is added or built automatically. Check the proposed recipe before saving it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(candidate.project.name)
        .toolbar {
            ToolbarItem {
                Button("Ignore") { model.ignore(candidate) }
            }
            ToolbarItem {
                Button("Configure…") { model.editing = candidate.project }.buttonStyle(.tinted)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

private struct EmptyDetail: View {
    @EnvironmentObject var model: LauncherModel
    var body: some View {
        ContentUnavailableView {
            Label(model.projects.isEmpty ? "Your workshop starts here" : "No App Selected", systemImage: "square.stack.3d.up")
        } description: {
            Text(model.projects.isEmpty ? "Add a project to launch its latest version in one click." :
                    "Choose an app in the sidebar.")
        } actions: {
            if model.projects.isEmpty {
                Button("Discover My Projects") { AppWindows.showDiscovery(model) }.buttonStyle(.tinted)
                Button("Add Manually…") { model.editing = Project() }
            }
        }
    }
}

// MARK: - Log inspector

private struct LogInspector: View {
    @EnvironmentObject var model: LauncherModel

    private var project: Project? {
        if let editing = model.editing { return model.projects.first { $0.id == editing.id } }
        guard case .project(let id) = model.sidebarSelection else { return nil }
        return model.projects.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let project {
                BuildLogText(url: model.logURL(for: project.id)).id(model.logURL(for: project.id))
                    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
                HStack(spacing: 8) {
                    Button("Copy") {
                        let text = (try? String(contentsOf: model.logURL(for: project.id), encoding: .utf8)) ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.logURL(for: project.id)])
                    }
                }.buttonStyle(.glass).controlSize(.small)
            } else {
                ContentUnavailableView("No Log", systemImage: "doc.text", description: Text("Select an app to see its latest build."))
            }
        }
        .padding(12)
    }
}
