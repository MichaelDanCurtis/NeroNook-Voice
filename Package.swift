// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NeroVoice", platforms: [.macOS("26.0")], products: [
 .executable(name: "ModuleApp", targets: ["ModuleApp"]), .executable(name: "InterpreterPreview", targets: ["InterpreterPreview"]), .executable(name: "PluginCheck", targets: ["PluginCheck"]), .executable(name: "SpeechCheck", targets: ["SpeechCheck"]), .executable(name: "SelectionReview", targets: ["SelectionReview"]), .executable(name: "MeetingQualityCheck", targets: ["MeetingQualityCheck"])
], dependencies: [.package(path: "Vendor/NookPluginSDK")], targets: [
 .executableTarget(name: "InterpreterPreview", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]),
 .target(name: "ModuleCore", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]),
 .target(name: "VoiceAudio", dependencies: ["ModuleCore"]),
 .target(name: "VoiceEditing", dependencies: ["ModuleCore", .product(name: "NookPluginSDK", package: "NookPluginSDK")]),
 .executableTarget(name: "SelectionReview", dependencies: ["VoiceEditing", "VoiceAudio", "ModuleCore"]),
 .executableTarget(name: "MeetingQualityCheck", dependencies: ["VoiceAudio", "ModuleCore", .product(name: "NookPluginSDK", package: "NookPluginSDK")]),
 .executableTarget(name: "ModuleApp", dependencies: ["ModuleCore", "VoiceAudio", "VoiceEditing", .product(name: "NookPluginSDK", package: "NookPluginSDK")]),
 .executableTarget(name: "PluginCheck", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]),
 .executableTarget(name: "SpeechCheck", dependencies: ["VoiceAudio"]),
 .testTarget(name: "ModuleCoreTests", dependencies: ["ModuleCore"]),
 .testTarget(name: "MeetingAudioTests", dependencies: ["ModuleCore", "VoiceAudio"]),
 .testTarget(name: "VoiceEditingTests", dependencies: ["VoiceEditing", "ModuleCore"])
], swiftLanguageModes: [.v5])
