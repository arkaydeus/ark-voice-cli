// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ark-voice-cli",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "ark-voice", targets: ["ArkVoiceCLI"]),
    .library(name: "ArkVoiceKit", targets: ["ArkVoiceKit"]),
    .library(name: "ArkVoiceServer", targets: ["ArkVoiceServer"]),
    .library(name: "ArkVoiceClient", targets: ["ArkVoiceClient"]),
  ],
  dependencies: [
    .package(path: "Vendor/mlx-audio-swift"),
    // Parakeet Ultra runs on Core ML through FluidAudio. The NeMo text
    // normalisation binary is opted out: transcripts keep the recogniser's text.
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      exact: "0.17.3",
      traits: []
    ),
    .package(
      url: "https://github.com/huggingface/swift-huggingface.git",
      exact: "0.8.1"
    ),
    .package(
      url: "https://github.com/ml-explore/mlx-swift.git",
      exact: "0.31.6"
    ),
    .package(
      url: "https://github.com/swiftlang/swift-testing.git",
      exact: "6.2.4"
    ),
  ],
  targets: [
    .target(
      name: "ArkVoiceKit",
      dependencies: [
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "MLXAudioCodecs", package: "mlx-audio-swift"),
        .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
        .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "FluidAudio", package: "FluidAudio"),
      ]
    ),
    .target(
      name: "ArkVoiceServer",
      dependencies: ["ArkVoiceKit", "ArkVoiceClient"]
    ),
    // Talks to a running `ark-voice serve`; deliberately free of ML dependencies.
    .target(name: "ArkVoiceClient"),
    .executableTarget(
      name: "ArkVoiceCLI",
      dependencies: ["ArkVoiceKit", "ArkVoiceServer", "ArkVoiceClient"]
    ),
    .testTarget(
      name: "ArkVoiceKitTests",
      dependencies: [
        "ArkVoiceKit",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
        .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
        .product(name: "Testing", package: "swift-testing"),
      ]
    ),
    .testTarget(
      name: "ArkVoiceServerTests",
      dependencies: [
        "ArkVoiceServer",
        "ArkVoiceKit",
        .product(name: "Testing", package: "swift-testing"),
      ]
    ),
    .testTarget(
      name: "ArkVoiceClientTests",
      dependencies: [
        "ArkVoiceClient",
        .product(name: "Testing", package: "swift-testing"),
      ]
    ),
    .testTarget(
      name: "ArkVoiceCLITests",
      dependencies: [
        "ArkVoiceCLI",
        "ArkVoiceServer",
        "ArkVoiceClient",
        .product(name: "Testing", package: "swift-testing"),
      ]
    ),
  ]
)
