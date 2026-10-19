// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Sense",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Sense", targets: ["Sense"])],
    targets: [
        .executableTarget(name: "Sense", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "SenseTests", dependencies: ["Sense"])
    ]
)
