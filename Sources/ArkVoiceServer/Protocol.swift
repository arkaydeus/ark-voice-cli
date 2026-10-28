@_exported import ArkVoiceClient
import ArkVoiceKit
import Foundation

// The framing, protocol version, and operation, event, and error names live in
// ArkVoiceClient so the server and its lightweight client share one definition.
// They are re-exported so `import ArkVoiceServer` still sees them.

/// Default socket path, beside the models the daemon serves.
public func defaultSocketPath(modelRoot: URL = ModelStore.defaultRoot) -> String {
  modelRoot.appendingPathComponent("ark-voice.sock").path
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
  /// Recognizer for `stt`, as a ``TranscriptionModel`` raw value. Omit it for
  /// the server's default. A string rather than the enum so an unknown name is
  /// reported as such instead of failing the whole message.
  public var model: String?

  public init(
    op: ClientOperation,
    version: Int? = nil,
    text: String? = nil,
    voice: String? = nil,
    name: String? = nil,
    format: PCMSampleFormat? = nil,
    sampleRate: Int? = nil,
    model: String? = nil
  ) {
    self.op = op
    self.version = version
    self.text = text
    self.voice = voice
    self.name = name
    self.format = format
    self.sampleRate = sampleRate
    self.model = model
  }
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
  /// Which recognizer is resident, when one is.
  public var transcriptionModel: String?
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
