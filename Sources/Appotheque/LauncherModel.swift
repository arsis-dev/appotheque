import AppKit
import Foundation
import LauncherCore
import ServiceManagement
import SwiftUI

@MainActor
final class LauncherModel: ObservableObject {
    static let shared = LauncherModel()
    private static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let storageURL = supportDirectory.appendingPathComponent("Appotheque")

    @Published var projects: [Project] = []
    @Published var states: [UUID: String] = [:]
    /// Current step of the running launch, for the short label of its row.
    @Published var steps: [UUID: LaunchStep] = [:]
    @Published var failures: [UUID: String] = [:]
    @Published var receipts: [UUID: BuildReceipt] = [:]
    @Published var busyID: UUID? {
        didSet {
            guard busyID != oldValue else { return }
            busySince = busyID == nil ? nil : Date()
            buildStartedAt = nil
            if let id = busyID { steps[id] = nil }
            // The last build's duration, read before the engine sets the receipt aside.
            expectedBuildSeconds = busyID.flatMap { receipts[$0]?.buildSeconds }
        }
    }
    /// When the build command started, and how long the last one took: together they drive the row's progress bar.
    @Published private(set) var buildStartedAt: Date?
    private(set) var expectedBuildSeconds: Double?
    /// Start of the current operation, for the elapsed time shown while building.
    @Published private(set) var busySince: Date?
    @Published var configurationError: String?
    /// What the window shows: an app, a discovery proposal, or nothing.
    @Published var sidebarSelection: SidebarItem?
    /// Recipe being edited in the window's detail: a new app, a proposal, or an existing app.
    @Published var editing: Project?
    @Published var showLog = false
    /// Destination choice asked for before an iOS launch, or from the window's detail.
    @Published var destinationRequest: DestinationRequest?
    @Published private(set) var destinations: [LaunchDestination] = []
    @Published private(set) var destinationIssues: [String] = []
    @Published private(set) var isLoadingDestinations = false
    @Published private(set) var destinationChoices: [String: LaunchDestination] =
        UserDefaults.standard.data(forKey: "destinationChoices.v1")
            .flatMap { try? JSONDecoder().decode([String: LaunchDestination].self, from: $0) } ?? [:]
    private var destinationTask: Task<DestinationInventory, Never>?
    @Published var startAtLogin = SMAppService.mainApp.status == .enabled
    @Published var searchQuery = ""
    @Published var focusSearchToken = UUID()
    @Published var inspections: [UUID: ProjectInspection] = [:]
    @Published var runningPaths: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var favorites = Set((UserDefaults.standard.stringArray(forKey: "favoriteProjectIDs") ?? []).compactMap(UUID.init(uuidString:)))
    @Published private(set) var projectOrder = (UserDefaults.standard.stringArray(forKey: "projectOrder") ?? []).compactMap(UUID.init(uuidString:))
    @Published private(set) var shortcut = LauncherShortcut(rawValue: UserDefaults.standard.string(forKey: "launcherShortcut") ?? "space") ?? .space
    @Published private(set) var shortcutError: String?
    @Published private(set) var candidates: [DiscoveredProject] = []
    @Published private(set) var discoveryIssues: [String] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var discoveryRoots = UserDefaults.standard.stringArray(forKey: "discoveryRoots") ?? ProjectDiscovery.defaultRoots()
    private var ignoredDiscoveries = Set(UserDefaults.standard.stringArray(forKey: "ignoredDiscoveries") ?? [])
    private var lastDiscovery: Date = .distantPast
    private let hotKey = GlobalHotKey()
    @Published private(set) var hiddenProjectIDs = Set(
        (UserDefaults.standard.stringArray(forKey: "hiddenProjectIDs") ?? []).compactMap { UUID(uuidString: $0) }
    )

    var orderedProjects: [Project] { ProjectList.ordered(projects, favorites: favorites, order: projectOrder) }
    var visibleProjects: [Project] { orderedProjects.filter { !hiddenProjectIDs.contains($0.id) } }
    var searchResults: [Project] { ProjectList.search(visibleProjects, query: searchQuery) }

    let storage: URL
    let configURL: URL
    let engine: BuildEngine
    let mobileEngine: MobileEngine

    init() {
        storage = Self.storageURL
        configURL = storage.appendingPathComponent("projects.json")
        engine = BuildEngine(storage: storage)
        mobileEngine = MobileEngine(storage: storage)
        do {
            // A first launch starts empty and offers discovery: no project list ships with the app.
            if FileManager.default.fileExists(atPath: configURL.path) {
                projects = try ProjectStore.load(from: configURL)
            }
            sidebarSelection = projects.first.map { .project($0.id) }
        } catch { configurationError = String(localized: "Could not load the app list. \(error.localizedDescription)") }
        Task { await refreshReceipts() }
    }

    func refreshReceipts() async {
        for project in projects {
            if project.ios != nil {
                if let destination = destination(for: project) { receipts[project.id] = await mobileEngine.receipt(for: project, destination: destination) }
            } else { receipts[project.id] = await engine.receipt(for: project.id) }
        }
    }

    func refreshStatus() async {
        refreshRunning()
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for project in projects {
            guard !Task.isCancelled else { return }
            guard busyID != project.id else { continue }
            let choice = destination(for: project)
            let result = await inspect(project)
            if projects.contains(project), busyID != project.id, choice == destination(for: project) {
                inspections[project.id] = result
                receipts[project.id] = result?.receipt
            }
        }
    }

    func refreshRunning() {
        runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
    }

    func isRunning(_ project: Project) -> Bool {
        guard project.ios == nil else { return false }
        return runningPaths.contains { $0.hasPrefix(storage.appendingPathComponent("Builds/\(project.id.uuidString)").path + "/") } ||
            runningPaths.contains(project.appURL.resolvingSymlinksInPath().path)
    }

    func error(for project: Project) -> String? {
        if let failure = failures[project.id] { return failure }
        switch inspections[project.id]?.readiness {
        case .failed(let message), .unavailable(let message): return message
        default: return nil
        }
    }

    func subtitle(for project: Project) -> String {
        if busyID == project.id { return states[project.id] ?? String(localized: "Opening…") }
        if project.ios != nil, destination(for: project) == nil { return String(localized: "Choose a destination") }
        var status = inspections[project.id]?.readiness.label ?? String(localized: "Checking…")
        if let count = inspections[project.id]?.changes?.fileCount, count > 0 {
            status = count == 1 ? String(localized: "1 file changed · needs rebuild")
                : String(localized: "\(count) files changed · needs rebuild")
        }
        if project.ios != nil, inspections[project.id]?.readiness == .upToDate, let message = states[project.id], failures[project.id] == nil {
            status = message
        }
        if isRunning(project) {
            let current = receipts[project.id].map { runningPaths.contains(URL(fileURLWithPath: $0.appPath).resolvingSymlinksInPath().path) } ?? false
            status = (current ? String(localized: "Running") : String(localized: "Older version running")) + " · " + status
        }
        return status
    }

    /// Not published: filled while rendering. Reading the sources can take a moment, so only an explicit refresh empties it.
    private var iconCache: [UUID: (project: Project, path: String, image: NSImage)] = [:]

    func forgetIcons() { iconCache = [:] }

    /// The built bundle's icon when it has its own, otherwise the icon declared in the sources, otherwise Electron's or a symbol.
    func icon(for project: Project) -> NSImage {
        let path = receipts[project.id]?.appPath ?? project.appURL.path
        if let cached = iconCache[project.id], cached.project == project, cached.path == path { return cached.image }
        let bundle = URL(fileURLWithPath: path)
        let built = FileManager.default.fileExists(atPath: path)
        let image: NSImage
        if built, project.ios == nil, SourceIcon.bundleHasIcon(bundle) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if let source = SourceIcon.locate(for: project), let file = NSImage(contentsOf: source.url) {
            image = source.needsMask ? Self.homeScreenShape(file) : file
        } else if built, project.ios == nil {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSImage(systemSymbolName: project.ios == nil ? "app" : (project.ios?.deviceFamilies == [2] ? "ipad" : "iphone"), accessibilityDescription: nil)!
        }
        iconCache[project.id] = (project, path, image)
        return image
    }

    /// A square iOS icon, rounded and inset like a macOS icon so that it lines up with its neighbours.
    private static func homeScreenShape(_ source: NSImage) -> NSImage {
        let side: CGFloat = 256, inset = side * 0.1, inner = side - 2 * inset
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let frame = NSRect(x: inset, y: inset, width: inner, height: inner)
            NSBezierPath(roundedRect: frame, xRadius: inner * 0.225, yRadius: inner * 0.225).addClip()
            source.draw(in: frame)
            return true
        }
    }

    func launch(_ project: Project, force: Bool = false) {
        guard busyID == nil else { return }
        if project.ios != nil { launchMobile(project, force: force); return }
        busyID = project.id
        failures[project.id] = nil
        Task {
            defer { busyID = nil }
            do {
                let prepared = try await engine.prepare(project, force: force) { [self] phase in
                    await setPhase(phase, for: project.id)
                }
                steps[project.id] = .opening; states[project.id] = String(localized: "Opening…")
                let activated = try await openLatest(prepared.url)
                states[project.id] = activated ? String(localized: "Brought to front · no build") :
                    (prepared.rebuilt ? String(localized: "New version launched") : String(localized: "Launched · no build"))
                receipts[project.id] = await engine.receipt(for: project.id)
                await engine.pruneOldBuilds(for: project.id,
                    protecting: NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
            } catch {
                states[project.id] = String(localized: "Launch interrupted")
                failures[project.id] = error.localizedDescription
                receipts[project.id] = await engine.receipt(for: project.id)
            }
            inspections[project.id] = await engine.inspect(project)
            refreshRunning()
        }
    }

    func launchPrevious(_ project: Project) {
        guard busyID == nil else { return }
        if project.ios != nil { launchMobile(project, previous: true); return }
        busyID = project.id
        failures[project.id] = nil
        states[project.id] = String(localized: "Opening the previous build…")
        Task {
            defer { busyID = nil }
            do { _ = try await openLatest(engine.previousApp(for: project.id).url) }
            catch { failures[project.id] = error.localizedDescription }
            refreshRunning()
        }
    }

    func destination(for project: Project) -> LaunchDestination? {
        guard project.ios != nil, let saved = destinationChoices[project.id.uuidString] else { return nil }
        return destinations.first { $0.id == saved.id } ?? saved
    }

    @discardableResult
    func refreshDestinations() async -> DestinationInventory {
        if let task = destinationTask { return await task.value }
        isLoadingDestinations = true
        let task = Task { await DestinationInventory.read() }
        destinationTask = task
        let inventory = await task.value
        destinations = inventory.destinations; destinationIssues = inventory.issues
        destinationTask = nil; isLoadingDestinations = false
        return inventory
    }

    func chooseDestination(_ destination: LaunchDestination, for project: Project) {
        guard busyID == nil else { return }
        rememberDestination(destination, for: project)
        states[project.id] = nil; failures[project.id] = nil
        inspections[project.id] = nil; receipts[project.id] = nil
        Task { await refreshStatus() }
    }

    private func rememberDestination(_ destination: LaunchDestination, for project: Project) {
        destinationChoices[project.id.uuidString] = destination
        if let data = try? JSONEncoder().encode(destinationChoices) { UserDefaults.standard.set(data, forKey: "destinationChoices.v1") }
    }

    func logURL(for id: UUID) -> URL {
        if let project = projects.first(where: { $0.id == id }), let destination = destination(for: project) {
            return mobileEngine.logURL(for: project, destination: destination)
        }
        return engine.logURL(for: id)
    }

    private func inspect(_ project: Project) async -> ProjectInspection? {
        if project.ios != nil {
            guard let destination = destination(for: project) else { return nil }
            return await mobileEngine.inspect(project, destination: destination)
        }
        return await engine.inspect(project)
    }

    private func launchMobile(_ project: Project, force: Bool = false, previous: Bool = false) {
        guard let saved = destination(for: project) else {
            AppWindows.showDestinations(self, project: project, launch: true, force: force); return
        }
        busyID = project.id; failures[project.id] = nil
        states[project.id] = String(localized: "Looking for the destination…")
        Task {
            defer { busyID = nil }
            do {
                let inventory = await refreshDestinations()
                guard let current = inventory.destinations.first(where: { $0.id == saved.id }) else {
                    throw LauncherError.message(String(localized: "\(saved.name) was not found. Reconnect the device or choose another destination.") +
                        (inventory.issues.isEmpty ? "" : " " + inventory.issues.joined(separator: " ")))
                }
                rememberDestination(current, for: project)
                let prepared = try await mobileEngine.launch(project, destination: current, force: force, previous: previous) { [self] step, message in
                    await setMobilePhase(step, message, for: project.id)
                }
                states[project.id] = previous ? String(localized: "Previous build launched") : (prepared.rebuilt ? String(localized: "New version launched") : String(localized: "Launched · no build"))
                if current.kind == .simulator { try await showSimulator(current) }
            } catch { states[project.id] = String(localized: "Launch interrupted"); failures[project.id] = error.localizedDescription }
            inspections[project.id] = await inspect(project)
            receipts[project.id] = inspections[project.id]?.receipt
        }
    }

    private func setMobilePhase(_ step: LaunchStep, _ message: String, for id: UUID) {
        if step == .building, steps[id] != .building { buildStartedAt = Date() }
        steps[id] = step; states[id] = message
    }

    /// Where the running launch of a project stands, from 0 to 1; nil when it is building without an estimate.
    func progress(for project: Project, at date: Date) -> Double? {
        guard busyID == project.id else { return nil }
        let building = buildStartedAt.flatMap { start in
            expectedBuildSeconds.map { date.timeIntervalSince(start) / max($0, 0.5) }
        }
        return LaunchStep.progress(step: steps[project.id], building: building)
    }

    private func showSimulator(_ destination: LaunchDestination) async throws {
        let developer = await Task.detached {
            (try? ProcessRunner.capture("/usr/bin/xcode-select", ["-p"]))
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }.value
        guard let developer else { throw LauncherError.message(String(localized: "The app is running, but the Xcode folder was not found to show its simulator.")) }
        let root = URL(fileURLWithPath: developer)
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        let hub = root.appendingPathComponent("../Applications/DeviceHub.app").standardizedFileURL
        if FileManager.default.fileExists(atPath: hub.path) {
            // Xcode 27 exposes device windows through Device Hub's registered URL handler.
            var link = URLComponents()
            link.scheme = "devices"; link.host = "device"; link.path = "/open"
            link.queryItems = [URLQueryItem(name: "id", value: destination.udid)]
            guard let url = link.url else { throw LauncherError.message(String(localized: "Could not prepare the Device Hub link.")) }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: hub, configuration: options)
        } else {
            let locations = [root.appendingPathComponent("Applications/Simulator.app"), root.appendingPathComponent("../Applications/Simulator.app").standardizedFileURL]
            guard let simulator = locations.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw LauncherError.message(String(localized: "The app is running, but the simulator window was not found in Xcode."))
            }
            options.arguments = ["-CurrentDeviceUDID", destination.udid]
            _ = try await NSWorkspace.shared.openApplication(at: simulator, configuration: options)
        }
    }

    func setShortcut(_ choice: LauncherShortcut) {
        shortcut = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "launcherShortcut")
        activateShortcut()
    }

    func activateShortcut() { shortcutError = hotKey.register(shortcut) }

    func setFavorite(_ project: Project, _ favorite: Bool) {
        if favorite { favorites.insert(project.id) } else { favorites.remove(project.id) }
        UserDefaults.standard.set(favorites.map(\.uuidString).sorted(), forKey: "favoriteProjectIDs")
    }

    @discardableResult
    func move(_ id: UUID, before target: UUID) -> Bool {
        guard let order = ProjectList.moving(id, before: target, in: orderedProjects, favorites: favorites) else { return false }
        projectOrder = order
        UserDefaults.standard.set(order.map(\.uuidString), forKey: "projectOrder")
        return true
    }

    /// Reorders a group as shown in the window (favorites, other apps): its members swap places among themselves only.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int, in group: [Project]) {
        var reordered = group.map(\.id)
        reordered.move(fromOffsets: offsets, toOffset: destination)
        var order = orderedProjects.map(\.id)
        let members = Set(reordered)
        for (slot, id) in zip(order.indices.filter { members.contains(order[$0]) }, reordered) { order[slot] = id }
        projectOrder = order
        UserDefaults.standard.set(order.map(\.uuidString), forKey: "projectOrder")
    }

    func move(_ project: Project, down: Bool) {
        let group = visibleProjects.filter { favorites.contains($0.id) == favorites.contains(project.id) }
        guard let index = group.firstIndex(where: { $0.id == project.id }) else { return }
        if down, index + 1 < group.count { move(group[index + 1].id, before: project.id) }
        else if !down, index > 0 { move(project.id, before: group[index - 1].id) }
    }

    func discover(force: Bool = false) {
        guard !isDiscovering, force || Date().timeIntervalSince(lastDiscovery) > 60 else { return }
        isDiscovering = true
        let roots = discoveryRoots, registered = projects, ignored = ignoredDiscoveries
        Task {
            let result = await Task.detached(priority: .utility) {
                ProjectDiscovery.scan(roots: roots, registered: registered, ignored: ignored)
            }.value
            isDiscovering = false
            if roots != discoveryRoots || registered != projects || ignored != ignoredDiscoveries { discover(force: true); return }
            candidates = result.candidates.filter { $0.project.appURL.lastPathComponent != Bundle.main.bundleURL.lastPathComponent }
            discoveryIssues = result.issues
            lastDiscovery = Date()
        }
    }

    func ignore(_ candidate: DiscoveredProject) {
        ignoredDiscoveries.insert(candidate.id)
        UserDefaults.standard.set(ignoredDiscoveries.sorted(), forKey: "ignoredDiscoveries")
        candidates.removeAll { $0.id == candidate.id }
    }

    func resetIgnoredDiscoveries() {
        ignoredDiscoveries = []
        UserDefaults.standard.removeObject(forKey: "ignoredDiscoveries")
        discover(force: true)
    }

    func setDiscoveryRoots(_ roots: [String]) {
        discoveryRoots = roots
        UserDefaults.standard.set(roots, forKey: "discoveryRoots")
        discover(force: true)
    }

    private func setPhase(_ phase: BuildPhase, for id: UUID) {
        if phase == .building, steps[id] != .building { buildStartedAt = Date() }
        steps[id] = LaunchStep(phase)
        switch phase {
        case .checking: states[id] = String(localized: "Checking files…")
        case .building: states[id] = String(localized: "Building…")
        case .copying: states[id] = String(localized: "Preparing the app…")
        }
    }

    private func openLatest(_ url: URL) async throws -> Bool {
        let identifier = Bundle(url: url)?.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path ||
                (identifier != nil && $0.bundleIdentifier == identifier)
        }
        if let current = running.first(where: { $0.bundleURL?.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }) {
            current.activate(options: [.activateAllWindows])
            return true
        }
        // Normal termination lets document-based apps display their save dialog. Never kill.
        for app in running {
            guard app.terminate() || app.isTerminated else {
                app.activate(options: [.activateAllWindows])
                throw LauncherError.message(String(localized: "Quit \(app.localizedName ?? String(localized: "the older version")) after saving your work, then try again."))
            }
        }
        for _ in 0..<80 {
            if running.allSatisfy(\.isTerminated) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard running.allSatisfy(\.isTerminated) else {
            throw LauncherError.message(String(localized: "The older version is still open. Finish quitting it, then try again."))
        }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        options.createsNewApplicationInstance = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: options)
        try await Task.sleep(nanoseconds: 400_000_000)
        guard !app.isTerminated else {
            throw LauncherError.message(String(localized: "The app quit right after launching. Check its macOS diagnostics."))
        }
        return false
    }

    func save(_ project: Project) throws {
        try project.validate()
        var updated = projects
        if let index = updated.firstIndex(where: { $0.id == project.id }) { updated[index] = project }
        else { updated.append(project) }
        updated.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try ProjectStore.save(updated, to: configURL)
        projects = updated
        states[project.id] = nil; failures[project.id] = nil
        sidebarSelection = .project(project.id)
        Task { await refreshStatus() }
        discover(force: true)
    }

    func remove(_ project: Project) {
        do {
            let updated = projects.filter { $0.id != project.id }
            try ProjectStore.save(updated, to: configURL)
            projects = updated; sidebarSelection = updated.first.map { .project($0.id) }
            setHidden(project, false)
            setFavorite(project, false)
            inspections[project.id] = nil
            destinationChoices[project.id.uuidString] = nil
            if let data = try? JSONEncoder().encode(destinationChoices) { UserDefaults.standard.set(data, forKey: "destinationChoices.v1") }
            discover(force: true)
        } catch { configurationError = error.localizedDescription }
    }

    func setHidden(_ project: Project, _ hidden: Bool) {
        if hidden { hiddenProjectIDs.insert(project.id) }
        else { hiddenProjectIDs.remove(project.id) }
        // Visibility is a preference, separate from the recipe and its build fingerprint.
        UserDefaults.standard.set(hiddenProjectIDs.map(\.uuidString).sorted(), forKey: "hiddenProjectIDs")
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            startAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                configurationError = String(localized: "Allow Appothèque in System Settings → General → Login Items & Extensions.")
            }
        } catch { configurationError = error.localizedDescription }
    }
}

enum SidebarItem: Hashable {
    case project(UUID)
    case candidate(String)
}

struct DestinationRequest: Identifiable, Equatable {
    let projectID: UUID
    var launch = false
    var force = false
    var id: UUID { projectID }
}
