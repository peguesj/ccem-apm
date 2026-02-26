// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "APMv4App",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "APMv4App",
            path: "Sources/APMv4App",
            resources: [
                .copy("../../Resources/Assets.xcassets")
            ]
        )
    ]
)
