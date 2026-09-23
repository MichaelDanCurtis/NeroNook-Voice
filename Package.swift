// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NeroVoice", platforms: [.macOS("26.0")], products: [
 .executable(name: "ModuleApp", targets: ["ModuleApp"]), .executable(name: "PluginCheck", targets: ["PluginCheck"]), .executable(name: "SpeechCheck", targets: ["SpeechCheck"])
], dependencies: [.package(path: "Vendor/NookPluginSDK")], targets: [
 .target(name: "ModuleCore", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]),
 .target(name: "VoiceAudio", dependencies: ["ModuleCore"]),
 .executableTarget(name: "ModuleApp", dependencies: ["ModuleCore", "VoiceAudio", .product(name: "NookPluginSDK", package: "NookPluginSDK")]),
 .executableTarget(name: "PluginCheck", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]),
 .executableTarget(name: "SpeechCheck", dependencies: ["VoiceAudio"]),
 .testTarget(name: "ModuleCoreTests", dependencies: ["ModuleCore"])
], swiftLanguageModes: [.v5])
