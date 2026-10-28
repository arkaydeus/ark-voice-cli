import ArkVoiceClient
import ArkVoiceKit
import Foundation

/// Errors raised by ``VoiceClient`` when the server refuses or abandons a request.
public struct ServerRefusedError: LocalizedError {
  public let code: ServerErrorCode
  public let message: String

  public var errorDescription: String? { message }
}

/// A blocking client for a running `ark-voice serve`.
///
/// Requests are issued one at a time, which is what a command-line caller and a
/// test harness want. The wire protocol itself allows pipelining; a host that
/// needs it can drive ``SocketConnection`` directly.
public final class VoiceClient {
  /// Audio is sent in frames of this size so a long recording does not arrive
  /// as one enormous allocation on either side.
  private static let audioFrameBytes = 256 * 1024

  private let connection: SocketConnection
  private var nextRequestID: UInt32 = 1

  public init(socketPath: String) throws {
    connection = try connectToSocket(path: socketPath)
    var hello = ClientMessage(op: .hello)
    hello.version = arkVoiceProtocolVersion
    let requestID = takeRequestID()
    try send(hello, requestID: requestID)

    let reply = try readMessage(for: requestID)
    if reply.event == .error {
      throw ServerRefusedError(
        code: reply.code ?? .failed,
        message: reply.message ?? "The server refused the handshake."
      )
    }
  }

  public func close() {
    connection.close()
  }

  /// Result of a completed synthesis request.
  public struct SynthesisSummary: Sendable {
    public var sampleRate: Int
    public var chunks: Int
    public var samples: Int
    public var seconds: Double
  }

  /// Synthesizes `text`, handing each audio chunk to `onChunk` as it arrives.
  @discardableResult
  public func synthesize(
    text: String,
    voice: String? = nil,
    format: PCMSampleFormat = .s16le,
    onChunk: ([Float], Int) throws -> Void
  ) throws -> SynthesisSummary {
    var request = ClientMessage(op: .tts)
    request.text = text
    request.voice = voice
    request.format = format
    let requestID = takeRequestID()
    try send(request, requestID: requestID)

    var summary = SynthesisSummary(
      sampleRate: VoiceSession.synthesisSampleRate, chunks: 0, samples: 0, seconds: 0)

    while true {
      let frame = try connection.readFrame()
      if frame.requestID == 0, frame.kind == .json {
        let message = try ProtocolCoder.decodeServer(frame.payload)
        if message.event == .error { throw refusal(message) }
        continue
      }
      guard frame.requestID == requestID else { continue }
      switch frame.kind {
      case .pcm:
        try onChunk(
          try AudioDecoding.samples(from: frame.payload, format: format), summary.sampleRate)
      case .json:
        let message = try ProtocolCoder.decodeServer(frame.payload)
        switch message.event {
        case .audioFormat:
          summary.sampleRate = message.sampleRate ?? summary.sampleRate
        case .done:
          summary.chunks = message.chunks ?? 0
          summary.samples = message.samples ?? 0
          summary.seconds = message.seconds ?? 0
          return summary
        case .error:
          throw refusal(message)
        default:
          continue
        }
      }
    }
  }

  /// Transcribes `samples`, reporting incremental text through `onPartial`.
  ///
  /// `model` names the recognizer; `nil` uses the server's default.
  public func transcribe(
    samples: [Float],
    sampleRate: Int = VoiceSession.transcriptionSampleRate,
    format: PCMSampleFormat = .s16le,
    model: TranscriptionModel? = nil,
    onPartial: (String) -> Void = { _ in }
  ) throws -> String {
    var request = ClientMessage(op: .stt)
    request.format = format
    request.sampleRate = sampleRate
    request.model = model?.rawValue
    let requestID = takeRequestID()
    try send(request, requestID: requestID)
    try sendAudio(samples, format: format, requestID: requestID)
    try send(ClientMessage(op: .end), requestID: requestID)

    var transcript = ""
    while true {
      let message = try readMessage(for: requestID)
      switch message.event {
      case .partial:
        onPartial(message.text ?? "")
      case .final:
        transcript = message.text ?? ""
      case .done:
        return transcript
      case .error:
        throw refusal(message)
      default:
        continue
      }
    }
  }

  /// Creates a named voice profile from reference samples.
  public func createVoice(
    name: String,
    samples: [Float],
    sampleRate: Int = VoiceSession.synthesisSampleRate,
    format: PCMSampleFormat = .s16le
  ) throws -> String {
    var request = ClientMessage(op: .createVoice)
    request.name = name
    request.format = format
    request.sampleRate = sampleRate
    let requestID = takeRequestID()
    try send(request, requestID: requestID)
    try sendAudio(samples, format: format, requestID: requestID)
    try send(ClientMessage(op: .end), requestID: requestID)

    var path = ""
    while true {
      let message = try readMessage(for: requestID)
      switch message.event {
      case .voiceCreated:
        path = message.path ?? ""
      case .done:
        return path
      case .error:
        throw refusal(message)
      default:
        continue
      }
    }
  }

  public func voices() throws -> [String] {
    let requestID = takeRequestID()
    try send(ClientMessage(op: .voices), requestID: requestID)
    let message = try readMessage(for: requestID)
    if message.event == .error { throw refusal(message) }
    return message.names ?? []
  }

  public func status() throws -> ServerMessage {
    let requestID = takeRequestID()
    try send(ClientMessage(op: .status), requestID: requestID)
    let message = try readMessage(for: requestID)
    if message.event == .error { throw refusal(message) }
    return message
  }

  public func unload() throws {
    let requestID = takeRequestID()
    try send(ClientMessage(op: .unload), requestID: requestID)
    let message = try readMessage(for: requestID)
    if message.event == .error { throw refusal(message) }
  }

  // MARK: - Plumbing

  private func takeRequestID() -> UInt32 {
    defer { nextRequestID &+= 1 }
    return nextRequestID
  }

  private func send(_ message: ClientMessage, requestID: UInt32) throws {
    let payload = try ProtocolCoder.encode(message)
    connection.sendSynchronously(Frame(kind: .json, requestID: requestID, payload: payload))
  }

  private func sendAudio(_ samples: [Float], format: PCMSampleFormat, requestID: UInt32) throws {
    let samplesPerFrame = Self.audioFrameBytes / format.bytesPerSample
    var offset = 0
    while offset < samples.count {
      let end = min(offset + samplesPerFrame, samples.count)
      let payload = AudioDecoding.data(from: Array(samples[offset..<end]), format: format)
      connection.sendSynchronously(Frame(kind: .pcm, requestID: requestID, payload: payload))
      offset = end
    }
  }

  private func readMessage(for requestID: UInt32) throws -> ServerMessage {
    while true {
      let frame = try connection.readFrame()
      guard frame.kind == .json else { continue }
      let message = try ProtocolCoder.decodeServer(frame.payload)
      if frame.requestID == 0, message.event == .error { throw refusal(message) }
      guard frame.requestID == requestID else { continue }
      return message
    }
  }

  private func refusal(_ message: ServerMessage) -> ServerRefusedError {
    ServerRefusedError(
      code: message.code ?? .failed,
      message: message.message ?? "The server reported a failure."
    )
  }
}
