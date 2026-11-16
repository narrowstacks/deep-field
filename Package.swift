// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeepField",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "DeepField",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DeepField",
            linkerSettings: [
                // the app bundle carries Sparkle.framework in Contents/Frameworks
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
