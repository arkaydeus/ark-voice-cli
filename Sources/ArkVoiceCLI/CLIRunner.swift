import ArkVoiceClient
import ArkVoiceKit
import ArkVoiceServer
import Darwin
import Dispatch
import Foundation

/// Maps parsed commands onto the kit and the server.
///
/// Everything policy-free lives in `ArkVoiceKit`; this layer decides what a
/// command-line user sees — results on stdout, diagnostics on stderr.
enum CLIRunner {
  enum PartialTranscriptDestination: Equatable {
    case none
    case standardOutput
    case standardError
  }

  static func run(_ command: Command) async throws {
    switch command {
    case .help, .version:
      // Handled before a session is built.
      break
    case .models:
      showModels()
    case .voices:
      try showVoices()
    case .createVoice(let name, let reference):
      try await createVoice(name: name, reference: reference)
    case .download(let selection):
      try await download(selection)
    case .transcribe(let options):
      try await transcribe(options)
    case .speak(let options):
      try await speak(options)
    case .serve(let options):
      try await serve(options)
    case .client(let clientCommand):
      try await runClient(clientCommand)
    }
  }

  static func makeSession(transcriptionModel: TranscriptionModel? = nil) -> VoiceSession {
    var configuration = SessionConfiguration.fromEnvironment(progress: reportProgress)
    if let transcriptionModel { configuration.transcriptionModel = transcriptionModel }
    return VoiceSession(configuration: configuration)
  }

  // MARK: - Local commands

  static func showModels() {
    writeStandardOutput("Model directory: \(ModelStore.defaultRoot.path)\n")
    for model in ModelStore.all {
      let status = ModelStore.isDownloaded(model) ? "downloaded" : "not downloaded"
      writeStandardOutput("\(model.title) [\(status)]\n")
      writeStandardOutput("  \(model.repository) — \(model.purpose)\n")
      if let recognizer = TranscriptionModel.allCases.first(where: {
        ModelStore.spec(for: $0).repository == model.repository
      }) {
        writeStandardOutput("  stt --model \(recognizer.rawValue)\n")
      }
    }
  }

  static func showVoices() throws {
    let names = try VoiceStore.names()
    if names.isEmpty {
      writeStandardOutput(
        "No saved voices. Create one with 'ark-voice voice create <name> <audio>'.\n")
    } else {
      writeStandardOutput(names.joined(separator: "\n") + "\n")
    }
  }

  static func download(_ selection: ModelSelection) async throws {
    let models = ModelStore.selected(selection)
    writeStandardError("Downloading to \(ModelStore.defaultRoot.path)\n")
    try await ModelStore.download(models, progress: reportProgress)
    writeStandardError("Download complete.\n")
  }

  static func createVoice(name: String, reference: String) async throws {
    try VoiceStore.requireAvailable(name: name)
    let samples = try readReferenceSamples(path: reference)
    let session = makeSession()
    let url = try await session.createVoice(name: name, referenceSamples: samples)
    writeStandardOutput(url.path + "\n")
  }

  static func speak(_ options: SpeakOptions) async throws {
    let text = try readText(options.text)
    let writer = try SpeechWriter(options: options)
    let voice = try voiceSelection(reference: options.reference, name: options.voice)

    let session = makeSession()
    writer.announce()
    for try await chunk in session.synthesize(text, voice: voice) {
      writer.write(chunk)
    }
    if let path = try writer.finish() {
      writeStandardOutput(path + "\n")
    }
  }

  static func transcribe(_ options: TranscribeOptions) async throws {
    let samples = try readTranscriptionSamples(options)
    let session = makeSession()

    var transcript = ""
    for try await event in session.transcribe(samples: samples, model: options.model) {
      switch event {
      case .partial(let delta):
        emitPartialTranscript(delta, options: options)
      case .final(let text):
        transcript = text
      }
    }
    if options.stream, options.output == nil { writeStandardOutput("\n") }

    try emit(transcript: transcript, options: options)
  }

  private static func emit(transcript: String, options: TranscribeOptions) throws {
    if let outputPath = options.output {
      let output = resolvedURL(outputPath)
      try VoiceEngine.createParentDirectory(for: output)
      try (transcript + "\n").write(to: output, atomically: true, encoding: .utf8)
      writeStandardError("Transcript written to \(output.path)\n")
    } else if !options.stream {
      writeStandardOutput(transcript + "\n")
    }
  }

  private static func voiceSelection(reference: String?, name: String?) throws -> VoiceSelection {
    if let name { return .named(name) }
    if let reference { return .reference(samples: try readReferenceSamples(path: reference)) }
    return .standard
  }

  // MARK: - Server

  static func serve(_ options: ServeOptions) async throws {
    var sessionConfiguration = SessionConfiguration.fromEnvironment(progress: reportProgress)
    if let root = options.modelRoot { sessionConfiguration.modelRoot = URL(fileURLWithPath: root) }
    if let model = options.transcriptionModel { sessionConfiguration.transcriptionModel = model }
    let session = VoiceSession(configuration: sessionConfiguration)
    let configuration = VoiceServer.Configuration(
      socketPath: options.socketPath ?? defaultSocketPath(modelRoot: sessionConfiguration.modelRoot),
      idleUnloadSeconds: options.idleUnloadSeconds,
      idleExitSeconds: options.idleExitSeconds,
      log: { writeStandardError($0 + "\n") }
    )
    let server = VoiceServer(session: session, configuration: configuration)
    let sources = installShutdownHandlers { server.stop() }
    defer { sources.forEach { $0.cancel() } }
    try await server.run()
  }

  /// Turns SIGINT and SIGTERM into an orderly shutdown so the socket file is
  /// removed rather than left behind for the next start to clean up.
  private static func installShutdownHandlers(
    _ handler: @escaping @Sendable () -> Void
  ) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler(handler: handler)
      source.resume()
      return source
    }
  }

  // MARK: - Client

  /// The `client` subcommand runs on `ArkVoiceClient`, the same dependency-free
  /// library an app would use, so the CLI exercises it end to end.
  static func runClient(_ command: ClientCommand) async throws {
    switch command {
    case .tts(let options, let socketPath):
      try await clientSpeak(options, socketPath: socketPath)
    case .stt(let options, let socketPath):
      try await clientTranscribe(options, socketPath: socketPath)
    case .voices(let socketPath):
      let client = try await connect(socketPath)
      defer { client.close() }
      let names = try await client.voices()
      writeStandardOutput(names.isEmpty ? "No saved voices.\n" : names.joined(separator: "\n") + "\n")
    case .status(let socketPath):
      let client = try await connect(socketPath)
      defer { client.close() }
      writeStandardOutput(renderStatus(try await client.status()))
    case .unload(let socketPath):
      let client = try await connect(socketPath)
      defer { client.close() }
      try await client.unload()
      writeStandardError("Server released its models.\n")
    }
  }

  static func renderStatus(_ status: ServerStatus) -> String {
    """
    protocol: \(status.version)
    synthesis model loaded: \(status.synthesisModelLoaded)
    transcription model loaded: \(status.transcriptionModel ?? (status.transcriptionModelLoaded ? "yes" : "none"))
    requests served: \(status.requestsServed)
    uptime: \(Int(status.uptimeSeconds))s

    """
  }

  private static func connect(_ socketPath: String?) async throws -> ArkVoiceConnection {
    try await ArkVoiceConnection.connect(socketPath: socketPath ?? defaultSocketPath())
  }

  private static func clientSpeak(_ options: SpeakOptions, socketPath: String?) async throws {
    guard options.reference == nil else {
      throw CLIParseError.message(
        "The server speaks saved voices only. Create one with 'ark-voice voice create <name> <audio>' and pass --voice."
      )
    }
    let text = try readText(options.text)
    let writer = try SpeechWriter(options: options)
    let client = try await connect(socketPath)
    defer { client.close() }

    writer.announce()
    let format = SampleFormat(wireFormat(for: options))
    for try await event in client.synthesize(text, voice: options.voice, format: format) {
      if case .audio(let chunk, _) = event {
        writer.write(chunk.samples, sampleRate: chunk.sampleRate)
      }
    }
    if let path = try writer.finish() {
      writeStandardOutput(path + "\n")
    }
  }

  /// Sample encoding for the socket.
  ///
  /// `s16le` halves the bytes for the same audible result, so it is the default
  /// unless the caller asked for float output explicitly.
  static func wireFormat(for options: SpeakOptions) -> PCMSampleFormat {
    switch options.output {
    case .standardOutput: options.sampleFormat
    case .file: .s16le
    }
  }

  private static func clientTranscribe(
    _ options: TranscribeOptions,
    socketPath: String?
  ) async throws {
    let samples = try readTranscriptionSamples(options)
    let client = try await connect(socketPath)
    defer { client.close() }

    let audio = PCMAudio(samples: samples, sampleRate: VoiceSession.transcriptionSampleRate)
    let model = options.model.map { STTModel(rawValue: $0.rawValue) }
    var transcript = ""
    for try await event in client.transcribe(audio, model: model) {
      switch event {
      case .partial(let delta): emitPartialTranscript(delta, options: options)
      case .final(let text): transcript = text
      }
    }
    if options.stream, options.output == nil { writeStandardOutput("\n") }
    try emit(transcript: transcript, options: options)
  }

  /// Keeps a requested transcript file clean while still making `--stream`
  /// observable: stdout is the transcript when there is no file, otherwise
  /// partial progress goes to stderr and the final text is written atomically.
  private static func emitPartialTranscript(_ delta: String, options: TranscribeOptions) {
    switch partialTranscriptDestination(for: options) {
    case .none:
      break
    case .standardOutput:
      writeStandardOutput(delta)
    case .standardError:
      writeStandardError(delta)
    }
  }

  static func partialTranscriptDestination(
    for options: TranscribeOptions
  ) -> PartialTranscriptDestination {
    guard options.stream else { return .none }
    return options.output == nil ? .standardOutput : .standardError
  }
}

extension SampleFormat {
  init(_ format: PCMSampleFormat) {
    switch format {
    case .f32le: self = .f32le
    case .s16le: self = .s16le
    }
  }
}
