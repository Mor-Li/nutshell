// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nutshell",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nutshell",
            path: "Sources/Nutshell",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
