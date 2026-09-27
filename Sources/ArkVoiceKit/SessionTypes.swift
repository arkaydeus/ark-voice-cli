import Foundation

/// Progress and diagnostic reporting from a ``VoiceSession``.
///
/// The kit never writes to standard output or standard error on its own. A host
/// decides where these land; `ark-voice` sends them to stderr so stdout stays
/// available as a data channel.
public enum ProgressEvent: Sendable {
  case message(String)
  case modelDownloadStarted(model: String)
  case modelDownloadProgress(model: String, completedBytes: Int64, totalBytes: Int64)
  case modelDownloadFinished(model: String, directory: URL)
  case modelLoadStarted(model: String)
  case modelLoadFinished(model: String)
  case modelsUnloaded
  case synthesisChunkStarted(index: Int, count: Int, characters: Int)
}

/// A speech recognizer ``VoiceSession`` can transcribe with.
///
/// Only one recognizer is resident at a time; asking for another releases the
/// current one first, so installing several never multiplies memory use.
public enum TranscriptionModel: String, Sendable, Codable, CaseIterable {
  /// Parakeet TDT 0.6B v2 on MLX. English only; streams partial text.
  case parakeet
  /// Parakeet Ultra on Core ML (Neural Engine). 25 European languages; the
  /// transcript arrives in one piece.
  case parakeetUltra = "parakeet-ultra"
  /// Qwen3-ASR 1.7B on MLX. Multilingual; streams partial text.
  case qwen

  /// Whether the recognizer runs on MLX and so needs its Metal runtime.
  public var usesMLX: Bool {
    switch self {
    case .parakeet, .qwen: true
    case .parakeetUltra: false
    }
  }

  public static var optionsDescription: String {
    allCases.map(\.rawValue).joined(separator: ", ")
  }
}

/// Everything a ``VoiceSession`` needs that it must not discover for itself.
///
/// Model location, credentials, and diagnostics are injected rather than read
/// from the process environment, so several sessions can coexist in one host.
public struct SessionConfiguration: Sendable {
  /// Directory holding downloaded models and saved voices.
  public var modelRoot: URL
  /// Hugging Face token used for downloads, when the environment requires one.
  public var hfToken: String?
  /// Explicit location of MLX's Metal shader library.
  ///
  /// When `nil`, the library is searched for beside the running executable,
  /// which is the layout `Scripts/build-release.sh` produces. Hosts that embed
  /// the kit in an app bundle should point this at their bundled copy.
  public var metallibURL: URL?
  /// Longest text chunk handed to the TTS model in one generation pass.
  public var maximumChunkCharacters: Int
  /// Silence inserted between synthesized chunks, in seconds.
  public var silenceBetweenChunks: Double
  /// Recognizer used when a transcription call does not name one.
  public var transcriptionModel: TranscriptionModel
  /// Receives progress and diagnostics. `nil` discards them.
  public var progress: (@Sendable (ProgressEvent) -> Void)?

  public init(
    modelRoot: URL = ModelStore.defaultRoot,
    hfToken: String? = nil,
    metallibURL: URL? = nil,
    maximumChunkCharacters: Int = 300,
    silenceBetweenChunks: Double = 0.15,
    transcriptionModel: TranscriptionModel = .parakeet,
    progress: (@Sendable (ProgressEvent) -> Void)? = nil
  ) {
    self.modelRoot = modelRoot
    self.hfToken = hfToken
    self.metallibURL = metallibURL
    self.maximumChunkCharacters = maximumChunkCharacters
    self.silenceBetweenChunks = silenceBetweenChunks
    self.transcriptionModel = transcriptionModel
    self.progress = progress
  }

  /// Configuration that picks up `HF_TOKEN` from the environment.
  ///
  /// Reading the environment is a host decision, so it is opt-in rather than
  /// the behaviour of ``init(modelRoot:hfToken:metallibURL:maximumChunkCharacters:silenceBetweenChunks:transcriptionModel:progress:)``.
  public static func fromEnvironment(
    progress: (@Sendable (ProgressEvent) -> Void)? = nil
  ) -> SessionConfiguration {
    SessionConfiguration(
      hfToken: ProcessInfo.processInfo.environment["HF_TOKEN"],
      progress: progress
    )
  }
}

/// A span of mono PCM produced by synthesis.
///
/// Chunks arrive in order and can be played or encoded as they land; a chunk
/// already includes any leading silence that separates it from its predecessor.
public struct AudioChunk: Sendable {
  public let samples: [Float]
  public let sampleRate: Int
  /// Zero-based position in the synthesis stream.
  public let index: Int
  public let isLast: Bool

  public init(samples: [Float], sampleRate: Int, index: Int, isLast: Bool) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.index = index
    self.isLast = isLast
  }

  public var duration: Double {
    sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
  }
}

/// Incremental transcription output.
public enum TranscriptEvent: Sendable {
  /// Text recognized since the previous event.
  case partial(String)
  /// The complete transcript, trimmed.
  case final(String)
}

/// Which voice synthesis should speak with.
public enum VoiceSelection: Sendable {
  /// Chatterbox's built-in default voice.
  case standard
  /// A profile saved by ``VoiceSession/createVoice(name:referenceSamples:)``.
  case named(String)
  /// Zero-shot cloning from reference samples at ``VoiceSession/referenceSampleRate``.
  case reference(samples: [Float])
}

/// Interleaved sample encodings understood on the wire and on stdin/stdout.
public enum PCMSampleFormat: String, Sendable, Codable, CaseIterable {
  /// 32-bit little-endian float, the model's native form.
  case f32le
  /// 16-bit little-endian signed integer: half the bytes, no audible loss.
  case s16le

  public var bytesPerSample: Int {
    switch self {
    case .f32le: 4
    case .s16le: 2
    }
  }
}
