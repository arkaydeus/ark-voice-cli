import CryptoKit
import Foundation
import Testing

import ArkVoiceKit

@Suite struct ModelStoreTests {
  @Test func selectionAndCacheDirectoryMapping() {
    #expect(ModelStore.selected(.stt).map(\.repository) == [ModelStore.parakeet.repository])
    #expect(
      ModelStore.selected(.tts).map(\.repository)
        == [ModelStore.chatterbox.repository, ModelStore.s3Tokenizer.repository]
    )

    #expect(ModelStore.selected(.parakeetUltra).map(\.repository) == [ModelStore.parakeetUltra.repository])
    #expect(ModelStore.selected(.qwen).map(\.repository) == [ModelStore.qwen3ASR.repository])
    // The optional recognizers are large, so a bare download leaves them out.
    #expect(
      ModelStore.selected(.all).map(\.repository)
        == [ModelStore.parakeet, ModelStore.chatterbox, ModelStore.s3Tokenizer].map(\.repository)
    )
    for model in TranscriptionModel.allCases {
      #expect(
        ModelStore.selected(ModelSelection(model)).map(\.repository)
          == [ModelStore.spec(for: model).repository]
      )
    }

    let root = URL(fileURLWithPath: "/tmp/ark-voice-test-root", isDirectory: true)
    #expect(
      ModelStore.modelDirectory(for: ModelStore.chatterbox, root: root).path
        == "/tmp/ark-voice-test-root/mlx-audio/mlx-community_chatterbox-turbo-6bit"
    )
  }

  @Test func completeModelRequiresEveryArtifactAndMatchingMarker() throws {
    let fixture = try ModelFixture()
    defer { fixture.remove() }

    try fixture.writeValidFiles()
    #expect(!ModelStore.isDownloaded(fixture.model, root: fixture.root))

    try ModelStore.writeCompletionMarker(for: fixture.model, in: fixture.directory)
    #expect(ModelStore.isDownloaded(fixture.model, root: fixture.root))

    try FileManager.default.removeItem(
      at: fixture.directory.appendingPathComponent("model.safetensors"))
    #expect(!ModelStore.isDownloaded(fixture.model, root: fixture.root))
  }

  @Test func auxiliaryWeightsDoNotSubstituteForMainWeights() throws {
    let fixture = try ModelFixture()
    defer { fixture.remove() }

    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: fixture.directory.appendingPathComponent("config.json"))
    try Data([9, 9, 9]).write(to: fixture.directory.appendingPathComponent("conds.safetensors"))
    try ModelStore.writeCompletionMarker(for: fixture.model, in: fixture.directory)

    #expect(!ModelStore.isDownloaded(fixture.model, root: fixture.root))
    #expect(
      ModelStore.validationProblems(
        for: fixture.model,
        in: fixture.directory,
        requireMarker: true,
        verifyHashes: false
      ).contains("missing or invalid model.safetensors")
    )
  }

  @Test func zeroByteWeightsAndInvalidConfigAreRejected() throws {
    let fixture = try ModelFixture()
    defer { fixture.remove() }

    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: fixture.directory.appendingPathComponent("config.json"))
    _ = FileManager.default.createFile(
      atPath: fixture.directory.appendingPathComponent("model.safetensors").path,
      contents: Data()
    )

    let problems = ModelStore.validationProblems(
      for: fixture.model,
      in: fixture.directory,
      requireMarker: false,
      verifyHashes: false
    )
    #expect(problems.contains("missing or invalid config.json"))
    #expect(problems.contains("missing or invalid model.safetensors"))
    #expect(problems.contains("invalid config.json"))
  }

  @Test func artifactChecksumIsVerifiedAfterDownload() throws {
    let fixture = try ModelFixture(weightHash: sha256(Data([1, 2, 3])))
    defer { fixture.remove() }
    try fixture.writeValidFiles()

    #expect(
      ModelStore.validationProblems(
        for: fixture.model,
        in: fixture.directory,
        requireMarker: false,
        verifyHashes: true
      ).isEmpty
    )

    try Data([3, 2, 1]).write(to: fixture.directory.appendingPathComponent("model.safetensors"))
    #expect(
      ModelStore.validationProblems(
        for: fixture.model,
        in: fixture.directory,
        requireMarker: false,
        verifyHashes: true
      ).contains("checksum mismatch for model.safetensors")
    )
  }

  @Test func coreMLModelsDownloadOnlyTheirListedFiles() {
    let ultra = ModelStore.parakeetUltra
    #expect(ultra.downloadPatterns == ultra.artifacts.map(\.path))
    #expect(ultra.artifacts.contains { $0.path == "Encoder.mlmodelc/weights/weight.bin" })
    #expect(ModelStore.qwen3ASR.downloadPatterns == ModelSpec.defaultDownloadPatterns)
  }

  @Test func nestedArtifactsAreValidated() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-model-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ModelSpec(
      title: "Nested",
      repository: "test/nested",
      revision: "0123456789abcdef",
      purpose: "Testing",
      artifacts: [ModelArtifact(path: "Encoder.mlmodelc/weights/weight.bin", byteCount: 3, sha256: nil)]
    )
    let directory = ModelStore.modelDirectory(for: model, root: root)
    let weights = directory.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")
    try FileManager.default.createDirectory(
      at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: weights)
    try ModelStore.writeCompletionMarker(for: model, in: directory)
    #expect(ModelStore.isDownloaded(model, root: root))

    try Data([1]).write(to: weights)
    #expect(!ModelStore.isDownloaded(model, root: root))
  }

  @Test func missingModelsNameTheDownloadThatFetchesThem() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-empty-\(UUID().uuidString)", isDirectory: true)
    func message(_ models: [ModelSpec]) -> String? {
      let error = #expect(throws: ModelStoreError.self) {
        try ModelStore.requireDownloaded(models, root: root)
      }
      return error?.localizedDescription
    }
    #expect(message([ModelStore.parakeetUltra])?.contains("'ark-voice download parakeet-ultra'") == true)
    #expect(message([ModelStore.qwen3ASR])?.contains("'ark-voice download qwen'") == true)
    #expect(
      message([ModelStore.chatterbox, ModelStore.s3Tokenizer])?.contains("'ark-voice download tts'")
        == true)
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct ModelFixture {
  let root: URL
  let directory: URL
  let model: ModelSpec

  init(weightHash: String? = nil) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-model-tests-\(UUID().uuidString)", isDirectory: true)
    model = ModelSpec(
      title: "Fixture",
      repository: "test/model",
      revision: "0123456789abcdef",
      purpose: "Testing",
      artifacts: [
        ModelArtifact(path: "config.json", byteCount: 2, sha256: nil),
        ModelArtifact(path: "model.safetensors", byteCount: 3, sha256: weightHash),
      ]
    )
    directory = ModelStore.modelDirectory(for: model, root: root)
  }

  func writeValidFiles() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
    try Data([1, 2, 3]).write(to: directory.appendingPathComponent("model.safetensors"))
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
