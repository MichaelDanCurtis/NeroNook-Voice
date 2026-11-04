// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NookLocalServiceKit", platforms: [.macOS(.v14)],
    products: [.library(name: "NookLocalServiceKit", targets: ["NookLocalServiceKit"])],
    dependencies: [.package(path: "../NookPluginSDK")],
    targets: [
        .target(name: "NookLocalServiceKit", dependencies: ["NookPluginSDK"],
                linkerSettings: [.linkedFramework("Security", .when(platforms: [.macOS])), .linkedLibrary("bsm", .when(platforms: [.macOS]))]),
        .testTarget(name: "NookLocalServiceKitTests", dependencies: ["NookLocalServiceKit"])
    ])
