import Foundation

/// Protocol revision carried in the handshake.
///
/// A client sends `hello` first; a server that does not recognise the version
/// says so rather than guessing at the frames that follow.
public let arkVoiceProtocolVersion = 1

/// What a client is asking for.
public enum ClientOperation: String, Codable, Sendable {
  case hello
  /// Synthesize `text`; the server answers with `audio-format`, PCM frames, `done`.
  case tts
  /// Begin transcription; PCM frames follow on the same request until `end`.
  case stt
  /// Begin a voice profile; reference PCM frames follow until `end`.
  case createVoice = "create-voice"
  /// No more audio for this request.
  case end
  case voices
  case status
  /// Release resident models now.
  case unload
  /// Abandon the request this frame is addressed to.
  case cancel
}

public enum ServerEvent: String, Codable, Sendable {
  case helloOK = "hello-ok"
  /// Describes the PCM frames that follow for this request.
  case audioFormat = "audio-format"
  case partial
  case final
  case voices
  case status
  case voiceCreated = "voice-created"
  /// The request finished successfully.
  case done
  case error
}

public enum ServerErrorCode: String, Codable, Sendable {
  case badRequest = "bad-request"
  case unsupportedVersion = "unsupported-version"
  case modelsMissing = "models-missing"
  case cancelled
  case unknownRequest = "unknown-request"
  case failed
}

/// Sample encoding of PCM frames in either direction.
///
/// The same names as `ArkVoiceKit.PCMSampleFormat`, kept separate so this
/// module needs nothing from the in-process engine.
public enum SampleFormat: String, Codable, Sendable, CaseIterable {
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

/// A speech recognizer the server can transcribe with.
///
/// A string rather than a closed enum, so a client keeps working against a
/// server that has learned a recognizer this client has not heard of.
public struct STTModel: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }

  /// Parakeet TDT 0.6B v2: English, streams partial text.
  public static let parakeet = STTModel(rawValue: "parakeet")
  /// Parakeet Ultra: 25 European languages, text arrives in one piece.
  public static let parakeetUltra = STTModel(rawValue: "parakeet-ultra")
  /// Qwen3-ASR 1.7B: multilingual, streams partial text.
  public static let qwen = STTModel(rawValue: "qwen")
}

/// A control message from client to server, as it goes on the wire.
///
/// Keys are sorted and absent fields omitted, so every client binding produces
/// the same bytes for the same request (`bindings/test-vectors/protocol.json`).
struct WireRequest: Encodable, Sendable {
  var op: ClientOperation
  var version: Int?
  var text: String?
  var voice: String?
  var name: String?
  var format: SampleFormat?
  var sampleRate: Int?
  var model: String?

  init(_ op: ClientOperation) { self.op = op }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  func encoded() throws -> Data { try Self.encoder.encode(self) }
}

/// A control message from server to client.
///
/// Event names and error codes stay strings here: a newer server may send ones
/// this client does not know, and that must not fail the whole message.
struct WireEvent: Decodable, Sendable {
  var event: String
  var version: Int?
  var text: String?
  var format: String?
  var sampleRate: Int?
  var names: [String]?
  var path: String?
  var code: String?
  var message: String?
  var chunks: Int?
  var samples: Int?
  var seconds: Double?
  var synthesisModelLoaded: Bool?
  var transcriptionModelLoaded: Bool?
  var transcriptionModel: String?
  var requestsServed: Int?
  var uptimeSeconds: Double?

  static func decode(_ data: Data) throws -> WireEvent {
    try JSONDecoder().decode(WireEvent.self, from: data)
  }

  var kind: ServerEvent? { ServerEvent(rawValue: event) }
}
