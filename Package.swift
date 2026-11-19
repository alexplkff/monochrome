// swift-tools-version: 6.0
import PackageDescription

// Runs pure model tests on macOS when an iOS simulator is unavailable.
let package = Package(
    name: "MonoCameraCore",
    platforms: [.macOS(.v12)],
    products: [.library(name: "MonoCameraCore", targets: ["MonoCameraCore"])],
    targets: [
        .target(name: "MonoCameraCore", path: "MonoCamera",
                exclude: ["App", "Rendering", "Storage/PhotoLibraryService.swift", "Views", "Info.plist",
                          "Assets.xcassets", "Camera/CameraController.swift"],
                sources: ["Filters/FilterParameters.swift", "Filters/FilterEngine.swift", "Filters/FilmGrainFilter.swift",
                          "Presets/PresetRepository.swift", "Camera/CameraError.swift",
                          "Storage/PhotoProcessingQueue.swift"]),
        .testTarget(name: "MonoCameraCoreTests", dependencies: ["MonoCameraCore"],
                    path: "MonoCameraTests")
    ]
)
