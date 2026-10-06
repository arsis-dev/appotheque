import Foundation

public struct GitInfo: Equatable, Sendable {
    public let branch: String
    public let isDirty: Bool

    public static func read(at directory: URL) -> GitInfo? {
        func git(_ arguments: [String]) -> String? {
            guard let data = try? ProcessRunner.capture("/usr/bin/git", arguments, in: directory) else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let root = git(["rev-parse", "--show-toplevel"]),
              URL(fileURLWithPath: root).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path else { return nil }
        let branch = git(["symbolic-ref", "--quiet", "--short", "HEAD"])
            ?? git(["rev-parse", "--short", "HEAD"]).map { "HEAD · " + $0 }
        guard let branch else { return nil }
        return GitInfo(branch: branch, isDirty: !(git(["status", "--porcelain", "--untracked-files=normal"]) ?? "").isEmpty)
    }
}

public enum BuildReadiness: Equatable, Sendable {
    case firstBuild, upToDate, changed, failed(String), unavailable(String)

    public var label: String {
        switch self {
        case .firstBuild: return String(localized: "Needs build")
        case .upToDate: return String(localized: "Up to date")
        case .changed: return String(localized: "Code changed · needs rebuild")
        case .failed: return String(localized: "Last build failed")
        case .unavailable: return String(localized: "Could not check")
        }
    }
}

public struct BuildVersion: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let builtAt: Date
    public let artifactStamp: String?
    public var inputDigest: String? = nil
}

public struct BuildFailure: Codable, Sendable {
    public let date: Date
    public let message: String
}

public struct ProjectInspection: Sendable {
    public let readiness: BuildReadiness
    public let git: GitInfo?
    public let receipt: BuildReceipt?
    public let previous: BuildVersion?
    public let checkedAt: Date
    /// The digest of the current inputs, when they were read.
    public var inputDigest: String? = nil
    /// What changed since the last successful build, when the readiness is `.changed`.
    public var changes: InputChanges? = nil
}
