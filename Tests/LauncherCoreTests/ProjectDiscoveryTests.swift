import Foundation
import XCTest
@testable import LauncherCore

final class ProjectDiscoveryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Appotheque Discovery \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testContainerDiscoveryHasNoDuplicatesAndDoesNotExecuteScripts() throws {
        try write("platforms: [.macOS(.v14)], products: [.executable(name: \"Sample\", targets: [\"Sample\"])]", "native/Package.swift")
        try write("import SwiftUI\n@main struct Sample: App {}", "native/Sources/Sample.swift")
        try write("bundle=\"dist/Sample.app\"\ntouch executed", "native/build.sh")
        try write("{}", "website/package.json")
        try write("platforms: [.iOS(.v17)], products: [.executable(name: \"Phone\", targets: [])]", "phone/Package.swift")
        try write("import SwiftUI", "phone/Sources/Phone.swift")
        let result = ProjectDiscovery.scan(roots: [root.path, root.path], registered: [])
        XCTAssertEqual(result.candidates.count, 1)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.project.directoryURL.path, root.appendingPathComponent("native").path)
        XCTAssertEqual(candidate.project.buildCommand, "/bin/bash build.sh")
        XCTAssertEqual(candidate.project.appPath, "dist/Sample.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("native/executed").path))
        XCTAssertTrue(ProjectDiscovery.scan(roots: [root.path], registered: [candidate.project]).candidates.isEmpty)
        XCTAssertTrue(ProjectDiscovery.scan(roots: [root.path], registered: [], ignored: [candidate.id]).candidates.isEmpty)
    }

    func testNestedTauriWorkspaceAndUnavailableRoot() throws {
        try write("[workspace]\nmembers = [\"desktop/src-tauri\"]", "Cargo.toml")
        try write("{\"productName\":\"My Desktop\"}", "desktop/src-tauri/tauri.conf.json")
        try write("lock", "desktop/pnpm-lock.yaml")
        let result = ProjectDiscovery.scan(roots: [root.path, root.appendingPathComponent("missing").path], registered: [])
        XCTAssertEqual(result.candidates.count, 1)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.project.appPath, "target/release/bundle/macos/My Desktop.app")
        XCTAssertEqual(candidate.project.buildCommand, "cd 'desktop'\npnpm exec tauri build --bundles app")
        XCTAssertEqual(result.issues.count, 1)
    }

    func testXcodeFindsMacAndIOSTargetsAndUsesSharedScheme() throws {
        let objects: [String: Any] = [
            "root": ["buildConfigurationList": "configs"],
            "configs": ["buildConfigurations": ["debug"]], "debug": ["name": "Debug", "buildSettings": ["MACOSX_DEPLOYMENT_TARGET": "14.0", "IPHONEOS_DEPLOYMENT_TARGET": "18.0"]],
            "mac": ["name": "Desktop", "productType": "com.apple.product-type.application", "productReference": "product", "buildConfigurationList": "macConfigs"],
            "product": ["path": "Desktop.app"], "macConfigs": ["buildConfigurations": ["macDebug"]], "macDebug": ["name": "Debug", "buildSettings": ["SDKROOT": "macosx"]],
            "phone": ["name": "Phone", "productType": "com.apple.product-type.application", "buildConfigurationList": "phoneConfigs"],
            "phoneConfigs": ["buildConfigurations": ["phoneDebug"]], "phoneDebug": ["name": "Debug", "buildSettings": ["SDKROOT": "iphoneos"]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: ["rootObject": "root", "objects": objects], format: .xml, options: 0)
        try write(String(decoding: data, as: UTF8.self), "Sample.xcodeproj/project.pbxproj")
        try write("<BuildableReference BlueprintIdentifier = \"mac\" />", "Sample.xcodeproj/xcshareddata/xcschemes/Desktop Dev.xcscheme")
        let candidates = ProjectDiscovery.scan(roots: [root.path], registered: []).candidates
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(try XCTUnwrap(candidates.first).project.buildCommand.contains("-scheme 'Desktop Dev'"))
        let phone = try XCTUnwrap(candidates.first { $0.project.ios != nil })
        XCTAssertEqual(phone.project.ios?.scheme, "Phone")
        XCTAssertEqual(phone.project.ios?.container, "Sample.xcodeproj")
        XCTAssertEqual(phone.project.appPath, "Phone.app")
    }

    func testXcodegenAndSwiftRecipesArePrefilledSafely() throws {
        try write("name: Desktop\ntargets:\n  Mac App:\n    type: application\n    platform: macOS\n  Phone:\n    type: application\n    platform: iOS\n", "generated/project.yml")
        try write("platforms: [.macOS(.v14)], products: [.executable(name: \"App $value's\", targets: [])]", "swift/Package.swift")
        try write("import AppKit", "swift/Sources/main.swift")
        let candidates = ProjectDiscovery.scan(roots: [root.path], registered: []).candidates
        XCTAssertEqual(candidates.count, 3)
        let swift = try XCTUnwrap(candidates.first { $0.kind == "Swift Package" })
        XCTAssertTrue(swift.project.buildCommand.contains("cp \"$appotheque_bin\"/'App $value'\\''s'"))
        let xcode = try XCTUnwrap(candidates.first { $0.kind == "XcodeGen" })
        XCTAssertEqual(xcode.project.appPath, ".build/Appotheque/Build/Products/Debug/Mac App.app")
        let phone = try XCTUnwrap(candidates.first { $0.project.ios != nil })
        XCTAssertEqual(phone.project.buildCommand, "xcodegen generate")
        XCTAssertEqual(phone.project.ios?.container, "Desktop.xcodeproj")
        XCTAssertNoThrow(try phone.project.validate(), "The preparation command can generate the missing Xcode project.")
    }

    func testGitBranchDirtyStateAndDetachedHeadWithoutParentLeak() throws {
        _ = try ProcessRunner.capture("/usr/bin/git", ["init", "-q", "-b", "feature-launcher"], in: root)
        try write("hello", "source.txt")
        XCTAssertEqual(GitInfo.read(at: root)?.branch, "feature-launcher")
        XCTAssertEqual(GitInfo.read(at: root)?.isDirty, true)
        _ = try ProcessRunner.capture("/usr/bin/git", ["add", "source.txt"], in: root)
        _ = try ProcessRunner.capture("/usr/bin/git", ["-c", "user.name=Appotheque Tests", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"], in: root)
        XCTAssertEqual(GitInfo.read(at: root)?.isDirty, false)
        try write("nested", "child/file.txt")
        XCTAssertNil(GitInfo.read(at: root.appendingPathComponent("child")))
        _ = try ProcessRunner.capture("/usr/bin/git", ["checkout", "--detach", "-q"], in: root)
        XCTAssertTrue(GitInfo.read(at: root)?.branch.hasPrefix("HEAD · ") == true)
    }

    func testElectronPackagersProduceHostArchitectureRecipes() throws {
        #if arch(arm64)
        let arch = "arm64", builderFolder = "mac-arm64"
        #else
        let arch = "x64", builderFolder = "mac"
        #endif
        try write(#"{"name":"forge-app","productName":"Forge App","devDependencies":{"electron":"38.0.0","@electron-forge/cli":"7.0.0"},"scripts":{"build":"electron-forge package"}}"#, "forge/package.json")
        try write(#"{"name":"builder-app","build":{"productName":"Builder App","directories":{"output":"release"}},"devDependencies":{"electron":"38.0.0","electron-builder":"26.0.0"},"scripts":{"build":"vite build"}}"#, "builder/package.json")
        try write("lock", "builder/yarn.lock")
        try write(#"{"name":"packed","devDependencies":{"electron":"38.0.0","@electron/packager":"18.0.0"}}"#, "packer/package.json")
        try write("lock", "packer/pnpm-lock.yaml")
        try write(#"{"name":"bare","devDependencies":{"electron":"38.0.0"}}"#, "bare/package.json")
        try write(#"{"name":"site","dependencies":{"react":"19.0.0"}}"#, "site/package.json")

        let candidates = Dictionary(uniqueKeysWithValues: ProjectDiscovery.scan(roots: [root.path], registered: []).candidates.map { ($0.project.name, $0) })
        XCTAssertEqual(Set(candidates.keys), ["Forge App", "Builder App", "packed"])

        let forge = try XCTUnwrap(candidates["Forge App"]).project
        XCTAssertEqual(forge.buildCommand, "./node_modules/.bin/electron-forge package --arch=\(arch)")
        XCTAssertEqual(forge.appPath, "out/Forge App-darwin-\(arch)/Forge App.app")
        XCTAssertEqual(forge.exclusions, ["out"])

        let builder = try XCTUnwrap(candidates["Builder App"]).project
        XCTAssertEqual(builder.buildCommand, "yarn build\nyarn electron-builder --mac --dir --\(arch)")
        XCTAssertEqual(builder.appPath, "release/\(builderFolder)/Builder App.app")
        XCTAssertEqual(builder.exclusions, ["release"])

        let packer = try XCTUnwrap(candidates["packed"]).project
        XCTAssertEqual(packer.buildCommand, "pnpm exec electron-packager . --platform=darwin --arch=\(arch) --out=out --overwrite")
        XCTAssertEqual(packer.appPath, "out/packed-darwin-\(arch)/packed.app")
        XCTAssertEqual(candidates["packed"]?.kind, "Electron · electron-packager")
    }

    func testElectronWithoutPackagerIsWrappedAroundTheLocalElectron() throws {
        try write(#"{"name":"spicilege"}"#, "spicilege/package.json")
        try write(#"{"name":"spicilege-desktop","main":"dist-electron/main.cjs","scripts":{"build":"vite build"},"devDependencies":{"electron":"44.0.0"}}"#, "spicilege/desktop/package.json")
        try write("lock", "spicilege/desktop/pnpm-lock.yaml")
        let candidate = try XCTUnwrap(ProjectDiscovery.scan(roots: [root.path], registered: []).candidates.first)
        XCTAssertEqual(candidate.project.name, "Spicilege")
        XCTAssertEqual(candidate.kind, "Electron · development")
        XCTAssertEqual(candidate.project.appPath, "~/Library/Caches/Appotheque/Electron/spicilege/Spicilege.app")
        let command = candidate.project.buildCommand
        XCTAssertTrue(command.hasPrefix("cd 'desktop'\npnpm run build\n"))
        XCTAssertTrue(command.contains("local.appotheque.electron.spicilege"))
        let main = root.appendingPathComponent("spicilege/desktop").resolvingSymlinksInPath().appendingPathComponent("dist-electron/main.cjs").path
        XCTAssertTrue(command.contains("pathToFileURL(\"\(main)\")"))
        XCTAssertFalse(command.contains("CFBundleIconFile"))
        // The generated script must at least be valid zsh.
        _ = try ProcessRunner.capture("/bin/zsh", ["-n", "-c", command])
    }

    func testElectronWrapperUsesTheProjectIcon() throws {
        try write(#"{"name":"spicilege-desktop","main":"dist-electron/main.cjs","devDependencies":{"electron":"44.0.0"}}"#, "spicilege/desktop/package.json")
        try write("icns", "spicilege/desktop/assets/icon/AppIcon.icns")
        try write("icns", "spicilege/desktop/node_modules/electron/dist/Electron.app/Contents/Resources/electron.icns")
        try write("icns", "spicilege/desktop/assets/icon/variants/other.icns")
        let command = try XCTUnwrap(ProjectDiscovery.scan(roots: [root.path], registered: []).candidates.first).project.buildCommand
        XCTAssertTrue(command.contains("ditto 'assets/icon/AppIcon.icns' \"$appotheque_bundle/Contents/Resources/AppIcon.icns\"\n"))
        XCTAssertTrue(command.contains("CFBundleIconFile -string 'AppIcon.icns'"))
        // The icon is part of the bundle, so it must be in place before signing.
        XCTAssertLessThan(try XCTUnwrap(command.range(of: "CFBundleIconFile")).lowerBound,
                          try XCTUnwrap(command.range(of: "codesign")).lowerBound)
        _ = try ProcessRunner.capture("/bin/zsh", ["-n", "-c", command])
    }

    func testDefaultRootsKeepExistingUsualFoldersOnce() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Dev"), withIntermediateDirectories: true)
        try write("not a folder", "Code")
        XCTAssertEqual(ProjectDiscovery.defaultRoots(home: root), ["~/Dev", "~/Projects"])
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

final class ProjectListTests: XCTestCase {
    func testFavoritesManualOrderAndSearchPreserveRecipes() throws {
        let a = Project(name: "Éditeur", directory: "/apps/editor")
        let b = Project(name: "Music", directory: "/apps/synth")
        let c = Project(name: "Canvas", directory: "/apps/drawing")
        let all = [a, b, c]
        let pinned = ProjectList.ordered(all, favorites: [c.id], order: [b.id, a.id, c.id])
        XCTAssertEqual(pinned, [c, b, a])
        let moved = try XCTUnwrap(ProjectList.moving(a.id, before: b.id, in: pinned, favorites: [c.id]))
        XCTAssertEqual(ProjectList.ordered(all, favorites: [c.id], order: moved), [c, a, b])
        XCTAssertNil(ProjectList.moving(a.id, before: c.id, in: pinned, favorites: [c.id]))
        XCTAssertNil(ProjectList.moving(UUID(), before: a.id, in: pinned, favorites: []))
        XCTAssertEqual(ProjectList.search(all, query: " EDITEUR apps "), [a])
        XCTAssertEqual(ProjectList.search(all, query: "synth"), [b])
        XCTAssertTrue(ProjectList.search(all, query: "music drawing").isEmpty)
    }
}
