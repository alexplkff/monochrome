// swift-tools-version: 6.0
import PackageDescription

// Runs pure model tests on macOS when an iOS simulator is unavailable.
let package = Package(
    name: "MonoCameraCore",
    platforms: [.macOS(.v12)],
    products: [.library(name: "MonoCameraCore", targets: ["MonoCameraCore"])],
    targets: [
        .target(name: "MonoCameraCore", path: "MonoCamera",
                exclude: ["App", "Rendering", "Storage", "Views", "Info.plist", "Camera/CameraController.swift"],
                sources: ["Filters/FilterParameters.swift", "Filters/FilterEngine.swift",
                          "Presets/PresetRepository.swift", "Camera/CameraError.swift"]),
        .testTarget(name: "MonoCameraCoreTests", dependencies: ["MonoCameraCore"],
                    path: "MonoCameraTests")
    ]
)
