// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalSpeak",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalSpeak", targets: ["LocalSpeak"])],
    targets: [
        .target(name: "CMicTransport"),
        .executableTarget(name: "LocalSpeak", dependencies: ["CMicTransport"]),
        .testTarget(name: "LocalSpeakTests", dependencies: ["LocalSpeak"])
    ],
    swiftLanguageModes: [.v5]
)

