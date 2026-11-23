// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LoopNest",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CRing", path: "Sources/CRing"),
        .executableTarget(
            name: "LoopNest",
            dependencies: ["CRing"],
            path: "Sources/LoopNest",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
