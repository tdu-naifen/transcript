// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranscriptCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "TranscriptCore", targets: ["TranscriptCore"]),
        .executable(name: "asr-bench", targets: ["ASRBenchmarkTool"]),
        .executable(name: "diarize-bench", targets: ["DiarizeBenchTool"]),
        .executable(name: "reprocess-check", targets: ["ReprocessCheckTool"]),
        .executable(name: "model-install-smoke", targets: ["ModelInstallSmokeTool"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .target(
            name: "TranscriptCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .executableTarget(
            name: "ASRBenchmarkTool",
            dependencies: ["TranscriptCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .executableTarget(
            name: "DiarizeBenchTool",
            dependencies: [
                "TranscriptCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .executableTarget(
            name: "ReprocessCheckTool",
            dependencies: ["TranscriptCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .executableTarget(
            name: "ModelInstallSmokeTool",
            dependencies: [
                "TranscriptCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .testTarget(
            name: "TranscriptCoreTests",
            dependencies: ["TranscriptCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        )
    ]
)
