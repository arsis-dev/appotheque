// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Appotheque",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Appotheque", targets: ["Appotheque"])],
    targets: [
        .target(name: "LauncherCore"),
        .executableTarget(name: "Appotheque", dependencies: ["LauncherCore"]),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore"])
    ]
)
