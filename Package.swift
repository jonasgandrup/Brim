// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Brim",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Brim", targets: ["Brim"])],
    targets: [
        .executableTarget(name: "Brim", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "BrimTests", dependencies: ["Brim"])
    ]
)
