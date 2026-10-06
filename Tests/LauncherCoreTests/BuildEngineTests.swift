import Foundation
import XCTest
@testable import LauncherCore

final class BuildEngineTests: XCTestCase {
    private var root: URL!
    private var storage: URL!
    private var project: Project!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Appotheque Tests \(UUID().uuidString)")
        storage = root.appendingPathComponent(".build/launcher")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("alpha", to: "source.txt")
        try write("""
        #!/bin/sh
        set -eu
        mkdir -p .build
        if [ -f .build/fail ]; then echo 'Compilation volontairement échouée' >&2; exit 7; fi
        echo build >> .build/count
        mkdir -p 'dist/Sample App.app/Contents/MacOS' 'dist/Sample App.app/Contents/Resources'
        printf '#!/bin/sh\\nexit 0\\n' > 'dist/Sample App.app/Contents/MacOS/Sample'
        chmod +x 'dist/Sample App.app/Contents/MacOS/Sample'
        cp source.txt 'dist/Sample App.app/Contents/Resources/compiled.txt'
        cat > 'dist/Sample App.app/Contents/Info.plist' <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>Sample</string>
        <key>CFBundleIdentifier</key><string>local.appotheque.test</string></dict></plist>
        PLIST
        if [ -f .build/change-during-build ]; then echo changed >> source.txt; fi
        """, to: "build.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("build.sh").path)
        project = Project(name: "Sample App", directory: root.path, buildCommand: "./build.sh", appPath: "dist/Sample App.app")
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testFirstBuildThenNoBuildEvenAfterRestart() async throws {
        let first = try await BuildEngine(storage: storage).prepare(project)
        XCTAssertTrue(first.rebuilt)
        XCTAssertEqual(try count(), 1)
        let second = try await BuildEngine(storage: storage).prepare(project)
        XCTAssertFalse(second.rebuilt)
        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(try count(), 1, "Unchanged sources must never execute the build command.")
    }

    func testChangedContentWithSameSizeAndTimestampRebuilds() async throws {
        let engine = BuildEngine(storage: storage)
        let first = try await engine.prepare(project)
        let source = root.appendingPathComponent("source.txt")
        let modified = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate]!
        try write("bravo", to: "source.txt")
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        let second = try await engine.prepare(project)
        XCTAssertTrue(second.rebuilt)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(try String(contentsOf: second.url.appendingPathComponent("Contents/Resources/compiled.txt")), "bravo")
        XCTAssertEqual(try count(), 2)
    }

    func testUntrackedAdditionDeletionAndLockfileChangesRebuild() async throws {
        _ = try ProcessRunner.capture("/usr/bin/git", ["init", "-q"], in: root)
        try write(".build/\ndist/\n.env\n", to: ".gitignore")
        _ = try ProcessRunner.capture("/usr/bin/git", ["add", "source.txt", "build.sh", ".gitignore"], in: root)
        let engine = BuildEngine(storage: storage)
        _ = try await engine.prepare(project)
        try write("new code", to: "new.swift")
        let addition = try await engine.prepare(project)
        XCTAssertTrue(addition.rebuilt)
        try FileManager.default.removeItem(at: root.appendingPathComponent("new.swift"))
        let deletion = try await engine.prepare(project)
        XCTAssertTrue(deletion.rebuilt)
        try write("dependency-v2", to: "Package.resolved")
        let lock = try await engine.prepare(project)
        XCTAssertTrue(lock.rebuilt)
        try write("LOCAL_SETTING=yes", to: ".env")
        let environment = try await engine.prepare(project)
        XCTAssertTrue(environment.rebuilt, "Ignored local environment files affect builds too.")
        XCTAssertEqual(try count(), 5)
    }

    func testIgnoredBuildOutputDoesNotRebuild() async throws {
        let engine = BuildEngine(storage: storage)
        _ = try await engine.prepare(project)
        try write("transient output", to: ".build/noise")
        try write("transient output", to: "dist/other")
        try write("installed dependency", to: "node_modules/package/file.js")
        let second = try await engine.prepare(project)
        XCTAssertFalse(second.rebuilt)
        XCTAssertEqual(try count(), 1)
    }

    func testForceAndRecipeChangesRebuild() async throws {
        let engine = BuildEngine(storage: storage)
        _ = try await engine.prepare(project)
        let forced = try await engine.prepare(project, force: true)
        XCTAssertTrue(forced.rebuilt)
        project.buildCommand += "\n# New build configuration"
        let changed = try await engine.prepare(project)
        XCTAssertTrue(changed.rebuilt)
        XCTAssertEqual(try count(), 3)
    }

    func testMissingManagedBinaryRebuilds() async throws {
        let engine = BuildEngine(storage: storage)
        let first = try await engine.prepare(project)
        try FileManager.default.removeItem(at: first.url.appendingPathComponent("Contents/MacOS/Sample"))
        let second = try await engine.prepare(project)
        XCTAssertTrue(second.rebuilt)
        XCTAssertEqual(try count(), 2)
    }

    func testFailedForcedBuildDoesNotReuseReceiptOrLoseLastGoodApp() async throws {
        let engine = BuildEngine(storage: storage)
        let first = try await engine.prepare(project)
        try write("fail", to: ".build/fail")
        do { _ = try await engine.prepare(project, force: true); XCTFail("Build must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("code 7")) }
        let receipt = await engine.receipt(for: project.id)
        XCTAssertNil(receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(try String(contentsOf: engine.logURL(for: project.id)).contains("volontairement"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".build/fail"))
        let retry = try await engine.prepare(project)
        XCTAssertTrue(retry.rebuilt)
        XCTAssertEqual(try count(), 2)
    }

    func testSourceChangeDuringBuildIsNotCached() async throws {
        try write("change", to: ".build/change-during-build")
        let engine = BuildEngine(storage: storage)
        do { _ = try await engine.prepare(project); XCTFail("Changed sources cannot be marked current") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed during the build")) }
        let receipt = await engine.receipt(for: project.id)
        XCTAssertNil(receipt)
    }

    func testMissingBundleIsNotSuccessful() async throws {
        project.buildCommand = "true"
        let engine = BuildEngine(storage: storage)
        do { _ = try await engine.prepare(project); XCTFail("No app was produced") }
        catch { XCTAssertTrue(error.localizedDescription.contains("missing or incomplete")) }
        let receipt = await engine.receipt(for: project.id)
        XCTAssertNil(receipt)
    }

    func testExtraLocalDependencyIsWatched() async throws {
        let external = root.appendingPathComponent(".build/local-package.swift")
        try write("version one", to: ".build/local-package.swift")
        project.extraWatchPaths = [external.path]
        let engine = BuildEngine(storage: storage)
        _ = try await engine.prepare(project)
        try write("version two", to: ".build/local-package.swift")
        let updated = try await engine.prepare(project)
        XCTAssertTrue(updated.rebuilt)
        XCTAssertEqual(try count(), 2)
    }

    func testConfigurationRoundTripAndDuplicateIDsRejected() throws {
        let url = root.appendingPathComponent(".build/projects.json")
        try ProjectStore.save([project], to: url)
        XCTAssertEqual(try ProjectStore.load(from: url), [project])
        try ProjectStore.save([project, project], to: url)
        XCTAssertThrowsError(try ProjectStore.load(from: url))
    }

    func testInspectionDetectsChangesWithoutExecutingBuild() async throws {
        let engine = BuildEngine(storage: storage)
        let initial = await engine.inspect(project)
        XCTAssertEqual(initial.readiness, .firstBuild)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/count").path))
        _ = try await engine.prepare(project)
        let current = await engine.inspect(project)
        XCTAssertEqual(current.readiness, .upToDate)
        try write("new version", to: "source.txt")
        let changed = await engine.inspect(project)
        XCTAssertEqual(changed.readiness, .changed)
        XCTAssertEqual(try count(), 1)
    }

    func testPreviousBuildSurvivesRestartAndDoesNotReplaceCurrentReceipt() async throws {
        let engine = BuildEngine(storage: storage)
        let first = try await engine.prepare(project)
        try write("second version", to: "source.txt")
        let second = try await engine.prepare(project)
        let restarted = BuildEngine(storage: storage)
        let previous = try await restarted.previousApp(for: project.id)
        XCTAssertEqual(previous.url.resolvingSymlinksInPath(), first.url.resolvingSymlinksInPath())
        XCTAssertFalse(previous.rebuilt)
        XCTAssertEqual(try String(contentsOf: previous.url.appendingPathComponent("Contents/Resources/compiled.txt")), "alpha")
        let current = try await restarted.prepare(project)
        XCTAssertEqual(current.url, second.url)
        XCTAssertFalse(current.rebuilt)
        XCTAssertEqual(try count(), 2)
        try write("third version", to: "source.txt")
        _ = try await restarted.prepare(project)
        await restarted.pruneOldBuilds(for: project.id, protecting: [first.url.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path), "Do not remove a running previous version.")
        await restarted.pruneOldBuilds(for: project.id, protecting: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        let latestPrevious = try await restarted.previousApp(for: project.id)
        XCTAssertEqual(latestPrevious.url.resolvingSymlinksInPath(), second.url.resolvingSymlinksInPath())
    }

    func testPersistedFailureOffersLastSuccessAndClearsAfterRecovery() async throws {
        let engine = BuildEngine(storage: storage)
        let first = try await engine.prepare(project)
        try write("fail", to: ".build/fail")
        do { _ = try await engine.prepare(project, force: true); XCTFail("Expected a build failure") } catch {}
        let restarted = BuildEngine(storage: storage)
        let inspection = await restarted.inspect(project)
        guard case .failed(let message) = inspection.readiness else { return XCTFail("Failure must survive restart") }
        XCTAssertTrue(message.contains("code 7"))
        let previous = try await restarted.previousApp(for: project.id)
        XCTAssertEqual(previous.url.resolvingSymlinksInPath(), first.url.resolvingSymlinksInPath())
        XCTAssertEqual(try count(), 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".build/fail"))
        _ = try await restarted.prepare(project)
        let recovered = await restarted.inspect(project)
        XCTAssertEqual(recovered.readiness, .upToDate)
    }

    func testMissingGenerationRebuildsAndDamagedPreviousIsRejected() async throws {
        let engine = BuildEngine(storage: storage)
        let first = try await engine.prepare(project)
        try FileManager.default.removeItem(at: first.url.deletingLastPathComponent())
        let second = try await engine.prepare(project)
        XCTAssertTrue(second.rebuilt)
        _ = try await engine.prepare(project, force: true)
        try Data("altered build".utf8).write(to: second.url.appendingPathComponent("Contents/Resources/compiled.txt"))
        do { _ = try await engine.previousApp(for: project.id); XCTFail("Damaged previous build cannot launch") }
        catch { XCTAssertTrue(error.localizedDescription.contains("modified")) }
    }

    func testInspectionListsFilesChangedSinceTheBuild() async throws {
        let engine = BuildEngine(storage: storage)
        _ = try await engine.prepare(project)
        let clean = await engine.inspect(project)
        XCTAssertEqual(clean.readiness, .upToDate)
        XCTAssertNil(clean.changes)
        XCTAssertEqual(clean.inputDigest, clean.receipt?.inputDigest)

        try write("bravo", to: "source.txt")
        try write("new", to: "Sources/New.swift")
        try FileManager.default.removeItem(at: root.appendingPathComponent("build.sh"))
        let changed = await engine.inspect(project)
        XCTAssertEqual(changed.readiness, .changed)
        XCTAssertEqual(changed.changes?.modified, ["source.txt"])
        XCTAssertEqual(changed.changes?.added, ["Sources/New.swift"])
        XCTAssertEqual(changed.changes?.removed, ["build.sh"])
        XCTAssertEqual(changed.changes?.settingsChanged, false)
        XCTAssertEqual(changed.changes?.appChanged, false)
        XCTAssertNotEqual(changed.inputDigest, changed.receipt?.inputDigest)
    }

    func testRecipeChangeIsReportedWithoutFiles() async throws {
        let engine = BuildEngine(storage: storage)
        _ = try await engine.prepare(project)
        project.exclusions = ["docs"]
        let changed = await engine.inspect(project)
        XCTAssertEqual(changed.readiness, .changed)
        XCTAssertEqual(changed.changes?.settingsChanged, true)
        XCTAssertEqual(changed.changes?.fileCount, 0)
    }

    func testReceiptWithoutFileDigestsStillMatchesAndSaysDetailsAreUnavailable() async throws {
        let engine = BuildEngine(storage: storage)
        _ = try await engine.prepare(project)
        // Rewrite the receipt as an older Appothèque would have: no per-file digests.
        let url = storage.appendingPathComponent("Receipts/\(project.id.uuidString).json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["files"] = nil; json["settingsDigest"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let clean = await engine.inspect(project)
        XCTAssertEqual(clean.readiness, .upToDate, "The whole digest must not change with per-file digests.")
        try write("bravo", to: "source.txt")
        let changed = await engine.inspect(project)
        XCTAssertEqual(changed.changes?.detailsAvailable, false)
        XCTAssertEqual(changed.changes?.fileCount, 0)
    }

    func testFingerprintGlyphIsStableAndKeepsItsCentre() {
        let digest = String(repeating: "a5", count: 32)
        XCTAssertEqual(FingerprintGlyph.cells(for: digest), FingerprintGlyph.cells(for: digest))
        XCTAssertEqual(FingerprintGlyph.cells(for: digest).count, 9)
        XCTAssertTrue(FingerprintGlyph.cells(for: digest)[4])
        XCTAssertTrue(FingerprintGlyph.cells(for: "")[4])
        XCTAssertNotEqual(FingerprintGlyph.cells(for: "00"), FingerprintGlyph.cells(for: "ff"))
        // 0xa5 = 10100101: bits 0, 2, 5 and 7 lit, around the centre.
        XCTAssertEqual(FingerprintGlyph.cells(for: digest), [true, false, true, false, true, false, true, false, true])
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func count() throws -> Int {
        try String(contentsOf: root.appendingPathComponent(".build/count")).split(separator: "\n").count
    }
}
