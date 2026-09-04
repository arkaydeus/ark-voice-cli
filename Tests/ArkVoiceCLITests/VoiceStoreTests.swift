import Foundation
import MLX
import MLXAudioTTS
import Testing

@testable import ArkVoiceCLI

@Suite struct VoiceStoreTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ARK_VOICE_TEST_MLX"] == "1",
      "Set ARK_VOICE_TEST_MLX=1 and package mlx.metallib to test safetensors I/O."
    )
  )
  func profileRoundTripsAndListsByName() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = conditioning()

    let saved = try VoiceStore.save(
      original,
      name: "narrator-1",
      root: directory,
      stream: .cpu
    )
    #expect(saved.lastPathComponent == "narrator-1.safetensors")
    #expect(try VoiceStore.names(root: directory) == ["narrator-1"])

    let loaded = try VoiceStore.load(name: "narrator-1", root: directory, stream: .cpu)
    #expect(loaded.speakerEmb.shape == [1, 256])
    #expect(loaded.condPromptSpeechTokens.asArray(Int32.self) == [1, 1])
    #expect(loaded.xVector.shape == [1, 192])
    #expect(loaded.promptToken.asArray(Int32.self) == [1, 1])
    #expect(loaded.promptFeat.shape == [1, 4, 80])
  }

  @Test func profileNamesAreRestricted() throws {
    for name in ["", "-bad", "../bad", "two words", "é"] {
      #expect(throws: VoiceStoreError.self) {
        try VoiceStore.validateName(name)
      }
    }
    try VoiceStore.validateName("Voice_01")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ARK_VOICE_TEST_MLX"] == "1",
      "Set ARK_VOICE_TEST_MLX=1 and package mlx.metallib to test safetensors I/O."
    )
  )
  func profilesCannotBeOverwritten() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try VoiceStore.save(conditioning(), name: "saved", root: directory, stream: .cpu)
    #expect(throws: VoiceStoreError.self) {
      try VoiceStore.save(conditioning(), name: "saved", root: directory, stream: .cpu)
    }
  }

  @Test func missingProfilesAreRejected() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: VoiceStoreError.self) {
      try VoiceStore.load(name: "missing", root: directory)
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ARK_VOICE_TEST_MLX"] == "1",
      "Set ARK_VOICE_TEST_MLX=1 and package mlx.metallib to test safetensors I/O."
    )
  )
  func incompatibleProfilesAreRejected() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let incompatible = directory.appendingPathComponent("old.safetensors")
    try MLX.save(
      arrays: ["value": MLXArray.zeros([1], stream: .cpu)],
      metadata: ["ark_voice_schema": "0"],
      url: incompatible,
      stream: .cpu
    )
    #expect(throws: VoiceStoreError.self) {
      try VoiceStore.load(name: "old", root: directory, stream: .cpu)
    }
  }

  private func conditioning() -> DefaultConditioning {
    DefaultConditioning(
      speakerEmb: MLXArray.zeros([1, 256], stream: .cpu),
      condPromptSpeechTokens: MLXArray.ones([1, 2], type: Int32.self, stream: .cpu),
      emotionAdv: MLXArray.zeros([1, 1, 1], stream: .cpu),
      xVector: MLXArray.zeros([1, 192], stream: .cpu),
      promptToken: MLXArray.ones([1, 2], type: Int32.self, stream: .cpu),
      promptTokenLen: MLXArray.ones([1], type: Int32.self, stream: .cpu),
      promptFeat: MLXArray.zeros([1, 4, 80], stream: .cpu),
      promptFeatLen: MLXArray.ones([1], type: Int32.self, stream: .cpu)
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-store-tests-\(UUID().uuidString)", isDirectory: true)
  }
}
