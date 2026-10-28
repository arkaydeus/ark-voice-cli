import Foundation

/// A request the server refused or abandoned, carrying the protocol's error code.
///
/// An error on request id 0 is connection-level: every request in flight on
/// that connection fails with it, and the connection closes.
public struct ServerError: LocalizedError, Sendable, Equatable {
  /// The mapped code. A code this client does not recognise maps to `.failed`;
  /// ``rawCode`` keeps what the server actually sent.
  public let code: ServerErrorCode
  public let rawCode: String
  public let message: String
  public let requestID: UInt32

  public init(code: ServerErrorCode, message: String, requestID: UInt32) {
    self.init(rawCode: code.rawValue, message: message, requestID: requestID)
  }

  init(rawCode: String, message: String, requestID: UInt32) {
    self.code = ServerErrorCode(rawValue: rawCode) ?? .failed
    self.rawCode = rawCode
    self.message = message
    self.requestID = requestID
  }

  public var isConnectionLevel: Bool { requestID == 0 }

  public var errorDescription: String? { "\(rawCode): \(message)" }
}

/// Failures on the client's side of the socket.
public enum ArkVoiceClientError: LocalizedError, Sendable, Equatable {
  /// Nothing is listening at the socket path.
  case notRunning(path: String)
  /// The connection closed, or was closed, before the request finished.
  case connectionClosed
  /// The server answered the handshake with a protocol version this client
  /// does not speak.
  case unsupportedVersion(Int)
  /// The server sent something that is not valid protocol.
  case protocolViolation(String)
  case socketPathTooLong(String)
  case systemCall(String, Int32)

  public var errorDescription: String? {
    switch self {
    case .notRunning(let path):
      "No ark-voice server is listening on \(path). Start one with 'ark-voice serve'."
    case .connectionClosed:
      "The connection to the ark-voice server closed."
    case .unsupportedVersion(let version):
      "The server speaks protocol version \(version); this client speaks \(arkVoiceProtocolVersion)."
    case .protocolViolation(let detail):
      "The server sent an invalid message: \(detail)"
    case .socketPathTooLong(let path):
      "Socket path is too long for a Unix domain socket: \(path)"
    case .systemCall(let name, let code):
      "\(name) failed: \(String(cString: strerror(code))) (\(code))"
    }
  }
}
