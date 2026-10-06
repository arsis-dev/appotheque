import Foundation

/// The icon a project declares in its sources, shown while no built bundle provides one.
public struct SourceIcon: Equatable, Sendable {
    public let url: URL
    /// An iOS image is a full square: the launcher rounds it like the Home Screen does.
    public let needsMask: Bool

    private static let skipped: Set<String> = [
        "node_modules", "DerivedData", "target", "out", "release", "Builds", "docs", "Pods", "Carthage", "artifacts"
    ]

    /// Whether a built bundle shows its own icon. Electron's default icon and a bundle without one do not count.
    public static func bundleHasIcon(_ app: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return false }
        if info["CFBundleIconName"] != nil { return true }
        guard let file = info["CFBundleIconFile"] as? String, !file.isEmpty else { return false }
        return !["electron", "electron.icns"].contains(file.lowercased())
    }

    /// Looks for `AppIcon.appiconset` images and `AppIcon.icns`/`icon.icns` files, ignoring dependencies, build outputs,
    /// documentation and the project's exclusions. The folder holding the app (Xcode container, `cd` of the recipe,
    /// first folder of the output path) wins over the rest of the repository; then the shallowest candidate.
    public static func locate(for project: Project, maxDepth: Int = 5) -> SourceIcon? {
        // Enumerated paths are resolved (/var → /private/var): compare everything in that form.
        let root = project.directoryURL.resolvingSymlinksInPath()
        let excluded = Set(project.exclusions.map { project.resolve($0).resolvingSymlinksInPath().path })
        var found: [(icon: SourceIcon, path: String, depth: Int)] = []
        func visit(_ folder: URL, depth: Int) {
            guard depth <= maxDepth, let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                guard !excluded.contains(item.resolvingSymlinksInPath().path) else { continue }
                if item.pathExtension == "icns" {
                    if ["appicon", "icon"].contains(item.deletingPathExtension().lastPathComponent.lowercased()) {
                        found.append((SourceIcon(url: item, needsMask: false), item.resolvingSymlinksInPath().path, depth))
                    }
                    continue
                }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if name == "AppIcon.appiconset" {
                    if let icon = appIconSet(item, mac: project.ios == nil) { found.append((icon, item.resolvingSymlinksInPath().path, depth)) }
                } else if !skipped.contains(name), !name.hasPrefix("dist"), !["app", "xcodeproj", "xcworkspace"].contains(item.pathExtension) {
                    visit(item, depth: depth + 1)
                }
            }
        }
        visit(root, depth: 0)
        let hint = appFolder(of: project).map { $0.resolvingSymlinksInPath().path + "/" }
        return found.min { a, b in
            let aIn = hint.map { a.path.hasPrefix($0) } ?? false, bIn = hint.map { b.path.hasPrefix($0) } ?? false
            if aIn != bIn { return aIn }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path < b.path
        }?.icon
    }

    /// The largest image of an icon set, preferring the idioms of the target platform.
    static func appIconSet(_ folder: URL, mac: Bool) -> SourceIcon? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Contents.json")),
              let images = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["images"] as? [[String: Any]] else { return nil }
        let candidates: [(url: URL, mac: Bool, pixels: Double)] = images.compactMap { image in
            guard let file = image["filename"] as? String else { return nil }
            let url = folder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = Double((image["size"] as? String)?.split(separator: "x").first ?? "") ?? 0
            let scale = Double((image["scale"] as? String)?.dropLast() ?? "") ?? 1
            return (url, image["idiom"] as? String == "mac", size * scale)
        }
        let preferred = candidates.filter { $0.mac == mac }
        guard let best = (preferred.isEmpty ? candidates : preferred).max(by: { $0.pixels < $1.pixels }) else { return nil }
        return SourceIcon(url: best.url, needsMask: !best.mac)
    }

    private static func appFolder(of project: Project) -> URL? {
        if let ios = project.ios, !ios.container.isEmpty { return project.resolve(ios.container).deletingLastPathComponent() }
        let firstLine = project.buildCommand.split(separator: "\n").first.map(String.init) ?? ""
        if firstLine.hasPrefix("cd ") {
            let folder = firstLine.dropFirst(3).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            if !folder.isEmpty { return project.resolve(folder) }
        }
        let output = project.appPath
        guard !output.hasPrefix("/"), !output.hasPrefix("~"), let first = output.split(separator: "/").first,
              output.contains("/") else { return nil }
        return project.resolve(String(first))
    }
}
