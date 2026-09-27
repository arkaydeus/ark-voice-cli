import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS

/// Local speech synthesis and recognition with resident models.
///
/// A session loads each model the first time it is needed and keeps it in
/// memory, so repeated calls cost only inference. That is the difference that
/// matters for a host making many calls: process-per-call reloads roughly a
/// gigabyte of weights every time.
///
/// Instances are safe to share across tasks. Model work is serialized — one
/// generation runs at a time — because the models cannot run concurrently.
///
/// Speech recognition uses one resident recognizer at a time. Each call may
/// name a ``TranscriptionModel``; a successful load replaces the resident one.
///
/// The class is `@unchecked Sendable` because it stores models that are not
/// `Sendable`. Every access to them happens inside the gate, and the stored
/// references themselves are guarded by `stateLock`.
public final class VoiceSession: @unchecked Sendable {
  /// Sample rate for reference audio and synthesized output.
  public static let synthesisSampleRate = AudioDecoding.synthesisSampleRate
  /// Sample rate transcription input must be supplied at.
  public static let transcriptionSampleRate = AudioDecoding.transcriptionSampleRate

  public let configuration: SessionConfiguration

  private let gate = AsyncGate()
  private let stateLock = NSLock()
  private var chatterbox: ChatterboxModel?
  private var builtInConditioning: DefaultConditioning?
  private var recognizer: (any Recognizer)?
  private let recognizerFactory: ((TranscriptionModel, URL) async throws -> any Recognizer)?
  private let clearMLXCache: () -> Void
  private var conditioningCache: [String: DefaultConditioning] = [:]

  public init(configuration: SessionConfiguration = SessionConfiguration()) {
    self.configuration = configuration
    self.recognizerFactory = nil
    self.clearMLXCache = { MLX.Memory.clearCache() }
  }

  init(
    configuration: SessionConfiguration,
    recognizerFactory: @escaping (TranscriptionModel, URL) async throws -> any Recognizer,
    clearMLXCache: @escaping () -> Void = { MLX.Memory.clearCache() }
  ) {
    self.configuration = configuration
    self.recognizerFactory = recognizerFactory
    self.clearMLXCache = clearMLXCache
  }

  /// Directory holding saved voice profiles for this session.
  public var voicesDirectory: URL {
    VoiceStore.root(modelRoot: configuration.modelRoot)
  }

  public var isSynthesisModelLoaded: Bool {
    stateLock.withLock { chatterbox != nil }
  }

  public var isTranscriptionModelLoaded: Bool {
    stateLock.withLock { recognizer != nil }
  }

  /// The resident recognizer, if one is loaded.
  public var loadedTranscriptionModel: TranscriptionModel? {
    stateLock.withLock { recognizer?.model }
  }

  // MARK: - Synthesis

  /// Synthesizes `text`, yielding audio as each chunk finishes.
  ///
  /// Long input is split at sentence and word boundaries; a chunk is emitted as
  /// soon as it is generated, so playback can start after the first one instead
  /// of after the whole document. Chunks after the first carry leading silence
  /// so that concatenating them reproduces the joined output exactly.
  public func synthesize(
    _ text: String,
    voice: VoiceSelection = .standard
  ) -> AsyncThrowingStream<AudioChunk, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await self.runSynthesis(text: text, voice: voice) { chunk in
            continuation.yield(chunk)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Synthesizes `text` and returns the complete waveform.
  ///
  /// A fold over ``synthesize(_:voice:)`` so file output and streaming output
  /// cannot drift apart.
  public func synthesizeAll(
    _ text: String,
    voice: VoiceSelection = .standard
  ) async throws -> (samples: [Float], sampleRate: Int) {
    var samples = [Float]()
    var sampleRate = Self.synthesisSampleRate
    for try await chunk in synthesize(text, voice: voice) {
      samples.append(contentsOf: chunk.samples)
      sampleRate = chunk.sampleRate
    }
    guard !samples.isEmpty else {
      throw VoiceEngineError.audioEncodingFailed("No audio samples were generated.")
    }
    return (samples, sampleRate)
  }

  private func runSynthesis(
    text: String,
    voice: VoiceSelection,
    yield: @Sendable (AudioChunk) -> Void
  ) async throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VoiceEngineError.emptyText }
    guard configuration.maximumChunkCharacters > 0 else {
      throw VoiceEngineError.invalidConfiguration("maximumChunkCharacters must be positive.")
    }
    guard configuration.silenceBetweenChunks.isFinite,
      configuration.silenceBetweenChunks >= 0,
      configuration.silenceBetweenChunks
        <= Double(Int.max) / Double(Self.synthesisSampleRate)
    else {
      throw VoiceEngineError.invalidConfiguration(
        "silenceBetweenChunks must be finite, non-negative, and representable as samples.")
    }
    try requireRuntime()

    let chunks = VoiceEngine.chunkText(
      trimmed,
      maximumCharacters: configuration.maximumChunkCharacters
    )
    guard !chunks.isEmpty else { throw VoiceEngineError.emptyText }

    try await withGate(gate) {
      let model = try await loadSynthesisModel()
      try applyConditioning(voice, to: model)

      let sampleRate = model.sampleRate
      let silenceSampleCount = Int(
        Double(sampleRate) * max(0, configuration.silenceBetweenChunks)
      )

      for (index, chunk) in chunks.enumerated() {
        try Task.checkCancellation()
        configuration.progress?(
          .synthesisChunkStarted(index: index, count: chunks.count, characters: chunk.count)
        )

        let generated = try await model.generate(
          text: chunk,
          voice: nil,
          refAudio: nil,
          refText: nil,
          language: "English",
          generationParameters: model.defaultGenerationParameters
        )

        var samples = [Float]()
        if index > 0 {
          samples.append(contentsOf: repeatElement(0, count: silenceSampleCount))
        }
        samples.append(contentsOf: generated.asArray(Float.self))

        yield(
          AudioChunk(
            samples: samples,
            sampleRate: sampleRate,
            index: index,
            isLast: index == chunks.count - 1
          )
        )
      }
    }
  }

  // MARK: - Transcription

  /// Transcribes mono samples supplied at ``transcriptionSampleRate``.
  ///
  /// Partial events arrive as the recognizer works through the audio; the
  /// `final` event carries the complete transcript. Parakeet Ultra produces its
  /// text only once the whole input is done, so it sends a single partial.
  ///
  /// `model` defaults to the configuration's ``SessionConfiguration/transcriptionModel``.
  public func transcribe(
    samples: [Float],
    model: TranscriptionModel? = nil
  ) -> AsyncThrowingStream<TranscriptEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await self.runTranscription(samples: samples, model: model) { event in
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Decodes an audio file and transcribes it.
  public func transcribeFile(
    at url: URL,
    model: TranscriptionModel? = nil
  ) -> AsyncThrowingStream<TranscriptEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let samples = try AudioDecoding.decodeFile(
            at: url,
            sampleRate: Self.transcriptionSampleRate
          )
          try await self.runTranscription(samples: samples, model: model) { event in
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Transcribes and returns only the finished text.
  public func transcribeAll(
    samples: [Float],
    model: TranscriptionModel? = nil
  ) async throws -> String {
    var transcript = ""
    for try await event in transcribe(samples: samples, model: model) {
      if case .final(let text) = event { transcript = text }
    }
    return transcript
  }

  private func runTranscription(
    samples: [Float],
    model requested: TranscriptionModel?,
    yield: @Sendable (TranscriptEvent) -> Void
  ) async throws {
    guard !samples.isEmpty else {
      yield(.final(""))
      return
    }
    let model = requested ?? configuration.transcriptionModel
    if model.usesMLX { try requireRuntime() }

    try await withGate(gate) {
      let recognizer = try await loadRecognizer(model)
      let transcript = try await recognizer.transcribe(samples) { delta in
        yield(.partial(delta))
      }
      yield(.final(transcript.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
  }

  // MARK: - Voices

  /// Derives a reusable voice profile from reference audio at
  /// ``synthesisSampleRate`` and saves it under the session's model root.
  @discardableResult
  public func createVoice(name: String, referenceSamples: [Float]) async throws -> URL {
    let voicesRoot = voicesDirectory
    try VoiceStore.requireAvailable(name: name, root: voicesRoot)
    try requireRuntime()
    guard !referenceSamples.isEmpty else {
      throw VoiceEngineError.audioDecodingFailed("Reference audio contains no samples.")
    }

    return try await withGate(gate) {
      let model = try await loadSynthesisModel()
      let conditioning = try model.prepareConditioning(refAudio: MLXArray(referenceSamples))
      let url = try VoiceStore.save(conditioning, name: name, root: voicesRoot)
      stateLock.withLock { conditioningCache[name] = conditioning }
      return url
    }
  }

  public func voiceNames() throws -> [String] {
    try VoiceStore.names(root: voicesDirectory)
  }

  // MARK: - Model lifecycle

  /// Loads the synthesis model without generating anything.
  public func preloadSynthesisModel() async throws {
    try requireRuntime()
    try await withGate(gate) { _ = try await loadSynthesisModel() }
  }

  /// Loads a recognizer without transcribing anything.
  public func preloadTranscriptionModel(_ requested: TranscriptionModel? = nil) async throws {
    let model = requested ?? configuration.transcriptionModel
    if model.usesMLX { try requireRuntime() }
    try await withGate(gate) { _ = try await loadRecognizer(model) }
  }

  /// Releases resident models and cached conditioning.
  ///
  /// Waits for current model work to finish, then releases resident models and
  /// cached conditioning. New work starts only after the unload has completed.
  ///
  /// `condition` is evaluated after acquiring the model gate. Servers use it
  /// to abandon an idle unload if activity resumed while the unload was queued.
  @discardableResult
  public func unloadModels(
    if condition: @escaping @Sendable () -> Bool = { true }
  ) async -> Bool {
    await withGate(gate) {
      guard condition() else { return false }
      let hadMLXModel = stateLock.withLock { () -> Bool in
        let wasLoaded = chatterbox != nil || recognizer?.model.usesMLX == true
        chatterbox = nil
        builtInConditioning = nil
        recognizer = nil
        conditioningCache.removeAll()
        return wasLoaded
      }
      // Touching MLX's allocator initializes the Metal runtime, so leave it
      // alone when no MLX model was loaded — an idle server needs no GPU.
      if hadMLXModel { MLX.Memory.clearCache() }
      configuration.progress?(.modelsUnloaded)
      return true
    }
  }

  private func requireRuntime() throws {
    try VoiceEngine.requireMLXRuntime(explicitURL: configuration.metallibURL)
  }

  private func loadSynthesisModel() async throws -> ChatterboxModel {
    if let cached = stateLock.withLock({ chatterbox }) { return cached }

    try ModelStore.requireDownloaded(
      [ModelStore.chatterbox, ModelStore.s3Tokenizer],
      root: configuration.modelRoot
    )
    configuration.progress?(.modelLoadStarted(model: ModelStore.chatterbox.title))

    let model = try await ChatterboxModel.fromModelDirectory(
      ModelStore.modelDirectory(for: ModelStore.chatterbox, root: configuration.modelRoot),
      hfToken: configuration.hfToken
    )
    model.s3Tokenizer = try VoiceEngine.loadS3Tokenizer(
      from: ModelStore.modelDirectory(for: ModelStore.s3Tokenizer, root: configuration.modelRoot)
    )

    stateLock.withLock {
      chatterbox = model
      builtInConditioning = model.defaultConditioning
    }
    configuration.progress?(.modelLoadFinished(model: ModelStore.chatterbox.title))
    return model
  }

  /// Returns the resident recognizer for `model`, loading it if needed.
  ///
  /// The previous recognizer stays available if construction of its replacement fails.
  func loadRecognizer(_ model: TranscriptionModel) async throws -> any Recognizer {
    if let cached = stateLock.withLock({ recognizer }), cached.model == model { return cached }

    let spec = ModelStore.spec(for: model)
    try ModelStore.requireDownloaded([spec], root: configuration.modelRoot)

    configuration.progress?(.modelLoadStarted(model: spec.title))
    let directory = ModelStore.modelDirectory(for: spec, root: configuration.modelRoot)
    let loaded: any Recognizer
    if let recognizerFactory {
      loaded = try await recognizerFactory(model, directory)
    } else {
      loaded = try await Self.makeRecognizer(model, directory: directory)
    }

    var previous = stateLock.withLock { () -> (any Recognizer)? in
      let previous = recognizer
      recognizer = loaded
      return previous
    }
    let releasedMLXModel = previous?.model.usesMLX == true
    // Release the old weights before clearing buffers they left in MLX's cache.
    previous = nil
    if releasedMLXModel { clearMLXCache() }
    configuration.progress?(.modelLoadFinished(model: spec.title))
    return loaded
  }

  private static func makeRecognizer(
    _ model: TranscriptionModel, directory: URL
  ) async throws -> any Recognizer {
    switch model {
    case .parakeet: try ParakeetRecognizer(directory: directory)
    case .parakeetUltra: try ParakeetUltraRecognizer(directory: directory)
    case .qwen: try await QwenRecognizer.load(directory: directory)
    }
  }

  /// Points the model at the requested voice.
  ///
  /// A resident model outlives one request, so `.standard` must restore the
  /// weights' own conditioning rather than leave whichever clone ran last in
  /// place.
  private func applyConditioning(_ voice: VoiceSelection, to model: ChatterboxModel) throws {
    switch voice {
    case .standard:
      model.defaultConditioning = stateLock.withLock { builtInConditioning }
    case .named(let name):
      if let cached = stateLock.withLock({ conditioningCache[name] }) {
        model.defaultConditioning = cached
        return
      }
      let loaded = try VoiceStore.load(name: name, root: voicesDirectory)
      stateLock.withLock { conditioningCache[name] = loaded }
      model.defaultConditioning = loaded
    case .reference(let samples):
      guard !samples.isEmpty else {
        throw VoiceEngineError.audioDecodingFailed("Reference audio contains no samples.")
      }
      model.defaultConditioning = try model.prepareConditioning(refAudio: MLXArray(samples))
    }
  }
}
