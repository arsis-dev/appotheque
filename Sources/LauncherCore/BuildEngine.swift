import Foundation

public actor BuildEngine {
    public let storage: URL
    private var building: Set<UUID> = []

    public init(storage: URL) { self.storage = storage }

    public nonisolated func logURL(for id: UUID) -> URL { storage.appendingPathComponent("Logs/\(id.uuidString).log") }
    private func receiptURL(for id: UUID) -> URL { storage.appendingPathComponent("Receipts/\(id.uuidString).json") }
    private func failureURL(for id: UUID) -> URL { storage.appendingPathComponent("Failures/\(id.uuidString).json") }

    public func receipt(for id: UUID) -> BuildReceipt? {
        guard let data = try? Data(contentsOf: receiptURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(BuildReceipt.self, from: data)
    }

    public func inspect(_ project: Project) async -> ProjectInspection {
        let saved = receipt(for: project.id)
        let previous = previousVersion(for: project.id)
        let failure = (try? Data(contentsOf: failureURL(for: project.id))).flatMap { try? JSONDecoder().decode(BuildFailure.self, from: $0) }
        return await Task.detached(priority: .utility) {
            let git = GitInfo.read(at: project.directoryURL)
            let readiness: BuildReadiness
            var digest: String?, changes: InputChanges?
            do {
                try project.validate()
                if let failure { readiness = .failed(failure.message) }
                else if let saved {
                    let now = try Fingerprint.snapshot(for: project)
                    let stamp = try? Fingerprint.artifact(at: URL(fileURLWithPath: saved.appPath))
                    let intact = stamp == saved.artifactStamp
                    digest = now.digest
                    readiness = now.digest == saved.inputDigest && intact ? .upToDate : .changed
                    if readiness == .changed { changes = InputChanges(since: saved, now: now, appIntact: intact) }
                } else { readiness = .firstBuild }
            } catch { readiness = .unavailable(error.localizedDescription) }
            return ProjectInspection(readiness: readiness, git: git, receipt: saved, previous: previous, checkedAt: Date(),
                                     inputDigest: digest, changes: changes)
        }.value
    }

    public func versions(for id: UUID) -> [BuildVersion] {
        let current = receipt(for: id)
        let root = storage.appendingPathComponent("Builds/\(id.uuidString)")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return folders.compactMap { folder -> BuildVersion? in
            guard let app = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
                  (try? Fingerprint.validateApp(at: app)) != nil else { return nil }
            let archived = (try? Data(contentsOf: folder.appendingPathComponent("receipt.json")))
                .flatMap { try? JSONDecoder().decode(BuildReceipt.self, from: $0) }
            let currentPath = current.map { URL(fileURLWithPath: $0.appPath).resolvingSymlinksInPath().path }
            let info = archived ?? (currentPath == app.resolvingSymlinksInPath().path ? current : nil)
            let date = info?.builtAt ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return BuildVersion(url: app, builtAt: date, artifactStamp: info?.artifactStamp, inputDigest: info?.inputDigest)
        }.sorted { $0.builtAt > $1.builtAt }
    }

    public func previousVersion(for id: UUID) -> BuildVersion? {
        let currentPath = receipt(for: id).map { URL(fileURLWithPath: $0.appPath).resolvingSymlinksInPath().path }
        return versions(for: id).first { $0.url.resolvingSymlinksInPath().path != currentPath }
    }

    public func previousApp(for id: UUID) throws -> PreparedApp {
        guard let version = previousVersion(for: id) else { throw LauncherError.message(String(localized: "No previous build is available.")) }
        let stamp = try Fingerprint.artifact(at: version.url)
        if let expected = version.artifactStamp, stamp != expected {
            throw LauncherError.message(String(localized: "The previous build was modified or is incomplete."))
        }
        return PreparedApp(url: version.url, rebuilt: false, builtAt: version.builtAt)
    }

    public func prepare(_ project: Project, force: Bool = false,
                        phase: @escaping @Sendable (BuildPhase) async -> Void = { _ in }) async throws -> PreparedApp {
        try project.validate()
        guard building.insert(project.id).inserted else { throw LauncherError.message(String(localized: "This app is already being built.")) }
        defer { building.remove(project.id) }
        await phase(.checking)
        let before = try await Task.detached { try Fingerprint.snapshot(for: project) }.value
        if !force, let saved = receipt(for: project.id), saved.inputDigest == before.digest,
           let stamp = try? Fingerprint.artifact(at: URL(fileURLWithPath: saved.appPath)), stamp == saved.artifactStamp {
            return PreparedApp(url: URL(fileURLWithPath: saved.appPath), rebuilt: false, builtAt: saved.builtAt)
        }
        // Preserve the last successful build's identity before invalidating its current receipt.
        if let saved = receipt(for: project.id) {
            let app = URL(fileURLWithPath: saved.appPath)
            if app.path.hasPrefix(storage.appendingPathComponent("Builds/\(project.id.uuidString)").path + "/"),
               FileManager.default.fileExists(atPath: app.deletingLastPathComponent().path) {
                try JSONEncoder().encode(saved).write(to: app.deletingLastPathComponent().appendingPathComponent("receipt.json"), options: .atomic)
            }
        }
        // A failed/forced build must never leave a receipt that claims current inputs are safe.
        if FileManager.default.fileExists(atPath: receiptURL(for: project.id).path) {
            try FileManager.default.removeItem(at: receiptURL(for: project.id))
        }
        await phase(.building)
        do {
            let prepared = try await performBuild(project, before: before, phase: phase)
            try? FileManager.default.removeItem(at: failureURL(for: project.id))
            return prepared
        } catch {
            let failure = BuildFailure(date: Date(), message: error.localizedDescription)
            let url = failureURL(for: project.id)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(failure).write(to: url, options: .atomic)
            throw error
        }
    }

    private func performBuild(_ project: Project, before: InputSnapshot,
                              phase: @escaping @Sendable (BuildPhase) async -> Void) async throws -> PreparedApp {
        let started = Date()
        try await ProcessRunner.build(project, logURL: logURL(for: project.id))
        let buildSeconds = Date().timeIntervalSince(started)
        try Fingerprint.validateApp(at: project.appURL)
        let after = try await Task.detached { try Fingerprint.snapshot(for: project) }.value
        guard before.digest == after.digest else {
            throw LauncherError.message(String(localized: "The project changed during the build. Launch again to build its current state."))
        }
        await phase(.copying)
        let generation = storage.appendingPathComponent("Builds/\(project.id.uuidString)/\(UUID().uuidString)")
        let app = generation.appendingPathComponent(project.appURL.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        do {
            // ditto preserves bundle links, resource forks and signing metadata.
            _ = try await Task.detached { try ProcessRunner.capture("/usr/bin/ditto", [project.appURL.path, app.path]) }.value
            let stamp = try Fingerprint.artifact(at: app)
            let receipt = BuildReceipt(inputDigest: after.digest, artifactStamp: stamp, appPath: app.path, builtAt: Date(),
                                       settingsDigest: after.settingsDigest, files: after.files, buildSeconds: buildSeconds)
            try JSONEncoder().encode(receipt).write(to: generation.appendingPathComponent("receipt.json"), options: .atomic)
            let target = receiptURL(for: project.id)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(receipt).write(to: target, options: .atomic)
            return PreparedApp(url: app, rebuilt: true, builtAt: receipt.builtAt)
        } catch {
            try? FileManager.default.removeItem(at: generation)
            throw error
        }
    }

    public func pruneOldBuilds(for id: UUID, protecting runningPaths: [String]) {
        let root = storage.appendingPathComponent("Builds/\(id.uuidString)")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let newestFirst = folders.sorted {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        let current = receipt(for: id).map { URL(fileURLWithPath: $0.appPath).resolvingSymlinksInPath().path }
        let protectedPaths = runningPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        for folder in newestFirst.dropFirst(2) {
            let prefix = folder.resolvingSymlinksInPath().path + "/"
            guard !(current?.hasPrefix(prefix) ?? false), !protectedPaths.contains(where: { $0.hasPrefix(prefix) }) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
