import CryptoKit
import Foundation

public struct IOSProject: Codable, Equatable, Sendable {
    public var container: String
    public var scheme: String
    public var configuration: String
    public var deviceFamilies: [Int]
    public var minimumOS: String?

    public init(container: String = "", scheme: String = "", configuration: String = "Debug",
                deviceFamilies: [Int] = [1, 2], minimumOS: String? = nil) {
        self.container = container; self.scheme = scheme; self.configuration = configuration
        self.deviceFamilies = deviceFamilies; self.minimumOS = minimumOS
    }

    func validate(in project: Project) throws {
        guard ["xcodeproj", "xcworkspace"].contains(project.resolve(container).pathExtension),
              !scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherError.message(String(localized: "Enter the Xcode project (.xcodeproj or .xcworkspace), the scheme and the iOS configuration."))
        }
        if !FileManager.default.fileExists(atPath: project.resolve(container).path), project.buildCommand.isEmpty {
            throw LauncherError.message(String(localized: "Xcode project not found. Check its path or add a preparation command."))
        }
    }
}

public struct LaunchDestination: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case simulator, device }
    public let kind: Kind
    public let identifier: String
    public let udid: String
    public let name: String
    public let osVersion: String
    public let family: Int
    public let isAvailable: Bool
    public let isBooted: Bool
    public let developerModeEnabled: Bool?
    public let runtime: String

    public var id: String { kind.rawValue + ":" + udid }
    public var symbol: String { family == 2 ? "ipad" : "iphone" }
    public var label: String { name + " · " + (family == 2 ? "iPadOS " : "iOS ") + osVersion }
    public var status: String {
        if !isAvailable { return String(localized: "Unavailable") }
        if kind == .simulator { return isBooted ? String(localized: "Booted") : String(localized: "Ready to boot") }
        if developerModeEnabled == false { return String(localized: "Developer Mode off") }
        return String(localized: "Paired")
    }
    public var cacheKey: String {
        // OS updates, simulator runtimes and physical devices never share compiled artifacts.
        SHA256.hash(data: Data((id + "|" + runtime + "|" + osVersion).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public init(kind: Kind, identifier: String, udid: String, name: String, osVersion: String,
                family: Int, isAvailable: Bool = true, isBooted: Bool = false,
                developerModeEnabled: Bool? = nil, runtime: String = "") {
        self.kind = kind; self.identifier = identifier; self.udid = udid; self.name = name
        self.osVersion = osVersion; self.family = family; self.isAvailable = isAvailable
        self.isBooted = isBooted; self.developerModeEnabled = developerModeEnabled; self.runtime = runtime
    }

    public func incompatibility(with project: IOSProject) -> String? {
        if !isAvailable { return String(localized: "This destination is unavailable. Refresh the list or reconnect the device.") }
        if kind == .device, developerModeEnabled == false {
            return String(localized: "Turn on Developer Mode in Settings → Privacy & Security on this device.")
        }
        if family == 1, !project.deviceFamilies.isEmpty, !project.deviceFamilies.contains(1) {
            return String(localized: "This app is iPad only.")
        }
        if let minimum = project.minimumOS, !minimum.isEmpty,
           osVersion.compare(minimum, options: .numeric) == .orderedAscending {
            return String(localized: "This app requires iOS/iPadOS \(minimum) or later.")
        }
        return nil
    }
}

public struct DestinationInventory: Sendable {
    public let destinations: [LaunchDestination]
    public let issues: [String]

    public static func read() async -> DestinationInventory {
        async let simulatorResult = simulators()
        async let deviceResult = devices()
        let (simulators, devices) = await (simulatorResult, deviceResult)
        let destinations = (simulators.0 + devices.0).sorted {
            if $0.kind != $1.kind { return $0.kind == .simulator }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.osVersion.compare($1.osVersion, options: .numeric) == .orderedDescending
        }
        return DestinationInventory(destinations: destinations, issues: [simulators.1, devices.1].compactMap { $0 })
    }

    private static func simulators() async -> ([LaunchDestination], String?) {
        do {
            let data = try await AppleCommand.run(["simctl", "list", "devices", "available", "--json"], timeout: 25)
            return (try parseSimulators(data), nil)
        } catch { return ([], String(localized: "Simulators: \(error.localizedDescription)")) }
    }

    private static func devices() async -> ([LaunchDestination], String?) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("appotheque-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await AppleCommand.run(["devicectl", "--timeout", "15", "list", "devices", "--json-output", file.path], timeout: 20)
            return (try parseDevices(Data(contentsOf: file)), nil)
        } catch { return ([], String(localized: "Devices: \(error.localizedDescription)")) }
    }

    public static func parseSimulators(_ data: Data) throws -> [LaunchDestination] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let runtimes = json?["devices"] as? [String: [[String: Any]]] else {
            throw LauncherError.message(String(localized: "Xcode returned a simulator list that could not be read."))
        }
        var seen: Set<String> = []
        return runtimes.sorted { $0.key < $1.key }.flatMap { runtime, entries in
            guard runtime.contains(".iOS-") else { return [LaunchDestination]() }
            let version = String(runtime.components(separatedBy: ".iOS-").last ?? "").replacingOccurrences(of: "-", with: ".")
            return entries.compactMap { entry in
                guard entry["isAvailable"] as? Bool == true, let udid = entry["udid"] as? String,
                      let name = entry["name"] as? String, seen.insert(udid).inserted else { return nil }
                let type = entry["deviceTypeIdentifier"] as? String ?? name
                guard type.localizedCaseInsensitiveContains("iphone") || type.localizedCaseInsensitiveContains("ipad") else { return nil }
                return LaunchDestination(kind: .simulator, identifier: udid, udid: udid, name: name,
                    osVersion: version, family: type.localizedCaseInsensitiveContains("ipad") ? 2 : 1,
                    isBooted: entry["state"] as? String == "Booted", runtime: runtime)
            }
        }
    }

    public static func parseDevices(_ data: Data) throws -> [LaunchDestination] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let result = json?["result"] as? [String: Any], let devices = result["devices"] as? [[String: Any]] else {
            throw LauncherError.message(String(localized: "Xcode returned a device list that could not be read."))
        }
        var seen: Set<String> = []
        return devices.compactMap { entry in
            let properties = entry["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any] ?? entry["hardwareProperties"] as? [String: Any] ?? [:]
            let state = properties["state"] as? [String: Any] ?? entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any] ?? entry["connectionProperties"] as? [String: Any] ?? [:]
            let software = properties["software"] as? [String: Any] ?? [:]
            guard hardware["reality"] as? String == "physical",
                  ["iOS", "iPadOS"].contains(hardware["platform"] as? String ?? ""),
                  let udid = hardware["udid"] as? String, let identifier = entry["identifier"] as? String,
                  seen.insert(udid).inserted else { return nil }
            let version = (software["osVersionNumber"] as? [String: Any])?["stringValue"] as? String
                ?? software["osVersionNumber"] as? String ?? state["osVersionNumber"] as? String ?? ""
            let mode = state["developerModeStatus"] as? [String: Any]
            let legacyMode = state["developerModeStatus"] as? String
            let enabled: Bool? = mode?["enabled"] != nil || legacyMode == "enabled" ? true :
                (mode?["disabled"] != nil || legacyMode == "disabled" ? false : nil)
            let connectionState = connection["state"] as? String ?? connection["tunnelState"] as? String
            // A disconnected tunnel may be opened on demand for a paired wireless device.
            let available = connectionState != "unavailable" && connection["pairingState"] as? String == "paired"
            return LaunchDestination(kind: .device, identifier: identifier, udid: udid,
                name: state["name"] as? String ?? String(localized: "iOS Device"), osVersion: version,
                family: hardware["deviceType"] as? String == "iPad" ? 2 : 1,
                isAvailable: available, isBooted: state["bootState"] as? String == "booted", developerModeEnabled: enabled)
        }
    }
}

/// Each command owns its temporary output and has a bounded lifetime. No shell evaluates device identifiers.
enum AppleCommand {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func run(_ arguments: [String], timeout: TimeInterval = 120, logURL: URL? = nil) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try runSynchronously(arguments, timeout: timeout, logURL: logURL)
        }.value
    }

    private static func runSynchronously(_ arguments: [String], timeout: TimeInterval, logURL: URL?) throws -> Data {
            let fm = FileManager.default
            let output = fm.temporaryDirectory.appendingPathComponent("appotheque-command-\(UUID().uuidString).log")
            fm.createFile(atPath: output.path, contents: nil)
            defer { try? fm.removeItem(at: output) }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments; process.environment = ProcessRunner.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle; process.standardError = handle
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            let timedOut = process.isRunning
            if timedOut {
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            let data = try Data(contentsOf: output)
            if let logURL {
                try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
                let log = try FileHandle(forWritingTo: logURL)
                defer { try? log.close() }
                try log.seekToEnd()
                try log.write(contentsOf: Data(("\n\(Date().formatted()) · xcrun " + arguments.map(quote).joined(separator: " ") + "\n").utf8))
                try log.write(contentsOf: data)
            }
            if timedOut { throw LauncherError.message(String(localized: "Xcode did not respond in time. Check that the device is connected and unlocked, then try again.")) }
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw LauncherError.message(String(localized: "\(arguments.prefix(3).joined(separator: " ")) failed. \(String(detail.suffix(1800)))"))
            }
            return data
    }
}
