import Foundation

/// What a streaming synthesis yields.
public enum SynthesisEvent: Sendable, Equatable {
  /// A span of speech, in order. `index` counts from zero.
  case audio(PCMAudio, index: Int)
  /// The last event: what the server sent in total.
  case done(SynthesisSummary)
}

public struct SynthesisSummary: Sendable, Equatable {
  public var chunks: Int
  public var samples: Int
  public var seconds: Double
  public var sampleRate: Int
}

/// A whole synthesized utterance.
public struct SynthesisResult: Sendable, Equatable {
  public var audio: PCMAudio
  public var summary: SynthesisSummary
}

/// What a streaming transcription yields.
public enum TranscriptionEvent: Sendable, Equatable {
  /// Text recognized since the previous event, with its own spacing:
  /// concatenating the partials reproduces the transcript.
  case partial(String)
  /// The complete transcript, trimmed.
  case final(String)
}

/// The server's `status` reply.
public struct ServerStatus: Sendable, Equatable {
  public var version: Int
  public var synthesisModelLoaded: Bool
  public var transcriptionModelLoaded: Bool
  /// Which recognizer is resident, when one is.
  public var transcriptionModel: String?
  public var requestsServed: Int
  public var uptimeSeconds: Double

  public init(
    version: Int = arkVoiceProtocolVersion,
    synthesisModelLoaded: Bool = false,
    transcriptionModelLoaded: Bool = false,
    transcriptionModel: String? = nil,
    requestsServed: Int = 0,
    uptimeSeconds: Double = 0
  ) {
    self.version = version
    self.synthesisModelLoaded = synthesisModelLoaded
    self.transcriptionModelLoaded = transcriptionModelLoaded
    self.transcriptionModel = transcriptionModel
    self.requestsServed = requestsServed
    self.uptimeSeconds = uptimeSeconds
  }
}

/// An async client for a running `ark-voice serve`.
///
/// It needs nothing but Foundation: the models stay in the daemon, so an app can
/// speak and listen without linking MLX. Requests are pipelined — every method
/// may be called concurrently on one connection, and each response is routed to
/// the call that asked for it.
///
/// ```swift
/// let voice = try await ArkVoiceConnection.connect()
/// for try await event in voice.synthesize("Hello from Swift") {
///   if case .audio(let chunk, _) = event { player.enqueue(chunk.samples) }
/// }
/// ```
///
/// Streams send their request as soon as they are created. Stopping iteration
/// early, or cancelling the task that iterates, cancels the request on the
/// server; the connection stays usable.
public final class ArkVoiceConnection: Sendable {
  /// `$ARK_VOICE_SOCKET` when set, otherwise `~/.ark-voice-cli/ark-voice.sock`.
  public static var defaultSocketPath: String {
    if let path = ProcessInfo.processInfo.environment["ARK_VOICE_SOCKET"], !path.isEmpty {
      return path
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ark-voice-cli/ark-voice.sock").path
  }

  public let socketPath: String
  /// Protocol version the server confirmed in the handshake.
  public let serverVersion: Int
  /// Sample rate of synthesized speech.
  public let sampleRate: Int
  private let transport: Transport

  private init(socketPath: String, serverVersion: Int, sampleRate: Int, transport: Transport) {
    self.socketPath = socketPath
    self.serverVersion = serverVersion
    self.sampleRate = sampleRate
    self.transport = transport
  }

  deinit {
    transport.close()
  }

  /// Connects and performs the `hello` handshake.
  public static func connect(socketPath: String? = nil) async throws -> ArkVoiceConnection {
    let path = socketPath ?? defaultSocketPath
    let transport = try Transport.connect(path: path)
    do {
      var hello = WireRequest(.hello)
      hello.version = arkVoiceProtocolVersion
      let reply = try await transport.events(hello).last
      guard let version = reply?.version, version == arkVoiceProtocolVersion else {
        throw ArkVoiceClientError.unsupportedVersion(reply?.version ?? 0)
      }
      return ArkVoiceConnection(
        socketPath: path,
        serverVersion: version,
        sampleRate: reply?.sampleRate ?? 24_000,
        transport: transport
      )
    } catch {
      transport.close()
      throw error
    }
  }

  /// Closes the connection. Requests still in flight fail with
  /// ``ArkVoiceClientError/connectionClosed``.
  public func close() {
    transport.close()
  }

  // MARK: - Synthesis

  /// Streams speech for `text` as it is generated.
  ///
  /// - Parameters:
  ///   - voice: A saved voice profile; `nil` for the built-in voice.
  ///   - format: Encoding of the returned audio. `s16le` is half the bytes.
  public func synthesize(
    _ text: String,
    voice: String? = nil,
    format: SampleFormat = .s16le
  ) -> RequestStream<SynthesisEvent> {
    var request = WireRequest(.tts)
    request.text = text
    request.voice = voice
    request.format = format
    let state = SynthesisState(sampleRate: sampleRate, format: format)
    return transport.stream(request, retaining: self) { inbound in state.event(for: inbound) }
  }

  /// Synthesizes `text` and returns the whole utterance.
  public func synthesizeAudio(
    _ text: String,
    voice: String? = nil,
    format: SampleFormat = .s16le
  ) async throws -> SynthesisResult {
    var chunks: [PCMAudio] = []
    for try await event in synthesize(text, voice: voice, format: format) {
      switch event {
      case .audio(let chunk, _):
        chunks.append(chunk)
      case .done(let summary):
        let audio = PCMAudio.joined(
          chunks, sampleRate: summary.sampleRate, format: chunks.first?.format ?? format)
        return SynthesisResult(audio: audio, summary: summary)
      }
    }
    try Task.checkCancellation()
    throw ArkVoiceClientError.connectionClosed
  }

  /// Synthesizes `text` into a WAV file.
  @discardableResult
  public func synthesize(
    _ text: String,
    toWAV url: URL,
    voice: String? = nil,
    format: SampleFormat = .s16le
  ) async throws -> SynthesisSummary {
    let result = try await synthesizeAudio(text, voice: voice, format: format)
    try result.audio.writeWAV(to: url)
    return result.summary
  }

  // MARK: - Transcription

  /// Streams the transcript of `audio` as the recognizer produces it.
  ///
  /// Audio at any sample rate is accepted; the server resamples to 16 kHz.
  /// - Parameter model: A recognizer; `nil` uses the server's default.
  public func transcribe(
    _ audio: PCMAudio,
    model: STTModel? = nil
  ) -> RequestStream<TranscriptionEvent> {
    var request = WireRequest(.stt)
    request.format = audio.format
    request.sampleRate = audio.sampleRate
    request.model = model?.rawValue
    return transport.stream(request, audio: audio, retaining: self) {
      inbound -> TranscriptionEvent? in
      guard case .event(let event) = inbound else { return nil }
      switch event.kind {
      case .partial: return .partial(event.text ?? "")
      case .final: return .final(event.text ?? "")
      default: return nil
      }
    }
  }

  /// Streams the transcript of a 16-bit PCM or 32-bit float WAV file.
  public func transcribe(
    fileAt url: URL,
    model: STTModel? = nil
  ) throws -> RequestStream<TranscriptionEvent> {
    transcribe(try PCMAudio(contentsOfWAV: url), model: model)
  }

  /// Transcribes `audio` and returns the final transcript.
  public func transcribeText(_ audio: PCMAudio, model: STTModel? = nil) async throws -> String {
    var transcript = ""
    for try await event in transcribe(audio, model: model) {
      if case .final(let text) = event { transcript = text }
    }
    try Task.checkCancellation()
    return transcript
  }

  // MARK: - Voices and housekeeping

  /// Saves a voice profile from reference speech and returns its path on the
  /// server's machine.
  @discardableResult
  public func createVoice(named name: String, from audio: PCMAudio) async throws -> String {
    var request = WireRequest(.createVoice)
    request.name = name
    request.format = audio.format
    request.sampleRate = audio.sampleRate
    let events = try await transport.events(request, audio: audio)
    return events.first { $0.kind == .voiceCreated }?.path ?? ""
  }

  /// Names of the saved voice profiles.
  public func voices() async throws -> [String] {
    try await transport.events(WireRequest(.voices)).last?.names ?? []
  }

  public func status() async throws -> ServerStatus {
    guard let reply = try await transport.events(WireRequest(.status)).last else {
      throw ArkVoiceClientError.protocolViolation("empty status reply")
    }
    return ServerStatus(
      version: reply.version ?? serverVersion,
      synthesisModelLoaded: reply.synthesisModelLoaded ?? false,
      transcriptionModelLoaded: reply.transcriptionModelLoaded ?? false,
      transcriptionModel: reply.transcriptionModel,
      requestsServed: reply.requestsServed ?? 0,
      uptimeSeconds: reply.uptimeSeconds ?? 0
    )
  }

  /// Releases the server's resident models; the next request reloads them.
  public func unload() async throws {
    _ = try await transport.events(WireRequest(.unload))
  }
}

/// Rate, format, and position of a synthesis stream. Touched only by the
/// connection's reader thread, one frame at a time.
private final class SynthesisState: @unchecked Sendable {
  private var sampleRate: Int
  private var format: SampleFormat
  private var index = 0

  init(sampleRate: Int, format: SampleFormat) {
    self.sampleRate = sampleRate
    self.format = format
  }

  func event(for inbound: Inbound) -> SynthesisEvent? {
    switch inbound {
    case .audio(let data):
      defer { index += 1 }
      return .audio(PCMAudio(data: data, sampleRate: sampleRate, format: format), index: index)
    case .event(let event):
      switch event.kind {
      case .audioFormat:
        sampleRate = event.sampleRate ?? sampleRate
        format = event.format.flatMap(SampleFormat.init(rawValue:)) ?? format
        return nil
      case .done:
        return .done(
          SynthesisSummary(
            chunks: event.chunks ?? index,
            samples: event.samples ?? 0,
            seconds: event.seconds ?? 0,
            sampleRate: sampleRate
          ))
      default:
        return nil
      }
    }
  }
}
