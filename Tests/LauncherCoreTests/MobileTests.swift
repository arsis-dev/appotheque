import Foundation
import XCTest
@testable import LauncherCore

final class MobileTests: XCTestCase {
    private var root: URL!
    private let simulator = LaunchDestination(kind: .simulator, identifier: "SIM-1", udid: "SIM-1", name: "iPhone test", osVersion: "27.0", family: 1, runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
    private let device = LaunchDestination(kind: .device, identifier: "CORE-1", udid: "DEVICE-1", name: "iPad test", osVersion: "27.0", family: 2, developerModeEnabled: true)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Appotheque Mobile's \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testOldMacConfigurationsKeepTheirEncodedFingerprintInputs() throws {
        let original = Data(#"{"appPath":"dist/App.app","buildCommand":"bash build.sh","directory":"/tmp/project","exclusions":[],"extraWatchPaths":[],"id":"11111111-1111-1111-1111-111111111111","name":"App"}"#.utf8)
        let project = try JSONDecoder().decode(Project.self, from: original)
        XCTAssertNil(project.ios)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(try encoder.encode(project), original, "Adding iOS must not invalidate existing Mac receipts.")
    }

    func testSimulatorInventoryFiltersUnavailableAndNonIOSDevices() throws {
        let data = Data(#"""
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
            {"udid":"PHONE","name":"Mon téléphone","deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro","isAvailable":true,"state":"Booted"},
            {"udid":"PAD","name":"iPad Pro","isAvailable":true,"state":"Shutdown"},
            {"udid":"MISSING","name":"iPhone 16","isAvailable":false},
            {"udid":"PHONE","name":"iPhone duplicate","isAvailable":true}],
          "com.apple.CoreSimulator.SimRuntime.watchOS-27-0":[
            {"udid":"WATCH","name":"Apple Watch","isAvailable":true}]
        }}
        """#.utf8)
        let destinations = try DestinationInventory.parseSimulators(data)
        XCTAssertEqual(destinations.count, 2)
        XCTAssertEqual(destinations.first { $0.udid == "PHONE" }?.isBooted, true)
        XCTAssertEqual(destinations.first { $0.udid == "PAD" }?.family, 2)
        XCTAssertEqual(destinations.first?.osVersion, "27.0")
        XCTAssertThrowsError(try DestinationInventory.parseSimulators(Data("{}".utf8)))
    }

    func testPhysicalInventoryAcceptsBothAppleSchemasAndExcludesSimulators() throws {
        let data = Data(#"""
        {"result":{"devices":[
          {"identifier":"OLD","hardwareProperties":{"udid":"PHONE","platform":"iOS","reality":"physical","deviceType":"iPhone"},"deviceProperties":{"name":"Téléphone","osVersionNumber":"26.5","developerModeStatus":"enabled"},"connectionProperties":{"pairingState":"paired","tunnelState":"disconnected"}},
          {"identifier":"NEW","properties":{"hardware":{"udid":"PAD","platform":"iOS","reality":"physical","deviceType":"iPad"},"state":{"name":"Tablette","developerModeStatus":{"disabled":{}}},"software":{"osVersionNumber":{"stringValue":"27.0.1"}},"connection":{"pairingState":"paired","state":"unavailable"}}},
          {"identifier":"SIM","hardwareProperties":{"udid":"SIM","platform":"iOS","reality":"simulated","deviceType":"iPhone"}},
          {"identifier":"WATCH","hardwareProperties":{"udid":"WATCH","platform":"watchOS","reality":"physical","deviceType":"appleWatch"}}
        ]}}
        """#.utf8)
        let destinations = try DestinationInventory.parseDevices(data)
        XCTAssertEqual(destinations.count, 2)
        let phone = try XCTUnwrap(destinations.first { $0.udid == "PHONE" })
        XCTAssertTrue(phone.isAvailable, "A paired wireless device may open its tunnel on demand.")
        XCTAssertEqual(phone.developerModeEnabled, true)
        let pad = try XCTUnwrap(destinations.first { $0.udid == "PAD" })
        XCTAssertEqual(pad.family, 2)
        XCTAssertEqual(pad.osVersion, "27.0.1")
        XCTAssertEqual(pad.developerModeEnabled, false)
        XCTAssertFalse(pad.isAvailable)
    }

    func testDestinationCompatibilityAndPersistence() throws {
        XCTAssertNotNil(simulator.incompatibility(with: IOSProject(deviceFamilies: [2])))
        XCTAssertNil(device.incompatibility(with: IOSProject(deviceFamilies: [1]))) // iPhone compatibility on iPad
        XCTAssertNotNil(simulator.incompatibility(with: IOSProject(minimumOS: "27.1")))
        XCTAssertNil(simulator.incompatibility(with: IOSProject(minimumOS: "9.0")))
        let disabled = LaunchDestination(kind: .device, identifier: "A", udid: "A", name: "Phone", osVersion: "27", family: 1, developerModeEnabled: false)
        XCTAssertTrue(disabled.incompatibility(with: IOSProject())?.contains("Developer Mode") == true)
        let choices = [UUID().uuidString: simulator, UUID().uuidString: device]
        XCTAssertEqual(try JSONDecoder().decode([String: LaunchDestination].self, from: JSONEncoder().encode(choices)), choices)
        XCTAssertNotEqual(simulator.cacheKey, device.cacheKey)
        let upgraded = LaunchDestination(kind: .simulator, identifier: "SIM-1", udid: "SIM-1", name: "Renommé", osVersion: "27.1", family: 1)
        XCTAssertEqual(upgraded.id, simulator.id)
        XCTAssertNotEqual(upgraded.cacheKey, simulator.cacheKey)
    }

    func testRecipesKeepDestinationsSeparateAndQuoteShellArguments() throws {
        try write("", "App's.xcworkspace/contents.xcworkspacedata")
        let project = Project(name: "Mobile", directory: root.path, buildCommand: "cd 'preparation'\ntrue",
            appPath: "My App.app", ios: IOSProject(container: "App's.xcworkspace", scheme: "App $(touch bad)'s"))
        let sim = try MobileEngine.recipe(for: project, destination: simulator)
        let phone = try MobileEngine.recipe(for: project, destination: device)
        XCTAssertNotEqual(sim.appPath, phone.appPath)
        XCTAssertTrue(sim.appPath.contains("Debug-iphonesimulator/My App.app"))
        XCTAssertTrue(phone.appPath.contains("Debug-iphoneos/My App.app"))
        XCTAssertTrue(sim.buildCommand.contains("'CODE_SIGNING_ALLOWED=NO'"))
        XCTAssertFalse(phone.buildCommand.contains("CODE_SIGNING_ALLOWED"))
        XCTAssertTrue(phone.buildCommand.contains("platform=iOS,id=DEVICE-1"))
        XCTAssertTrue(sim.buildCommand.contains("'App $(touch bad)'\\''s'"))
        XCTAssertTrue(sim.buildCommand.hasPrefix("(\ncd 'preparation'\ntrue\n)\n"))
        _ = try ProcessRunner.capture("/bin/zsh", ["-n", "-c", sim.buildCommand])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
        XCTAssertNotEqual(try Fingerprint.inputs(for: sim), try Fingerprint.inputs(for: phone))
    }

    func testMobileBundleValidationRejectsWrongPlatformFamilyAndOS() throws {
        let bundle = root.appendingPathComponent("Sample.app")
        try mobileBundle(bundle, platform: "iPhoneSimulator")
        XCTAssertEqual(try MobileEngine.validateBundle(at: bundle, for: simulator), "local.appotheque.tests")
        XCTAssertThrowsError(try MobileEngine.validateBundle(at: bundle, for: device))
        try mobileBundle(bundle, platform: "iPhoneSimulator", families: [2])
        XCTAssertThrowsError(try MobileEngine.validateBundle(at: bundle, for: simulator))
        try mobileBundle(bundle, platform: "iPhoneSimulator", minimum: "28.0")
        XCTAssertThrowsError(try MobileEngine.validateBundle(at: bundle, for: simulator))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Sample"))
        XCTAssertThrowsError(try Fingerprint.validateApp(at: bundle))
    }

    func testFlatMobileBundlesCanBeCachedAndReusedAfterRestart() async throws {
        let bundle = root.appendingPathComponent("dist/Sample.app")
        try mobileBundle(bundle, platform: "iPhoneSimulator")
        try write("source", "source.swift")
        let project = Project(name: "Mobile", directory: root.path,
            buildCommand: "mkdir -p .build\necho build >> .build/count", appPath: "dist/Sample.app")
        let storage = root.appendingPathComponent(".build/cache")
        let first = try await BuildEngine(storage: storage).prepare(project)
        let second = try await BuildEngine(storage: storage).prepare(project)
        XCTAssertTrue(first.rebuilt)
        XCTAssertFalse(second.rebuilt)
        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".build/count")), "build\n")
    }

    func testNestedWorkspaceDiscoveryAndMacRegistrationDoNotHideIOS() throws {
        let objects: [String: Any] = [
            "root": ["buildConfigurationList": "configs"], "configs": ["buildConfigurations": ["debug"]],
            "debug": ["name": "Debug", "buildSettings": ["SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator", "TARGETED_DEVICE_FAMILY": "2", "IPHONEOS_DEPLOYMENT_TARGET": "26.0"]],
            "app": ["name": "Shared", "productType": "com.apple.product-type.application", "productReference": "product"],
            "product": ["path": "Shared.app"]]
        let data = try PropertyListSerialization.data(fromPropertyList: ["rootObject": "root", "objects": objects], format: .xml, options: 0)
        try write(String(decoding: data, as: UTF8.self), "apps/mobile/ios/Shared.xcodeproj/project.pbxproj")
        try write("<Workspace><FileRef location=\"group:Shared.xcodeproj\" /></Workspace>", "apps/mobile/ios/Shared.xcworkspace/contents.xcworkspacedata")
        try write("{}", "package.json")
        let all = ProjectDiscovery.scan(roots: [root.path], registered: []).candidates
        XCTAssertEqual(all.count, 2)
        let mac = try XCTUnwrap(all.first { $0.project.ios == nil })
        let mobile = try XCTUnwrap(all.first { $0.project.ios != nil })
        XCTAssertEqual(mobile.project.ios?.container, "apps/mobile/ios/Shared.xcworkspace")
        XCTAssertEqual(mobile.project.ios?.deviceFamilies, [2])
        XCTAssertEqual(mobile.project.ios?.minimumOS, "26.0")
        XCTAssertEqual(ProjectDiscovery.scan(roots: [root.path], registered: [mac.project]).candidates.map(\.id), [mobile.id])
        XCTAssertTrue(ProjectDiscovery.scan(roots: [root.path], registered: [mac.project, mobile.project]).candidates.isEmpty)
    }

    func testGeneratedProjectExclusionsKeepDependencyLockWatched() throws {
        try write("name: Phone\ntargets:\n  Phone:\n    type: application\n    platform: iOS\n", "project.yml")
        let project = try XCTUnwrap(ProjectDiscovery.discover(in: root).first).project
        let before = try Fingerprint.inputs(for: project)
        try write("generated", "Phone.xcodeproj/project.pbxproj")
        try write("generated", "Phone.xcodeproj/xcshareddata/xcschemes/Phone.xcscheme")
        XCTAssertEqual(try Fingerprint.inputs(for: project), before, "Generated exclusions: \(project.exclusions), root: \(project.directory)")
        try write("dependency v1", "Phone.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        XCTAssertNotEqual(try Fingerprint.inputs(for: project), before)
    }

    private func mobileBundle(_ url: URL, platform: String, families: [Int] = [1, 2], minimum: String = "18.0") throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "Sample", "CFBundleIdentifier": "local.appotheque.tests",
            "CFBundleSupportedPlatforms": [platform], "UIDeviceFamily": families, "MinimumOSVersion": minimum]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url.appendingPathComponent("Sample"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent("Sample").path)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

final class MobileSimulatorIntegrationTests: XCTestCase {
    /// Opt-in test: installs only a generated fixture on the explicitly supplied simulator.
    func testBuildInstallLaunchCacheAndSourceChangeOnSimulator() async throws {
        guard let udid = ProcessInfo.processInfo.environment["APPOTHEQUE_SMOKE_SIMULATOR"] else {
            throw XCTSkip("Set APPOTHEQUE_SMOKE_SIMULATOR to an isolated iOS simulator UDID for the live integration check.")
        }
        let inventory = await DestinationInventory.read()
        let destination = try XCTUnwrap(inventory.destinations.first { $0.kind == .simulator && $0.udid == udid })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Appotheque-iOS-Smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let yaml = """
        name: AppothequeSmoke
        options:
          deploymentTarget:
            iOS: "18.0"
        targets:
          AppothequeSmoke:
            type: application
            platform: iOS
            sources: [Sources]
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: local.appotheque.simulator-smoke
                GENERATE_INFOPLIST_FILE: YES
                INFOPLIST_KEY_UILaunchScreen_Generation: YES
                TARGETED_DEVICE_FAMILY: "1,2"
        """
        try Data(yaml.utf8).write(to: root.appendingPathComponent("project.yml"))
        let source = root.appendingPathComponent("Sources/Smoke.swift")
        let swift = "import SwiftUI\n@main struct Smoke: App { var body: some Scene { WindowGroup { Text(\"Appothèque — validation\").padding() } } }\n"
        try Data(swift.utf8).write(to: source)
        let project = try XCTUnwrap(ProjectDiscovery.discover(in: root).first { $0.project.ios != nil }).project
        let storage = root.appendingPathComponent(".build/launcher")
        let engine = MobileEngine(storage: storage)
        let first = try await engine.launch(project, destination: destination)
        XCTAssertTrue(first.rebuilt)
        let firstReceipt = await engine.receipt(for: project, destination: destination)
        let second = try await MobileEngine(storage: storage).launch(project, destination: destination)
        XCTAssertFalse(second.rebuilt)
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(second.builtAt, firstReceipt?.builtAt)
        let ready = await engine.inspect(project, destination: destination)
        XCTAssertEqual(ready.readiness, .upToDate)
        try Data(swift.replacingOccurrences(of: "validation", with: "version suivante").utf8).write(to: source)
        let changed = await engine.inspect(project, destination: destination)
        XCTAssertEqual(changed.readiness, .changed)
        let third = try await engine.launch(project, destination: destination)
        XCTAssertTrue(third.rebuilt)
        XCTAssertNotEqual(third.url, first.url)
        let previous = try await engine.launch(project, destination: destination, previous: true)
        XCTAssertEqual(previous.url.resolvingSymlinksInPath(), first.url.resolvingSymlinksInPath())
        print("IOS_SMOKE_OK: build/install/launch, cached launch after restart, changed source rebuild, previous version launch")
        _ = try await AppleCommand.run(["simctl", "terminate", udid, "local.appotheque.simulator-smoke"])
        _ = try await AppleCommand.run(["simctl", "uninstall", udid, "local.appotheque.simulator-smoke"])
    }
}
