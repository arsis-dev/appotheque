import Foundation

public actor MobileEngine {
    public nonisolated let storage: URL
    private var engines: [String: BuildEngine] = [:]

    public init(storage: URL) { self.storage = storage }

    public nonisolated func logURL(for project: Project, destination: LaunchDestination) -> URL {
        cacheStorage(destination).appendingPathComponent("Logs/\(project.id.uuidString).log")
    }

    private nonisolated func cacheStorage(_ destination: LaunchDestination) -> URL {
        storage.appendingPathComponent("Mobile/\(destination.cacheKey)")
    }

    private func engine(for destination: LaunchDestination) -> BuildEngine {
        if let engine = engines[destination.cacheKey] { return engine }
        let engine = BuildEngine(storage: cacheStorage(destination))
        engines[destination.cacheKey] = engine
        return engine
    }

    public static func recipe(for project: Project, destination: LaunchDestination) throws -> Project {
        try project.validate()
        guard let ios = project.ios else { throw LauncherError.message(String(localized: "This project is not set up for iOS.")) }
        let derived = project.directoryURL.appendingPathComponent(".build/AppothequeMobile/\(project.id.uuidString)/\(destination.cacheKey)")
        let simulator = destination.kind == .simulator
        let sdk = simulator ? "iphonesimulator" : "iphoneos"
        let arguments = ["xcodebuild", project.resolve(ios.container).pathExtension == "xcworkspace" ? "-workspace" : "-project",
            project.resolve(ios.container).path, "-scheme", ios.scheme, "-configuration", ios.configuration,
            "-sdk", sdk, "-destination", "platform=\(simulator ? "iOS Simulator" : "iOS"),id=\(destination.udid)",
            "-derivedDataPath", derived.path, "build"] + (simulator ? ["CODE_SIGNING_ALLOWED=NO"] : [])
        var prepared = project
        let preparation = project.buildCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        // A prebuild may change its working directory without moving the actual xcodebuild invocation.
        prepared.buildCommand = (preparation.isEmpty ? "" : "(\n\(preparation)\n)\n") + arguments.map(AppleCommand.quote).joined(separator: " ")
        prepared.appPath = derived.appendingPathComponent("Build/Products/\(ios.configuration)-\(sdk)/\(project.appURL.lastPathComponent)").path
        return prepared
    }

    public func receipt(for project: Project, destination: LaunchDestination) async -> BuildReceipt? {
        await engine(for: destination).receipt(for: project.id)
    }

    public func inspect(_ project: Project, destination: LaunchDestination) async -> ProjectInspection {
        do {
            let effective = try Self.recipe(for: project, destination: destination)
            let result = await engine(for: destination).inspect(effective)
            if result.readiness == .upToDate, destination.kind == .device, let saved = result.receipt,
               await Self.profileNeedsRenewal(at: URL(fileURLWithPath: saved.appPath)) {
                var changes = result.changes ?? InputChanges(); changes.profileRenewal = true
                return ProjectInspection(readiness: .changed, git: result.git, receipt: result.receipt,
                    previous: result.previous, checkedAt: result.checkedAt, inputDigest: result.inputDigest, changes: changes)
            }
            return result
        } catch {
            return ProjectInspection(readiness: .unavailable(error.localizedDescription), git: nil,
                receipt: nil, previous: nil, checkedAt: Date())
        }
    }

    public func launch(_ project: Project, destination: LaunchDestination, force: Bool = false, previous: Bool = false,
                       phase: @escaping @Sendable (LaunchStep, String) async -> Void = { _, _ in }) async throws -> PreparedApp {
        guard let ios = project.ios else { throw LauncherError.message(String(localized: "Missing iOS configuration.")) }
        if let reason = destination.incompatibility(with: ios) { throw LauncherError.message(reason) }
        let effective = try Self.recipe(for: project, destination: destination)
        let builder = engine(for: destination)
        let prepared: PreparedApp
        if previous {
            prepared = try await builder.previousApp(for: project.id)
        } else {
            let saved = await builder.receipt(for: project.id)
            let renew = destination.kind == .device && saved != nil
                ? await Self.profileNeedsRenewal(at: URL(fileURLWithPath: saved!.appPath)) : false
            do {
                prepared = try await builder.prepare(effective, force: force || renew) { buildPhase in
                    switch buildPhase {
                    case .checking: await phase(.checking, String(localized: "Checking files…"))
                    case .building: await phase(.building, String(localized: "Building for \(destination.name)…"))
                    case .copying: await phase(.preparing, String(localized: "Preparing the app…"))
                    }
                }
            } catch {
                if destination.kind == .device {
                    throw LauncherError.message(error.localizedDescription + " " + String(localized: "On a physical device, also check the project’s signing and Apple team in Xcode."))
                }
                throw error
            }
        }
        let identifier = try Self.validateBundle(at: prepared.url, for: destination)
        if destination.kind == .device, await Self.profileNeedsRenewal(at: prepared.url) {
            throw LauncherError.message(String(localized: "This build’s signature is missing or expired. Set up the project’s Apple team and signing in Xcode, then force a build."))
        }
        let log = logURL(for: project, destination: destination)
        do {
            if destination.kind == .simulator {
                await phase(.booting, String(localized: "Booting \(destination.name)…"))
                // Re-read boot state: another launch may have started the simulator since discovery.
                let current = try DestinationInventory.parseSimulators(await AppleCommand.run(["simctl", "list", "devices", "available", "--json"], timeout: 25))
                    .first { $0.id == destination.id }
                guard let current else { throw LauncherError.message(String(localized: "This simulator is no longer available. Choose another destination.")) }
                if !current.isBooted { _ = try await AppleCommand.run(["simctl", "boot", destination.udid], timeout: 60, logURL: log) }
                _ = try await AppleCommand.run(["simctl", "bootstatus", destination.udid, "-b"], timeout: 180, logURL: log)
                await phase(.installing, String(localized: "Installing on \(destination.name)…"))
                _ = try await AppleCommand.run(["simctl", "install", destination.udid, prepared.url.path], timeout: 120, logURL: log)
                await phase(.opening, String(localized: "Opening on \(destination.name)…"))
                _ = try await AppleCommand.run(["simctl", "launch", destination.udid, identifier], timeout: 45, logURL: log)
            } else {
                await phase(.installing, String(localized: "Installing on \(destination.name)…"))
                _ = try await AppleCommand.run(["devicectl", "--timeout", "120", "device", "install", "app", "--device", destination.identifier, prepared.url.path], timeout: 130, logURL: log)
                await phase(.opening, String(localized: "Opening on \(destination.name)…"))
                _ = try await AppleCommand.run(["devicectl", "--timeout", "30", "device", "process", "launch", "--device", destination.identifier, identifier], timeout: 40, logURL: log)
            }
        } catch {
            let help = destination.kind == .device ? " " + String(localized: "Check the device’s connection, lock state, pairing and Developer Mode.") : ""
            throw LauncherError.message(error.localizedDescription + help + " " + String(localized: "The log has the details."))
        }
        await builder.pruneOldBuilds(for: project.id, protecting: [])
        return prepared
    }

    @discardableResult
    public static func validateBundle(at url: URL, for destination: LaunchDestination) throws -> String {
        try Fingerprint.validateApp(at: url)
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let platforms = info["CFBundleSupportedPlatforms"] as? [String],
              platforms.contains(destination.kind == .simulator ? "iPhoneSimulator" : "iPhoneOS") else {
            throw LauncherError.message(String(localized: "This build does not match the chosen iOS destination. Check the scheme and the .app bundle name."))
        }
        let configuration = IOSProject(deviceFamilies: info["UIDeviceFamily"] as? [Int] ?? [], minimumOS: info["MinimumOSVersion"] as? String)
        if let reason = destination.incompatibility(with: configuration) { throw LauncherError.message(reason) }
        return identifier
    }

    private static func profileNeedsRenewal(at url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let profile = url.appendingPathComponent("embedded.mobileprovision")
            guard let data = try? ProcessRunner.capture("/usr/bin/security", ["cms", "-D", "-i", profile.path]),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let expiration = plist["ExpirationDate"] as? Date else { return true }
            return expiration <= Date()
        }.value
    }
}
