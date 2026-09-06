import ArkVoiceKit
import Foundation

/// Protocol revision carried in the handshake.
///
/// A client sends `hello` first; a server that does not recognise the version
/// says so rather than guessing at the frames that follow.
public let arkVoiceProtocolVersion = 1

/// Default socket path, beside the models the daemon serves.
public func defaultSocketPath(modelRoot: URL = ModelStore.defaultRoot) -> String {
  modelRoot.appendingPathComponent("ark-voice.sock").path
}

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

/// A control message from client to server.
///
/// One permissive struct rather than a discriminated union so that clients in
/// other languages can build requests as plain dictionaries.
public struct ClientMessage: Codable, Sendable {
  public var op: ClientOperation
  public var version: Int?
  public var text: String?
  /// Name of a saved voice profile, for `tts`; or the new profile's name, for
  /// `create-voice`.
  public var voice: String?
  public var name: String?
  /// Sample encoding of PCM frames in either direction. Defaults to `s16le`,
  /// which halves the bytes of speech audio with no audible loss.
  public var format: PCMSampleFormat?
  /// Sample rate of the PCM frames the client is about to send.
  public var sampleRate: Int?

  public init(
    op: ClientOperation,
    version: Int? = nil,
    text: String? = nil,
    voice: String? = nil,
    name: String? = nil,
    format: PCMSampleFormat? = nil,
    sampleRate: Int? = nil
  ) {
    self.op = op
    self.version = version
    self.text = text
    self.voice = voice
    self.name = name
    self.format = format
    self.sampleRate = sampleRate
  }
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

/// A control message from server to client.
public struct ServerMessage: Codable, Sendable {
  public var event: ServerEvent
  public var version: Int?
  public var text: String?
  public var format: PCMSampleFormat?
  public var sampleRate: Int?
  public var names: [String]?
  public var path: String?
  public var code: ServerErrorCode?
  public var message: String?
  /// Chunks of audio sent for a finished `tts` request.
  public var chunks: Int?
  /// Sample frames sent for a finished `tts` request.
  public var samples: Int?
  public var seconds: Double?
  public var synthesisModelLoaded: Bool?
  public var transcriptionModelLoaded: Bool?
  public var requestsServed: Int?
  public var uptimeSeconds: Double?

  public init(event: ServerEvent) {
    self.event = event
  }
}

enum ProtocolCoder {
  static let encoder = JSONEncoder()
  static let decoder = JSONDecoder()

  static func encode(_ message: ServerMessage) -> Data {
    (try? encoder.encode(message)) ?? Data(#"{"event":"error","code":"failed"}"#.utf8)
  }

  static func encode(_ message: ClientMessage) throws -> Data {
    try encoder.encode(message)
  }

  static func decodeClient(_ data: Data) throws -> ClientMessage {
    try decoder.decode(ClientMessage.self, from: data)
  }

  static func decodeServer(_ data: Data) throws -> ServerMessage {
    try decoder.decode(ServerMessage.self, from: data)
  }
}
