import Foundation
import XCTest
@testable import LauncherCore

final class SourceIconTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Appotheque Icons \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testAppIconSetPicksTheLargestImageOfThePlatform() throws {
        let set = "App/Assets.xcassets/AppIcon.appiconset"
        try write(#"{"images":[{"idiom":"iphone","size":"60x60","scale":"3x","filename":"phone.png"},{"idiom":"ios-marketing","size":"1024x1024","scale":"1x","filename":"marketing.png"},{"idiom":"mac","size":"512x512","scale":"2x","filename":"mac.png"},{"idiom":"mac","size":"16x16","scale":"1x","filename":"small.png"},{"idiom":"mac","size":"1024x1024","scale":"1x","filename":"missing.png"}]}"#, set + "/Contents.json")
        for file in ["phone.png", "marketing.png", "mac.png", "small.png"] { try write("png", "\(set)/\(file)") }
        try write("png", "docs/brand/AppIcon.appiconset/Contents.json")

        let mac = try XCTUnwrap(SourceIcon.locate(for: Project(directory: root.path, appPath: "App.app")))
        XCTAssertEqual(mac.url.lastPathComponent, "mac.png")
        XCTAssertFalse(mac.needsMask)
        let phone = try XCTUnwrap(SourceIcon.locate(for: Project(directory: root.path, appPath: "App.app",
                                                                  ios: IOSProject(container: "App.xcodeproj", scheme: "App"))))
        XCTAssertEqual(phone.url.lastPathComponent, "marketing.png")
        XCTAssertTrue(phone.needsMask)
    }

    func testTheAppFolderWinsAndExclusionsAndDependenciesAreSkipped() throws {
        try write("icns", "legacy-ui/src-tauri/icons/icon.icns")
        try write("icns", "desktop/node_modules/electron/dist/Electron.app/Contents/Resources/icon.icns")
        try write("icns", "desktop/release/mac-arm64/App.app/Contents/Resources/icon.icns")
        let excluded = Project(directory: root.path, buildCommand: "cd desktop\nnpm run package",
                               appPath: "desktop/release/mac-arm64/App.app", exclusions: ["legacy-ui"])
        XCTAssertNil(SourceIcon.locate(for: excluded))

        try write("icns", "desktop/build/icon.icns")
        try write("icns", "other/AppIcon.icns")
        let preferred = Project(directory: root.path, buildCommand: "cd 'desktop'\nnpm run package", appPath: "~/Library/Caches/App.app")
        XCTAssertEqual(SourceIcon.locate(for: preferred)?.url.resolvingSymlinksInPath().path,
                       root.appendingPathComponent("desktop/build/icon.icns").resolvingSymlinksInPath().path)
    }

    func testOnlyARealBundleIconHidesTheSourceIcon() throws {
        func bundle(_ name: String, _ plist: [String: Any]) throws -> URL {
            let app = root.appendingPathComponent("\(name).app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            XCTAssertTrue(NSDictionary(dictionary: plist).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true))
            return app
        }
        XCTAssertTrue(SourceIcon.bundleHasIcon(try bundle("Xcode", ["CFBundleIconName": "AppIcon"])))
        XCTAssertTrue(SourceIcon.bundleHasIcon(try bundle("Tauri", ["CFBundleIconFile": "icon.icns"])))
        XCTAssertFalse(SourceIcon.bundleHasIcon(try bundle("Electron", ["CFBundleIconFile": "electron.icns"])))
        XCTAssertFalse(SourceIcon.bundleHasIcon(try bundle("Bare", [:])))
        XCTAssertFalse(SourceIcon.bundleHasIcon(root.appendingPathComponent("Missing.app")))
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
