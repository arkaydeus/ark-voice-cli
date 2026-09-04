// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ark-voice-cli",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "ark-voice", targets: ["ArkVoiceCLI"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/Blaizzy/mlx-audio-swift.git",
      revision: "bf14ae0c26e4e85553dd989571cae29d70fa6735"
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
    .executableTarget(
      name: "ArkVoiceCLI",
      dependencies: [
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "MLXAudioCodecs", package: "mlx-audio-swift"),
        .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
        .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "MLX", package: "mlx-swift"),
      ]
    ),
    .testTarget(
      name: "ArkVoiceCLITests",
      dependencies: [
        "ArkVoiceCLI",
        .product(name: "Testing", package: "swift-testing"),
      ]
    ),
  ]
)
