// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranscriptCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "TranscriptCore", targets: ["TranscriptCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0"))
    ],
    targets: [
        .target(
            name: "TranscriptCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "TranscriptCoreTests", dependencies: ["TranscriptCore"])
    ]
)
