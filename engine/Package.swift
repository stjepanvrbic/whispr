// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisprEngine",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.0"),
    ],
    targets: [
        .target(
            name: "WhisprLib",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/WhisprLib"
        ),
        .executableTarget(
            name: "whispr-engine",
            dependencies: ["WhisprLib"],
            path: "Sources/WhisprEngine"
        ),
        .testTarget(
            name: "WhisprTests",
            dependencies: ["WhisprLib"],
            path: "Tests/WhisprTests"
        ),
    ]
)
