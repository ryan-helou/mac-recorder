// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacRecorder",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "MacRecorder", path: "Sources/MacRecorder")
    ]
)
