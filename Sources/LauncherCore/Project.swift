import Foundation

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var directory: String
    public var buildCommand: String
    public var appPath: String
    public var exclusions: [String]
    public var extraWatchPaths: [String]
    public var ios: IOSProject?

    public init(id: UUID = UUID(), name: String = String(localized: "New App"), directory: String = "",
                buildCommand: String = "", appPath: String = "", exclusions: [String] = [],
                extraWatchPaths: [String] = [], ios: IOSProject? = nil) {
        self.id = id; self.name = name; self.directory = directory
        self.buildCommand = buildCommand; self.appPath = appPath
        self.exclusions = exclusions; self.extraWatchPaths = extraWatchPaths
        self.ios = ios
    }

    public var directoryURL: URL {
        URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath).standardizedFileURL
    }

    public func resolve(_ path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : directoryURL.appendingPathComponent(expanded)).standardizedFileURL
    }

    public var appURL: URL { resolve(appPath) }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !directory.isEmpty, (ios != nil || !buildCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              !appPath.isEmpty else {
            throw LauncherError.message(String(localized: "Enter the name, folder, command and built app."))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue, directoryURL.path != "/" else {
            throw LauncherError.message(String(localized: "Project folder not found: \(directory)"))
        }
        guard appURL.pathExtension == "app" else {
            throw LauncherError.message(String(localized: "The built app must be a .app folder."))
        }
        if let ios { try ios.validate(in: self) }
    }
}

public enum LauncherError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct BuildReceipt: Codable, Sendable {
    public let inputDigest: String
    public let artifactStamp: String
    public let appPath: String
    public let builtAt: Date
    /// Absent from receipts written before Appothèque could list changed files.
    public let settingsDigest: String?
    public let files: [String: String]?

    public init(inputDigest: String, artifactStamp: String, appPath: String, builtAt: Date,
                settingsDigest: String? = nil, files: [String: String]? = nil) {
        self.inputDigest = inputDigest; self.artifactStamp = artifactStamp
        self.appPath = appPath; self.builtAt = builtAt
        self.settingsDigest = settingsDigest; self.files = files
    }
}

public struct PreparedApp: Sendable {
    public let url: URL
    public let rebuilt: Bool
    public let builtAt: Date
}

public enum BuildPhase: Sendable { case checking, building, copying }

/// What a launch is doing, for the short label of a row while it runs.
public enum LaunchStep: Sendable {
    case checking, building, preparing, booting, installing, opening

    public init(_ phase: BuildPhase) {
        switch phase {
        case .checking: self = .checking
        case .building: self = .building
        case .copying: self = .preparing
        }
    }

    public var short: String {
        switch self {
        case .checking: return String(localized: "Checking…")
        case .building: return String(localized: "Building…")
        case .preparing: return String(localized: "Preparing…")
        case .booting: return String(localized: "Booting…")
        case .installing: return String(localized: "Installing…")
        case .opening: return String(localized: "Opening…")
        }
    }
}

public enum ProjectStore {
    public static func load(from url: URL) throws -> [Project] {
        let projects = try JSONDecoder().decode([Project].self, from: Data(contentsOf: url))
        guard Set(projects.map(\.id)).count == projects.count else {
            throw LauncherError.message(String(localized: "The configuration contains duplicate project identifiers."))
        }
        return projects
    }

    public static func save(_ projects: [Project], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(projects).write(to: url, options: .atomic)
    }
}
