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
