import Foundation

public struct DiscoveredProject: Identifiable, Sendable {
    public let project: Project
    public let kind: String
    public let note: String
    public var id: String {
        project.directoryURL.resolvingSymlinksInPath().path + "|" + project.appURL.lastPathComponent.lowercased() +
            (project.ios.map { "|ios|" + $0.container + "|" + $0.scheme } ?? "")
    }
}

public struct DiscoveryResult: Sendable {
    public let candidates: [DiscoveredProject]
    public let issues: [String]
}

/// Only reads manifests. Scanning never runs a package manifest, project script or build tool.
public enum ProjectDiscovery {
    private static let skipped: Set<String> = ["node_modules", "target", "dist", "build", "vendor", "Pods", "Sources", "Tests", "Packages", "docs", "evidence", "artifacts", "runtime", "venv", "__pycache__"]

    /// Usual places for source code, in order; only those that exist are proposed for a first discovery.
    public static let usualRoots = ["~/Developer", "~/Dev", "~/Projects", "~/Code", "~/src", "~/GitHub"]

    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        var seen: Set<String> = []
        return usualRoots.filter { root in
            let url = home.appendingPathComponent(String(root.dropFirst(2)))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            // Case-insensitive volumes: ~/Dev and ~/dev are the same folder.
            return seen.insert(url.resolvingSymlinksInPath().path.lowercased()).inserted
        }
    }

    public static func scan(roots: [String], registered: [Project], ignored: Set<String> = []) -> DiscoveryResult {
        var candidates: [DiscoveredProject] = [], issues: [String] = []
        var seen: Set<String> = []
        for path in roots {
            let root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                issues.append(String(localized: "Folder not accessible: \(path)")); continue
            }
            // The selected folder can itself be a project, or contain project folders.
            let isProject = [".git", "Package.swift", "package.json", "project.yml", "Cargo.toml"].contains {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
            } || children.contains { $0.pathExtension == "xcodeproj" }
            for projectRoot in isProject ? [root] : children.filter(isProjectDirectory) {
                for candidate in discover(in: projectRoot) {
                    let alreadyAdded = registered.contains {
                        $0.directoryURL.resolvingSymlinksInPath().path == candidate.project.directoryURL.resolvingSymlinksInPath().path &&
                        ($0.ios != nil) == (candidate.project.ios != nil) &&
                        ($0.ios == nil || ($0.ios?.container == candidate.project.ios?.container && $0.ios?.scheme == candidate.project.ios?.scheme)) &&
                        ($0.appURL.lastPathComponent.caseInsensitiveCompare(candidate.project.appURL.lastPathComponent) == .orderedSame ||
                         $0.name.caseInsensitiveCompare(candidate.project.name) == .orderedSame ||
                         $0.exclusions.contains { candidate.project.appPath.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") })
                    }
                    if !alreadyAdded, !ignored.contains(candidate.id), seen.insert(candidate.id).inserted { candidates.append(candidate) }
                }
            }
        }
        return DiscoveryResult(candidates: candidates.sorted { $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending }, issues: issues)
    }

    public static func discover(in root: URL) -> [DiscoveredProject] {
        var results: [DiscoveredProject] = []
        // Native iOS projects often live in apps/mobile/ios. Keep discovery bounded and read-only.
        var queue: [(URL, Int)] = [(root, 0)], visited = 0
        while !queue.isEmpty, visited < 300 {
            let (directory, depth) = queue.removeFirst(); visited += 1
            let prefix = directory == root ? "" : String(directory.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1)) + "/"
            if depth < 4 {
                let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                queue += children.filter(isProjectDirectory).sorted { $0.path < $1.path }.map { ($0, depth + 1) }
            }
            if let tauri = tauri(in: directory, root: root, prefix: prefix) { results.append(tauri) }
            if let electron = electron(in: directory, root: root, prefix: prefix) { results.append(electron) }
            let projects = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "xcodeproj" }
            for project in projects { results += xcode(project: project, root: root, prefix: prefix) }
            if projects.isEmpty { results += xcodegen(in: directory, root: root, prefix: prefix) }
            if projects.isEmpty, !FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path),
               let swift = swiftPackage(in: directory, root: root, prefix: prefix) { results.append(swift) }
        }
        return results
    }

    private static func isProjectDirectory(_ url: URL) -> Bool {
        !url.lastPathComponent.hasPrefix(".") && !skipped.contains(url.lastPathComponent) &&
        !url.lastPathComponent.hasSuffix("-evidence") && !url.lastPathComponent.hasSuffix("-worktrees") &&
        url.pathExtension.isEmpty && (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true &&
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }

    private static func tauri(in directory: URL, root: URL, prefix: String) -> DiscoveredProject? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("src-tauri/tauri.conf.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = config["productName"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
        let cargo = (try? String(contentsOf: root.appendingPathComponent("Cargo.toml"), encoding: .utf8)) ?? ""
        let workspace = cargo.contains("[workspace]")
        let output = (workspace ? "" : prefix + "src-tauri/") + "target/release/bundle/macos/\(name).app"
        let manager: String
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) { manager = "pnpm exec tauri build --bundles app" }
        else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) { manager = "yarn tauri build --bundles app" }
        else { manager = "./node_modules/.bin/tauri build --bundles app" }
        let sidecars = ((config["bundle"] as? [String: Any])?["externalBin"] as? [String]) ?? []
        let command: String
        if !sidecars.isEmpty, FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/build-release.sh").path) {
            command = "/bin/bash scripts/build-release.sh"
        } else { command = (prefix.isEmpty ? "" : "cd \(quote(String(prefix.dropLast())))\n") + manager }
        let note = sidecars.isEmpty ? String(localized: "Tauri configuration found. The project’s dependencies must be installed.") :
            String(localized: "This project bundles helper executables: check how the proposed command prepares them.")
        return DiscoveredProject(project: Project(name: name, directory: root.path, buildCommand: command, appPath: output,
            exclusions: [prefix + "src-tauri/gen", prefix + "src-tauri/binaries"]), kind: "Tauri", note: note)
    }

    private static func xcode(project: URL, root: URL, prefix: String) -> [DiscoveredProject] {
        guard let data = try? Data(contentsOf: project.appendingPathComponent("project.pbxproj")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]] else { return [] }
        let projectObject = objects[plist["rootObject"] as? String ?? ""] ?? [:]
        func settings(_ object: [String: Any]) -> [String: Any] {
            let list = objects[object["buildConfigurationList"] as? String ?? ""]
            let ids = list?["buildConfigurations"] as? [String] ?? []
            let config = ids.compactMap { objects[$0] }.first { ($0["name"] as? String) == "Debug" } ?? ids.first.flatMap { objects[$0] }
            return config?["buildSettings"] as? [String: Any] ?? [:]
        }
        return objects.flatMap { id, target -> [DiscoveredProject] in
            guard target["productType"] as? String == "com.apple.product-type.application", let name = target["name"] as? String else { return [] }
            let merged = settings(projectObject).merging(settings(target)) { _, new in new }
            let sdk = merged["SDKROOT"] as? String ?? ""
            let platforms = String(describing: merged["SUPPORTED_PLATFORMS"] ?? "")
            let mac = sdk == "macosx" || platforms.contains("macosx") || (merged["MACOSX_DEPLOYMENT_TARGET"] != nil && !sdk.hasPrefix("iphone"))
            let ios = sdk.hasPrefix("iphone") || platforms.contains("iphone") ||
                (merged["IPHONEOS_DEPLOYMENT_TARGET"] != nil && sdk != "macosx" && !platforms.contains("macosx"))
            guard mac || ios else { return [] }
            let product = objects[target["productReference"] as? String ?? ""]?["path"] as? String ?? name + ".app"
            guard product.hasSuffix(".app"), !product.contains("$("), !product.contains("/") else { return [] }
            let schemesDir = project.appendingPathComponent("xcshareddata/xcschemes")
            let schemes = ((try? FileManager.default.contentsOfDirectory(at: schemesDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "xcscheme" }.sorted {
                    if $0.deletingPathExtension().lastPathComponent == name { return true }
                    if $1.deletingPathExtension().lastPathComponent == name { return false }
                    return $0.lastPathComponent < $1.lastPathComponent
                }
            let scheme = schemes.first { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.range(of: "BlueprintIdentifier\\s*=\\s*\"" + NSRegularExpression.escapedPattern(for: id) + "\"", options: .regularExpression) != nil
            }?.deletingPathExtension().lastPathComponent ?? name
            let generate = FileManager.default.fileExists(atPath: project.deletingLastPathComponent().appendingPathComponent("project.yml").path)
            let command = (prefix.isEmpty ? "" : "cd \(quote(String(prefix.dropLast())))\n") + (generate ? "xcodegen generate\n" : "") +
                "xcodebuild -project \(quote(project.lastPathComponent)) -scheme \(quote(scheme)) -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/Appotheque build"
            var results: [DiscoveredProject] = []
            if mac {
                results.append(DiscoveredProject(project: Project(name: name, directory: root.path, buildCommand: command,
                    appPath: prefix + ".build/Appotheque/Build/Products/Debug/" + product), kind: "Xcode · macOS", note: String(localized: "macOS target “\(name)”, scheme “\(scheme)”.")))
            }
            if ios {
                let parent = project.deletingLastPathComponent()
                let workspace = ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "xcworkspace" }.sorted { $0.path < $1.path }.first {
                        ((try? String(contentsOf: $0.appendingPathComponent("contents.xcworkspacedata"), encoding: .utf8)) ?? "").contains(project.lastPathComponent)
                    }
                let container = prefix + (workspace ?? project).lastPathComponent
                let families = String(describing: merged["TARGETED_DEVICE_FAMILY"] ?? "1,2")
                    .split { !$0.isNumber }.compactMap { Int($0) }.filter { $0 == 1 || $0 == 2 }
                let prep = generate ? (prefix.isEmpty ? "" : "cd \(quote(String(prefix.dropLast())))\n") + "xcodegen generate" : ""
                results.append(DiscoveredProject(project: Project(name: name, directory: root.path, buildCommand: prep,
                    appPath: product, exclusions: generate ? generatedExclusions(prefix + project.lastPathComponent) : [],
                    ios: IOSProject(container: container, scheme: scheme, deviceFamilies: families,
                        minimumOS: merged["IPHONEOS_DEPLOYMENT_TARGET"] as? String)), kind: "Xcode · iOS/iPadOS",
                    note: String(localized: "Scheme “\(scheme)”. Pick a simulator, an iPhone or an iPad on first launch.")))
            }
            return results
        }
    }

    private static func xcodegen(in directory: URL, root: URL, prefix: String) -> [DiscoveredProject] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("project.yml"), encoding: .utf8),
              let projectName = capture("(?m)^name:\\s*[\"']?([^\\n\"']+)", in: text) else { return [] }
        // Conventional XcodeGen target blocks; complex YAML remains a manual configuration.
        guard let range = text.range(of: "(?m)^targets:\\s*\\n", options: .regularExpression) else { return [] }
        let targets = String(text[range.upperBound...]).components(separatedBy: .newlines)
        var blocks: [(String, String)] = []
        var name: String?, lines: [String] = []
        for line in targets {
            if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("#") { break }
            if let target = capture("^  ([^ ].*):\\s*$", in: line) {
                if let name { blocks.append((name, lines.joined(separator: "\n"))) }
                name = target.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")); lines = []
            } else { lines.append(line) }
        }
        if let name { blocks.append((name, lines.joined(separator: "\n"))) }
        return blocks.compactMap { name, body in
            guard body.range(of: "(?m)^    type:\\s*application\\s*$", options: .regularExpression) != nil,
                  let platform = capture("(?m)^    platform:\\s*(macOS|iOS)\\s*$", in: body) else { return nil }
            let product = capture("(?m)^\\s+PRODUCT_NAME:\\s*[\"']?([^\\n\"']+)", in: body) ?? name
            guard !product.contains("$("), !product.contains("/") else { return nil }
            if platform == "iOS" {
                let container = prefix + projectName + ".xcodeproj"
                let families = capture("(?m)^\\s+TARGETED_DEVICE_FAMILY:\\s*[\"']?([^\\n\"']+)", in: body)?
                    .split { !$0.isNumber }.compactMap { Int($0) } ?? [1, 2]
                let minimum = capture("(?m)^\\s+(?:IPHONEOS_DEPLOYMENT_TARGET|deploymentTarget):\\s*[\"']?([0-9.]+)", in: body)
                return DiscoveredProject(project: Project(name: name, directory: root.path,
                    buildCommand: (prefix.isEmpty ? "" : "cd \(quote(String(prefix.dropLast())))\n") + "xcodegen generate",
                    appPath: product + ".app", exclusions: generatedExclusions(container),
                    ios: IOSProject(container: container, scheme: name, deviceFamilies: families, minimumOS: minimum)),
                    kind: "XcodeGen · iOS/iPadOS", note: String(localized: "The Xcode project is generated before building for the chosen destination."))
            }
            let command = (prefix.isEmpty ? "" : "cd \(quote(String(prefix.dropLast())))\n") +
                "xcodegen generate\nxcodebuild -project \(quote(projectName + ".xcodeproj")) -scheme \(quote(name)) -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/Appotheque build"
            return DiscoveredProject(project: Project(name: name, directory: root.path, buildCommand: command,
                appPath: prefix + ".build/Appotheque/Build/Products/Debug/\(product).app"), kind: "XcodeGen", note: String(localized: "macOS target found in project.yml. The Xcode project is generated at build time."))
        }
    }

    /// Electron needs a packager to produce a .app; the recipe pins the host architecture so the output path is known.
    private static func electron(in directory: URL, root: URL, prefix: String) -> DiscoveredProject? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let dependencies = ["dependencies", "devDependencies"].reduce(into: [String: Any]()) { all, key in
            all.merge((package[key] as? [String: Any]) ?? [:]) { current, _ in current }
        }
        guard dependencies["electron"] != nil else { return nil }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let builder = package["build"] as? [String: Any]
        let forge = ((package["config"] as? [String: Any])?["forge"] as? [String: Any])?["packagerConfig"] as? [String: Any]
        let packageName = (package["productName"] as? String) ?? (package["name"] as? String)
        let fileManager = FileManager.default
        let runner: String
        if fileManager.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) { runner = "pnpm exec " }
        else if fileManager.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) { runner = "yarn " }
        else { runner = "./node_modules/.bin/" }

        let tool: String, name: String?, output: String, packageCommand: String
        var exclusions: [String] = []
        if dependencies["@electron-forge/cli"] != nil {
            tool = "Electron Forge"; name = (forge?["name"] as? String) ?? packageName
            output = "out/\(name ?? "")-darwin-\(arch)/\(name ?? "").app"
            packageCommand = runner + "electron-forge package --arch=\(arch)"
            exclusions = [prefix + "out"]
        } else if dependencies["electron-builder"] != nil {
            tool = "electron-builder"; name = (builder?["productName"] as? String) ?? packageName
            let folder = ((builder?["directories"] as? [String: Any])?["output"] as? String) ?? "dist"
            output = "\(folder)/\(arch == "arm64" ? "mac-arm64" : "mac")/\(name ?? "").app"
            packageCommand = runner + "electron-builder --mac --dir --\(arch)"
            if folder != "dist" { exclusions = [prefix + folder] }
        } else if dependencies["@electron/packager"] != nil || dependencies["electron-packager"] != nil {
            tool = "electron-packager"; name = packageName
            output = "out/\(name ?? "")-darwin-\(arch)/\(name ?? "").app"
            packageCommand = runner + "electron-packager . --platform=darwin --arch=\(arch) --out=out --overwrite"
            exclusions = [prefix + "out"]
        } else if let main = package["main"] as? String, !main.isEmpty {
            return electronWrapper(in: directory, root: root, prefix: prefix, main: main,
                                   name: (package["productName"] as? String) ?? root.lastPathComponent.capitalized,
                                   runner: runner, buildScript: (package["scripts"] as? [String: String])?["build"] != nil)
        } else { return nil }
        guard let name, !name.isEmpty, !name.contains("/") else { return nil }

        // A separate "build" script usually compiles the renderer before packaging (Vite, webpack…).
        let scripts = (package["scripts"] as? [String: String]) ?? [:]
        var prepare: String?
        if let script = scripts["build"], !["electron-builder", "electron-forge", "electron-packager"].contains(where: script.contains) {
            prepare = runner == "yarn " ? "yarn build" : runner == "pnpm exec " ? "pnpm run build" : "npm run build"
        }
        let command = (prefix.isEmpty ? "" : "cd \(quote(String(prefix.dropLast())))\n") + [prepare, packageCommand].compactMap { $0 }.joined(separator: "\n")
        return DiscoveredProject(project: Project(name: name, directory: root.path, buildCommand: command, appPath: prefix + output,
            exclusions: exclusions), kind: "Electron · \(tool)",
            note: String(localized: "Dependencies must be installed. Check the product name if the configuration lives in a JavaScript file (forge.config.js, electron-builder.config.js)."))
    }

    /// Electron without a packager: wrap the Electron.app from node_modules so that it runs the project's compiled main
    /// in place. A bootstrap restores the login shell PATH, which an app opened from the Finder does not inherit.
    private static func electronWrapper(in directory: URL, root: URL, prefix: String, main: String, name: String,
                                        runner: String, buildScript: Bool) -> DiscoveredProject? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let projectDirectory = directory.resolvingSymlinksInPath().path
        let mainPath = URL(fileURLWithPath: projectDirectory).appendingPathComponent(main).standardizedFileURL.path
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        // Outside the project: the generated bundle must not show up as untracked files in its repository.
        let app = "~/Library/Caches/Appotheque/Electron/\(slug)/\(name).app"
        let build = buildScript ? (runner == "yarn " ? "yarn build\n" : runner == "pnpm exec " ? "pnpm run build\n" : "npm run build\n") : ""
        let manifest = jsonLiteral(["name": slug, "productName": name, "main": "bootstrap.cjs"])
        // The copied Electron.app keeps Electron's icon unless the project's own .icns replaces it.
        let icon = projectIcon(in: directory).map {
            "ditto \(quote($0)) \"$appotheque_bundle/Contents/Resources/AppIcon.icns\"\n" +
            "/usr/bin/plutil -replace CFBundleIconFile -string 'AppIcon.icns' \"$appotheque_bundle/Contents/Info.plist\"\n"
        } ?? ""
        let command = (prefix.isEmpty ? "" : "cd \(quote(String(prefix.dropLast())))\n") + build + """
        appotheque_electron="$(node -p 'path.dirname(path.dirname(path.dirname(require("electron"))))')"
        appotheque_bundle="$HOME"/\(quote(String(app.dropFirst(2))))
        rm -rf "$appotheque_bundle"
        mkdir -p "$(dirname "$appotheque_bundle")"
        ditto "$appotheque_electron" "$appotheque_bundle"
        mkdir -p "$appotheque_bundle/Contents/Resources/app"
        printf '%s\\n' \(quote(manifest)) > "$appotheque_bundle/Contents/Resources/app/package.json"
        cat > "$appotheque_bundle/Contents/Resources/app/bootstrap.cjs" <<'APPOTHEQUE'
        // Generated by Appothèque: runs the project's compiled code with the Electron from node_modules.
        const { execFileSync } = require("child_process");
        const { pathToFileURL } = require("url");
        try { process.env.PATH = execFileSync("/bin/zsh", ["-l", "-c", 'printf %s "$PATH"'], { encoding: "utf8", timeout: 5000 }); } catch {}
        process.chdir(\(jsonLiteral(projectDirectory)));
        import(pathToFileURL(\(jsonLiteral(mainPath))).href).catch((error) => {
          require("electron").dialog.showErrorBox(\(jsonLiteral(name)), String((error && error.stack) || error));
          process.exit(1);
        });
        APPOTHEQUE
        /usr/bin/plutil -replace CFBundleName -string \(quote(name)) "$appotheque_bundle/Contents/Info.plist"
        /usr/bin/plutil -replace CFBundleDisplayName -string \(quote(name)) "$appotheque_bundle/Contents/Info.plist"
        /usr/bin/plutil -replace CFBundleIdentifier -string \(quote("local.appotheque.electron." + slug)) "$appotheque_bundle/Contents/Info.plist"
        \(icon)codesign --force --deep --sign - "$appotheque_bundle"
        """
        return DiscoveredProject(project: Project(name: name, directory: root.path, buildCommand: command, appPath: app),
            kind: String(localized: "Electron · development"),
            note: String(localized: "No packaging tool: the app is assembled from the Electron in node_modules and runs the project’s compiled code in place. Dependencies must be installed."))
    }

    /// The project's .icns relative to its directory: `AppIcon.icns` or `icon.icns` closest to the root, otherwise the only
    /// .icns found. Dependencies and build outputs are skipped; several unnamed candidates are too ambiguous to pick from.
    static func projectIcon(in directory: URL) -> String? {
        let skipped: Set<String> = ["node_modules", "out", "release", "dist", "dist-electron", "target", "docs"]
        var found: [String] = []
        func visit(_ folder: URL, _ relative: String, depth: Int) {
            guard depth <= 4, let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                                      options: [.skipsHiddenFiles]) else { return }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent, path = relative + name
                if item.pathExtension == "icns" { found.append(path) }
                else if !skipped.contains(name), !name.hasPrefix("dist"), item.pathExtension.isEmpty,
                        (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(item, path + "/", depth: depth + 1)
                }
            }
        }
        visit(directory, "", depth: 0)
        let named = found.filter { ["appicon.icns", "icon.icns"].contains(($0 as NSString).lastPathComponent.lowercased()) }
        if let best = named.min(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) { return best }
        return found.count == 1 ? found[0] : nil
    }

    private static func jsonLiteral(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func swiftPackage(in directory: URL, root: URL, prefix: String) -> DiscoveredProject? {
        guard let manifest = try? String(contentsOf: directory.appendingPathComponent("Package.swift"), encoding: .utf8), manifest.contains(".macOS"),
              let product = capture("\\.executable\\s*\\(\\s*name:\\s*\"([^\"]+)\"", in: manifest),
              !product.contains("/"), hasNativeUI(in: directory.appendingPathComponent("Sources")) else { return nil }
        let build = directory.appendingPathComponent("build.sh")
        if let script = try? String(contentsOf: build, encoding: .utf8),
           let output = capture("(?m)^(?:bundle|APP_BUNDLE|APP_PATH)=\"(?:\\$project_dir/|\\$\\{project_dir\\}/)?([^\"$`\\n]+\\.app)\"", in: script) {
            return DiscoveredProject(project: Project(name: URL(fileURLWithPath: output).deletingPathExtension().lastPathComponent,
                directory: root.path, buildCommand: (prefix.isEmpty ? "" : "cd \(quote(String(prefix.dropLast())))\n") + "/bin/bash build.sh",
                appPath: prefix + output), kind: "Swift Package", note: String(localized: "build.sh script and bundle path found; check that the script builds without opening the app."))
        }
        let app = ".build/Appotheque/\(product).app"
        let identifier = "local.appotheque." + root.lastPathComponent.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let command = (prefix.isEmpty ? "" : "cd \(quote(String(prefix.dropLast())))\n") + """
        swift build -c release --product \(quote(product))
        appotheque_bin="$(swift build -c release --show-bin-path)"
        appotheque_bundle=\(quote(app))
        mkdir -p "$appotheque_bundle/Contents/MacOS" "$appotheque_bundle/Contents/Resources"
        cp "$appotheque_bin"/\(quote(product)) "$appotheque_bundle/Contents/MacOS"/\(quote(product))
        for resource in "$appotheque_bin"/*.bundle(N); do
          [ ! -d "$resource" ] || ditto "$resource" "$appotheque_bundle/$(basename "$resource")"
        done
        /usr/bin/plutil -create xml1 "$appotheque_bundle/Contents/Info.plist"
        /usr/bin/plutil -insert CFBundleExecutable -string \(quote(product)) "$appotheque_bundle/Contents/Info.plist"
        /usr/bin/plutil -insert CFBundleIdentifier -string \(quote(identifier)) "$appotheque_bundle/Contents/Info.plist"
        /usr/bin/plutil -insert CFBundlePackageType -string APPL "$appotheque_bundle/Contents/Info.plist"
        /usr/bin/plutil -insert CFBundleName -string \(quote(product)) "$appotheque_bundle/Contents/Info.plist"
        /usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$appotheque_bundle/Contents/Info.plist"
        codesign --force --deep --sign - "$appotheque_bundle"
        """
        return DiscoveredProject(project: Project(name: product, directory: root.path, buildCommand: command, appPath: prefix + app),
            kind: "Swift Package", note: String(localized: "Local bundle proposed for a SwiftUI/AppKit app. Add any permissions or resources this project needs."))
    }

    private static func hasNativeUI(in sources: URL) -> Bool {
        guard let items = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return false }
        var count = 0
        for case let file as URL in items where file.pathExtension == "swift" {
            count += 1; if count > 250 { break }
            if let text = try? String(contentsOf: file, encoding: .utf8), text.contains("import SwiftUI") || text.contains("import AppKit") { return true }
        }
        return false
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func generatedExclusions(_ container: String) -> [String] {
        // Keep Package.resolved visible even when XcodeGen owns the project and shared schemes.
        [container + "/project.pbxproj", container + "/xcshareddata/xcschemes", container + "/project.xcworkspace/contents.xcworkspacedata"]
    }
}
