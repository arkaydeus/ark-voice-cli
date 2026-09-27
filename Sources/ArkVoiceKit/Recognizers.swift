import FluidAudio
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT

/// A loaded speech recognizer.
///
/// ``VoiceSession`` serializes every call through its gate, so implementations
/// need not be thread-safe.
protocol Recognizer: AnyObject {
  var model: TranscriptionModel { get }

  /// Transcribes mono samples at ``VoiceSession/transcriptionSampleRate``.
  ///
  /// `onPartial` receives text recognized since the previous call, with its
  /// own spacing, so the deltas concatenate to the transcript. Returns the
  /// complete transcript, untrimmed.
  func transcribe(_ samples: [Float], onPartial: (String) -> Void) async throws -> String
}

/// Parakeet TDT v2 on MLX, streamed in short windows.
final class ParakeetRecognizer: Recognizer {
  let model = TranscriptionModel.parakeet
  private let parakeet: ParakeetModel

  init(directory: URL) throws {
    parakeet = try ParakeetModel.fromDirectory(directory)
  }

  func transcribe(_ samples: [Float], onPartial: (String) -> Void) async throws -> String {
    let parameters = STTGenerateParameters(language: "English", chunkDuration: 5.0)
    var transcript = ""
    for try await event in parakeet.generateStream(
      audio: MLXArray(samples),
      generationParameters: parameters
    ) {
      try Task.checkCancellation()
      switch event {
      case .token(let delta):
        // Deltas keep their own spacing so that concatenating them
        // reproduces the transcript; trimming here would run words together.
        if !delta.isEmpty { onPartial(delta) }
      case .result(let output):
        transcript = output.text
      case .info:
        break
      }
    }
    return transcript
  }
}

/// Parakeet Ultra on Core ML through FluidAudio.
///
/// FluidAudio's long-form path windows and stitches the audio itself, and
/// returns the transcript only once the whole input is done, so the single
/// partial carries all of it.
final class ParakeetUltraRecognizer: Recognizer {
  let model = TranscriptionModel.parakeetUltra
  private let manager: AsrManager

  /// Loads from a verified local directory; FluidAudio never downloads here.
  ///
  /// An uncached load compiles the encoder for the Neural Engine, which takes
  /// several seconds. `ModelStore.download` does that load once, right after
  /// installing the model, so later loads are fast.
  init(directory: URL) throws {
    let models = try AsrModels.loadLocal(from: directory, version: .ultra)
    // Chunks are decoded one at a time, which keeps peak memory low.
    manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1), models: models)
  }

  func transcribe(_ samples: [Float], onPartial: (String) -> Void) async throws -> String {
    let audio = Self.paddedSamples(samples)
    var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.ultra.decoderLayers)
    let result = try await manager.transcribe(audio, decoderState: &state)
    try Task.checkCancellation()
    if !result.text.isEmpty { onPartial(result.text) }
    return result.text
  }

  static func paddedSamples(_ samples: [Float]) -> [Float] {
    var audio = samples
    let minimum = ASRConstants.minimumRequiredSamples(
      forSampleRate: VoiceSession.transcriptionSampleRate)
    if audio.count < minimum {
      audio.append(contentsOf: repeatElement(0, count: minimum - audio.count))
    }

    return audio
  }
}

/// Qwen3-ASR on MLX, streamed token by token.
final class QwenRecognizer: Recognizer {
  let model = TranscriptionModel.qwen
  private let qwen: Qwen3ASRModel
  private static let cacheGate = AsyncGate()

  /// Longest span decoded in one pass. The library splits longer audio at
  /// quiet points near this length. Longer spans raise peak memory by more
  /// than they improve accuracy.
  static let chunkSeconds: Float = 120

  /// Ceiling on MLX's pool of freed buffers while Qwen runs. Each chunk has a
  /// different length, so the pool fills with buffers that are never reused;
  /// uncapped it added about 3 GB to an 8-minute transcription.
  static let cacheLimitBytes = 256 * 1_048_576

  private init(qwen: Qwen3ASRModel) {
    self.qwen = qwen
  }

  /// Loads from `directory`, writing the `tokenizer.json` the checkpoint does
  /// not ship beside the weights on first use.
  static func load(directory: URL) async throws -> QwenRecognizer {
    QwenRecognizer(qwen: try await Qwen3ASRModel.fromModelDirectory(directory))
  }

  /// Generation budget for the whole input, not per chunk.
  ///
  /// The library's default is a flat 8,192 tokens, which would silently cut
  /// off anything much past half an hour. Speech rarely exceeds 5 tokens a
  /// second; the margin covers dense scripts.
  static func tokenBudget(seconds: Double) -> Int {
    max(1024, Int((seconds * 25).rounded(.up)))
  }

  func transcribe(_ samples: [Float], onPartial: (String) -> Void) async throws -> String {
    try await Self.withCacheLimit {
      try await transcribeWithCacheLimit(samples, onPartial: onPartial)
    }
  }

  static func withCacheLimit<T>(_ body: () async throws -> T) async rethrows -> T {
    try await withGate(cacheGate) {
      let previousCacheLimit = Memory.cacheLimit
      Memory.cacheLimit = cacheLimitBytes
      defer { Memory.cacheLimit = previousCacheLimit }
      return try await body()
    }
  }

  private func transcribeWithCacheLimit(
    _ samples: [Float], onPartial: (String) -> Void
  ) async throws -> String {
    let seconds = Double(samples.count) / Double(VoiceSession.transcriptionSampleRate)
    let parameters = STTGenerateParameters(
      maxTokens: Self.tokenBudget(seconds: seconds),
      temperature: 0,
      language: nil,
      chunkDuration: Self.chunkSeconds,
      minChunkDuration: 1.0
    )

    var transcript: String?
    for try await event in qwen.generateStream(
      audio: MLXArray(samples),
      generationParameters: parameters
    ) {
      try Task.checkCancellation()
      switch event {
      case .token(let delta):
        if !delta.isEmpty { onPartial(delta) }
      case .result(let output):
        transcript = output.text
      case .info:
        break
      }
    }
    // The library ends the stream quietly, without a result, when cancelled.
    try Task.checkCancellation()
    return try Self.requireTranscript(transcript)
  }

  static func requireTranscript(_ transcript: String?) throws -> String {
    guard let transcript else {
      throw VoiceEngineError.transcriptionFailed("Qwen3-ASR finished without a transcript.")
    }
    return transcript
  }
}
