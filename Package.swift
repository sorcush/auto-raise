// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoRaiseLauncher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AutoRaiseLauncher",
            path: "Launcher",
            exclude: ["Tests", "Info.plist"]
        )
    ]
)
