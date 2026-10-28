import Foundation
import MLX
import MLXAudioSTT
import Testing

@testable import ArkVoiceKit

@Suite(.serialized) struct RecognizerTests {
  @Test func qwenUnicodeDeltasAndChunkSpacing() {
    let expected = "你好世界"
    let bytes = Array(expected.utf8)
    var stream = QwenStreamText()
    var partials: [String] = []
    for count in 1...bytes.count {
      let decoded = String(decoding: bytes.prefix(count), as: UTF8.self)
      let delta = stream.append(decoded)
      if !delta.isEmpty { partials.append(delta) }
    }
    let final = String(decoding: bytes, as: UTF8.self)
    partials.append(stream.finish(final))
    #expect(partials.joined() == final)
    #expect(!partials.joined().contains("\u{FFFD}"))
    var combining = QwenStreamText()
    let first = combining.append("e")
    let accent = combining.append("e\u{0301}")
    #expect(first + accent == "e\u{0301}")

    #expect(QwenStreamText.separator(previous: "end.", next: "Next", language: "English") == " ")
    #expect(QwenStreamText.separator(previous: "你好", next: "世界", language: "Chinese") == "")
    #expect(QwenStreamText.separator(previous: "end ", next: "Next", language: "English") == "")
  }

  @Test func qwenBudgetMissingResultAndUltraPadding() throws {
    #expect(QwenRecognizer.tokenBudget(seconds: 0) == 1024)
    #expect(QwenRecognizer.tokenBudget(seconds: 40) == 1024)
    #expect(QwenRecognizer.tokenBudget(seconds: 120) == 3000)
    #expect(QwenRecognizer.tokenBudget(seconds: 1800) == 45_000)
    #expect(try QwenRecognizer.requireTranscript("hello") == "hello")
    #expect(throws: VoiceEngineError.self) { try QwenRecognizer.requireTranscript(nil) }

    let short: [Float] = [0.25, -0.5]
    let padded = ParakeetUltraRecognizer.paddedSamples(short)
    #expect(padded.count > short.count)
    #expect(Array(padded.prefix(2)) == short)
    #expect(padded.dropFirst(2).allSatisfy { $0 == 0 })
    #expect(ParakeetUltraRecognizer.paddedSamples(padded) == padded)
  }

  @Test func recognizerSwapKeepsResidentOnFailedLoad() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-recognizer-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try installPlaceholder(ModelStore.parakeet, root: root)
    try installPlaceholder(ModelStore.parakeetUltra, root: root)

    let parakeet = StubRecognizer(model: .parakeet)
    let ultra = StubRecognizer(model: .parakeetUltra)
    var clearCount = 0
    let session = VoiceSession(
      configuration: SessionConfiguration(modelRoot: root),
      recognizerFactory: { model, _ in
        switch model {
        case .parakeet: return parakeet
        case .parakeetUltra: return ultra
        case .qwen: throw VoiceEngineError.transcriptionFailed("Injected load failure")
        }
      },
      clearMLXCache: { clearCount += 1 }
    )

    let first = try await session.loadRecognizer(.parakeet)
    #expect(first === parakeet)
    #expect(try await session.loadRecognizer(.parakeet) === parakeet)
    #expect(session.loadedTranscriptionModel == .parakeet)
    #expect(session.isTranscriptionModelLoaded)
    #expect(clearCount == 0)

    await #expect(throws: ModelStoreError.self) { try await session.loadRecognizer(.qwen) }
    #expect(session.loadedTranscriptionModel == .parakeet)
    #expect(clearCount == 0)
    try installPlaceholder(ModelStore.qwen3ASR, root: root)
    await #expect(throws: VoiceEngineError.self) { try await session.loadRecognizer(.qwen) }
    #expect(session.loadedTranscriptionModel == .parakeet)
    #expect(clearCount == 0)

    #expect(try await session.loadRecognizer(.parakeetUltra) === ultra)
    #expect(session.loadedTranscriptionModel == .parakeetUltra)
    #expect(clearCount == 1)
    #expect(try await session.loadRecognizer(.parakeet) === parakeet)
    #expect(clearCount == 1)
    #expect(TranscriptionModel.parakeetUltra.usesMLX == false)
    #expect(TranscriptionModel.qwen.usesMLX)
  }

  // Reading MLX's cache limit initializes the Metal device, which aborts the
  // whole test process when mlx.metallib is not packaged beside it.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ARK_VOICE_TEST_MLX"] == "1",
      "Set ARK_VOICE_TEST_MLX=1 and package mlx.metallib to test MLX cache limits."
    ))
  func qwenCacheLimitIsRestoredAcrossSessions() async throws {
    let original = Memory.cacheLimit
    let entered = AsyncStream.makeStream(of: Void.self)
    let release = AsyncStream.makeStream(of: Void.self)
    let first = Task {
      await QwenRecognizer.withCacheLimit {
        entered.continuation.yield(())
        for await _ in release.stream { break }
      }
    }
    for await _ in entered.stream { break }
    #expect(Memory.cacheLimit == QwenRecognizer.cacheLimitBytes)
    let second = Task {
      await QwenRecognizer.withCacheLimit {
        #expect(Memory.cacheLimit == QwenRecognizer.cacheLimitBytes)
      }
    }
    release.continuation.yield(())
    await first.value
    await second.value
    #expect(Memory.cacheLimit == original)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["ARK_VOICE_TEST_MODELS"] == "1"))
  func ultraLoadsAndTranscribesWithResidentStatus() async throws {
    let audio = try integrationAudio()
    let session = VoiceSession()
    try await session.preloadTranscriptionModel(.parakeetUltra)
    #expect(session.loadedTranscriptionModel == .parakeetUltra)
    let transcript = try await session.transcribeAll(samples: audio, model: .parakeetUltra)
    #expect(!transcript.isEmpty)
    #expect(session.loadedTranscriptionModel == .parakeetUltra)

    let events = DownloadEventsForRecognizer()
    try await ModelStore.download([ModelStore.parakeetUltra]) { event in events.record(event) }
    #expect(events.finished == 1)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["ARK_VOICE_TEST_MODELS"] == "1"))
  func qwenLoadsAndStreamsTheFinalTranscript() async throws {
    let audio = try integrationAudio()
    _ = try await assertQwenStream(audio)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_QWEN_NONLATIN_AUDIO"] != nil))
  func qwenNonLatinPartialsEqualFinalTranscript() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_QWEN_NONLATIN_AUDIO"])
    let audio = try AudioDecoding.decodeFile(at: URL(fileURLWithPath: path), sampleRate: VoiceSession.transcriptionSampleRate)
    let final = try await assertQwenStream(audio)
    #expect(final.unicodeScalars.contains { $0.value > 127 })
    #expect(!final.contains("\u{FFFD}"))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["ARK_VOICE_TEST_LONG_QWEN"] == "1"))
  func qwenLongAudioKeepsChunkBoundariesReadable() async throws {
    let clip = try integrationAudio()
    let repeated = Array(repeating: clip, count: 7).flatMap { $0 }
    let final = try await assertQwenStream(repeated)
    #expect(final.contains("out. Hey"))
  }

  private func assertQwenStream(_ audio: [Float]) async throws -> String {
    let metallib = ProcessInfo.processInfo.environment["ARK_VOICE_TEST_METALLIB"]
      ?? ".build/debug/mlx.metallib"
    let session = VoiceSession(configuration: SessionConfiguration(
      metallibURL: URL(fileURLWithPath: metallib)))
    try await session.preloadTranscriptionModel(.qwen)
    #expect(session.loadedTranscriptionModel == .qwen)
    var partials = ""
    var final = ""
    for try await event in session.transcribe(samples: audio, model: .qwen) {
      switch event {
      case .partial(let delta): partials += delta
      case .final(let text): final = text
      }
    }
    #expect(!final.isEmpty)
    #expect(partials == final)
    return final
  }

  private func integrationAudio() throws -> [Float] {
    let path = try #require(ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_STT_AUDIO"])
    return try AudioDecoding.decodeFile(at: URL(fileURLWithPath: path), sampleRate: VoiceSession.transcriptionSampleRate)
  }

  private func installPlaceholder(_ model: ModelSpec, root: URL) throws {
    let directory = ModelStore.modelDirectory(for: model, root: root)
    for artifact in model.artifacts {
      let file = directory.appendingPathComponent(artifact.path)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      if artifact.path == "config.json" {
        try Data(("{}" + String(repeating: " ", count: artifact.byteCount - 2)).utf8).write(to: file)
      } else {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(artifact.byteCount))
        try handle.close()
      }
    }
    try ModelStore.writeCompletionMarker(for: model, in: directory)
  }
}

private final class DownloadEventsForRecognizer: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func record(_ event: ProgressEvent) {
    if case .modelDownloadFinished = event { lock.withLock { count += 1 } }
  }
  var finished: Int { lock.withLock { count } }
}

private final class StubRecognizer: Recognizer {
  let model: TranscriptionModel
  init(model: TranscriptionModel) { self.model = model }
  func transcribe(_ samples: [Float], onPartial: (String) -> Void) async throws -> String {
    "stub"
  }
}
