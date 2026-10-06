import Foundation

public enum ProcessRunner {
    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.cargo/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return env
    }

    public static func capture(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LauncherError.message(String(localized: "\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus))."))
        }
        return data
    }

    public static func build(_ project: Project, logURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(project.name) — \(Date().formatted())\nFolder: \(project.directoryURL.path)\n\n".utf8).write(to: logURL)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            try log.seekToEnd()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "set -e\n" + project.buildCommand]
            process.currentDirectoryURL = project.directoryURL
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            // Writing directly to disk avoids pipe deadlocks and unbounded log memory.
            process.standardOutput = log
            process.standardError = log
            try process.run()
            process.waitUntilExit()
            try log.write(contentsOf: Data("\nBuild finished: exit code \(process.terminationStatus)\n".utf8))
            guard process.terminationStatus == 0 else {
                throw LauncherError.message(String(localized: "Building \(project.name) failed (exit code \(process.terminationStatus)). Open the log to see the error."))
            }
        }.value
    }
}
