// swift-tools-version: 5.9
import PackageDescription

// Camera math in plain Swift and Foundation, with no camera or UI frameworks, so it builds and tests anywhere Swift runs.
let package = Package(
    name: "CameraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CameraCore", targets: ["CameraCore"]),
    ],
    targets: [
        .target(name: "CameraCore"),
        .testTarget(name: "CameraCoreTests", dependencies: ["CameraCore"]),
    ]
)
