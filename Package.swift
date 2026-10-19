// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "zeyt",
    platforms: [.macOS(.v14)],
    targets: [
        // Translations are copied into the app by build.sh (Bundle.main), not built as a SwiftPM resource bundle.
        .executableTarget(name: "zeyt", path: "Sources/zeyt", exclude: ["Resources"]),
        .testTarget(name: "zeytTests", dependencies: ["zeyt"], path: "Tests/zeytTests"),
    ]
)
