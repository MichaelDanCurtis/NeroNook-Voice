// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "NeroDiarization", platforms: [.macOS(.v14)], products: [
    .executable(name: "NeroDiarization", targets: ["NeroDiarization"]),
    .executable(name: "NeroParakeet", targets: ["NeroParakeet"]),
    .executable(name: "NeroNemotron", targets: ["NeroNemotron"])
], dependencies: [
    .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb")
], targets: [
    .executableTarget(name: "NeroDiarization", dependencies: [.product(name: "MLXAudioVAD", package: "mlx-audio-swift"), .product(name: "MLXAudioCore", package: "mlx-audio-swift")]),
    .executableTarget(name: "NeroParakeet", dependencies: [.product(name: "MLXAudioSTT", package: "mlx-audio-swift"), .product(name: "MLXAudioCore", package: "mlx-audio-swift")])
, .executableTarget(name: "NeroNemotron", dependencies: [.product(name: "MLXAudioSTT", package: "mlx-audio-swift"), .product(name:"MLXAudioTTS",package:"mlx-audio-swift"), .product(name:"MLXAudioCore",package:"mlx-audio-swift")])

], swiftLanguageModes: [.v5])
