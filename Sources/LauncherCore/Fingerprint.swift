import CryptoKit
import Foundation

public enum Fingerprint {
    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".derivedData", "DerivedData", "node_modules", "target", "dist", "build",
        ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next",
        ".cache", ".worktrees", ".idea", ".claude", ".codex", ".agents"
    ]

    public static func inputs(for project: Project) throws -> String { try snapshot(for: project).digest }

    /// The project's inputs: one digest for the whole, plus one per file and one for the recipe and Xcode,
    /// so that a receipt can tell which files changed since the build. The whole digest is computed exactly
    /// as before per-file digests existed, so older receipts stay valid.
    public static func snapshot(for project: Project) throws -> InputSnapshot {
        var hash = SHA256()
        var settings = SHA256()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let recipe = try encoder.encode(project)
        hash.update(data: recipe); settings.update(data: recipe)
        // Changing the selected Xcode or replacing it invalidates the successful build.
        if let developer = try? ProcessRunner.capture("/usr/bin/xcode-select", ["-p"]) {
            hash.update(data: developer); settings.update(data: developer)
            let path = String(decoding: developer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let version = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("../version.plist")) {
                hash.update(data: version); settings.update(data: version)
            }
        }
        let root = project.directoryURL
        var paths: [URL]
        if let gitRootData = try? ProcessRunner.capture("/usr/bin/git", ["rev-parse", "--show-toplevel"], in: root),
           URL(fileURLWithPath: String(decoding: gitRootData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath() == root.resolvingSymlinksInPath() {
            let data = try ProcessRunner.capture("/usr/bin/git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: root)
            paths = data.split(separator: 0).map { root.appendingPathComponent(String(decoding: $0, as: UTF8.self)) }
            // Local environment configuration often affects a build despite being gitignored.
            paths += try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent == ".env" || $0.lastPathComponent.hasPrefix(".env.") }
        } else {
            paths = try files(in: root, excluding: project.exclusions)
        }
        var expanded: [URL] = []
        for path in paths where !excluded(path, root: root, extra: project.exclusions) {
            if (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // Git lists a submodule as a directory. Watch its actual worktree as well.
                expanded += try files(in: path, excluding: [])
            } else { expanded.append(path) }
        }
        for extra in project.extraWatchPaths {
            let url = project.resolve(extra)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LauncherError.message(String(localized: "Watched path not found: \(extra)"))
            }
            if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                expanded += try files(in: url, excluding: [])
            } else { expanded.append(url) }
        }
        var digests: [String: String] = [:]
        for file in Set(expanded).sorted(by: { $0.path < $1.path }) {
            let name = displayPath(file, root: root)
            hash.update(data: Data((file.path + "\0").utf8))
            // A tracked deletion is an input change, not a read failure.
            guard FileManager.default.fileExists(atPath: file.path) else {
                hash.update(data: Data("missing\0".utf8)); continue
            }
            var own = SHA256()
            let before = try FileManager.default.attributesOfItem(atPath: file.path)
            if (before[.type] as? FileAttributeType) == .typeSymbolicLink {
                let target = Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8)
                hash.update(data: target); own.update(data: target)
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk); own.update(data: chunk) }
            let after = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date),
                  (before[.size] as? UInt64) == (after[.size] as? UInt64) else {
                throw LauncherError.message(String(localized: "Files are changing during the check. Try again once they are saved."))
            }
            hash.update(data: Data("\0".utf8))
            digests[name] = hex(own.finalize())
        }
        return InputSnapshot(digest: hex(hash.finalize()), settingsDigest: hex(settings.finalize()), files: digests)
    }

    /// A path relative to the project folder, or the full path (with ~) for a watched path outside it.
    private static func displayPath(_ file: URL, root: URL) -> String {
        for base in [root.path, root.resolvingSymlinksInPath().path] where file.path.hasPrefix(base + "/") {
            return String(file.path.dropFirst(base.count + 1))
        }
        let resolved = file.resolvingSymlinksInPath().path, resolvedRoot = root.resolvingSymlinksInPath().path
        if resolved.hasPrefix(resolvedRoot + "/") { return String(resolved.dropFirst(resolvedRoot.count + 1)) }
        return (file.path as NSString).abbreviatingWithTildeInPath
    }

    public static func artifact(at app: URL) throws -> String {
        try validateApp(at: app)
        // Directory enumeration resolves /var to /private/var on macOS. Use the same
        // root spelling for relative paths, regardless of how the bundle was found.
        let root = app.resolvingSymlinksInPath()
        var hash = SHA256()
        for file in try files(in: root, excluding: [], filterBuildOutputs: false).sorted(by: { $0.path < $1.path }) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let relative = String(file.path.dropFirst(root.path.count))
            let stamp = "\(relative)\0\(attrs[.size] ?? 0)\0\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)\0\(attrs[.posixPermissions] ?? 0)\0"
            hash.update(data: Data(stamp.utf8))
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8))
            }
        }
        return hex(hash.finalize())
    }

    public static func validateApp(at url: URL) throws {
        let macOS = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
        let plist = url.appendingPathComponent(macOS ? "Contents/Info.plist" : "Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent((macOS ? "Contents/MacOS/" : "") + executable).path) else {
            throw LauncherError.message(String(localized: "The built app is missing or incomplete: \(url.path)"))
        }
    }

    private static func excluded(_ file: URL, root: URL, extra: [String]) -> Bool {
        // Foundation may enumerate /private/var while the configured URL spells it /var.
        let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        if relative.split(separator: "/").contains(where: { ignoredDirectories.contains(String($0)) || $0.hasSuffix(".app") }) { return true }
        if file.lastPathComponent == ".DS_Store" { return true }
        return extra.contains { relative == $0 || relative.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") }
    }

    private static func files(in root: URL, excluding extra: [String], filterBuildOutputs: Bool = true) throws -> [URL] {
        var result: [URL] = []
        var readError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, error in readError = error; return false }) else {
            throw LauncherError.message(String(localized: "Could not read \(root.path)."))
        }
        for case let url as URL in enumerator {
            if filterBuildOutputs && excluded(url, root: root, extra: extra) {
                // On a regular file, skipDescendants can suppress the next directory's contents.
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory != true || values.isSymbolicLink == true { result.append(url) }
        }
        if let readError { throw readError }
        return result
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

public struct InputSnapshot: Sendable {
    /// The digest a receipt is compared with.
    public let digest: String
    /// The recipe and the selected Xcode.
    public let settingsDigest: String
    /// Relative path → SHA-256 of the file's content. Missing tracked files are left out.
    public let files: [String: String]
}

/// What differs between the inputs of the last successful build and the current ones.
public struct InputChanges: Equatable, Sendable {
    public var modified: [String] = []
    public var added: [String] = []
    public var removed: [String] = []
    /// The recipe or the selected Xcode changed.
    public var settingsChanged = false
    /// The built app was modified or removed since the build.
    public var appChanged = false
    /// On a device, the provisioning profile of the installed build needs renewal.
    public var profileRenewal = false
    /// False for a receipt written before per-file digests existed.
    public var detailsAvailable = true

    public init() {}

    public init(since receipt: BuildReceipt, now: InputSnapshot, appIntact: Bool) {
        appChanged = !appIntact
        guard let files = receipt.files, let settings = receipt.settingsDigest else { detailsAvailable = false; return }
        settingsChanged = settings != now.settingsDigest
        modified = files.keys.filter { now.files[$0] != nil && now.files[$0] != files[$0] }.sorted()
        removed = files.keys.filter { now.files[$0] == nil }.sorted()
        added = now.files.keys.filter { files[$0] == nil }.sorted()
    }

    public var fileCount: Int { modified.count + added.count + removed.count }
}

/// A 3×3 glyph drawn from a digest, echoing the app's icon: the centre cell is always lit,
/// the eight others follow the first byte of the digest. The same inputs always give the same glyph.
public enum FingerprintGlyph {
    public static func cells(for digest: String) -> [Bool] {
        let byte = UInt8(digest.prefix(2), radix: 16) ?? 0
        let outer = (0..<8).map { byte & (1 << $0) != 0 }
        return Array(outer[0..<4]) + [true] + Array(outer[4..<8])
    }
}
