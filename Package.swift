// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeepField",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DeepField",
            path: "Sources/DeepField"
        )
    ],
    swiftLanguageVersions: [.v5]
)
