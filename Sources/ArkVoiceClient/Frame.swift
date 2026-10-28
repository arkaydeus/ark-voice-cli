import Foundation

/// Wire framing for the ark-voice socket protocol.
///
/// Every message is a fixed 12-byte header followed by its payload:
///
/// ```text
/// magic   u8    always 0x41 ('A')
/// kind    u8    0 = JSON control, 1 = PCM audio
/// flags   u16   reserved, must be zero
/// request u32   little-endian request identifier
/// length  u32   little-endian payload byte count
/// ```
///
/// Control messages are JSON so they stay debuggable; audio rides in `pcm`
/// frames as raw little-endian samples. Audio is never base64-encoded inside
/// JSON — that would add a third more bytes and a parse pass per chunk to a
/// channel that carries 96 KB per second of speech.
public enum FrameKind: UInt8, Sendable, CaseIterable {
  case json = 0
  case pcm = 1
}

public struct Frame: Sendable, Equatable {
  public static let magic: UInt8 = 0x41
  public static let headerSize = 12
  /// Largest payload accepted from a peer, which bounds what a malformed or
  /// hostile length field can make the process allocate.
  public static let maximumPayloadSize = 64 * 1024 * 1024

  public let kind: FrameKind
  public let requestID: UInt32
  public let payload: Data

  public init(kind: FrameKind, requestID: UInt32, payload: Data) {
    self.kind = kind
    self.requestID = requestID
    self.payload = payload
  }

  public func encoded() -> Data {
    var data = Data(capacity: Self.headerSize + payload.count)
    data.append(Self.magic)
    data.append(kind.rawValue)
    data.append(contentsOf: [0, 0])  // flags
    data.append(littleEndian: requestID)
    data.append(littleEndian: UInt32(payload.count))
    data.append(payload)
    return data
  }
}

public enum FrameError: LocalizedError, Equatable {
  case badMagic(UInt8)
  case unknownKind(UInt8)
  case unsupportedFlags(UInt16)
  case payloadTooLarge(Int)
  case truncated
  case connectionClosed

  public var errorDescription: String? {
    switch self {
    case .badMagic(let byte):
      "Not an ark-voice frame: leading byte 0x\(String(byte, radix: 16))."
    case .unknownKind(let kind):
      "Unknown frame kind \(kind)."
    case .unsupportedFlags(let flags):
      "Unsupported frame flags 0x\(String(flags, radix: 16))."
    case .payloadTooLarge(let size):
      "Frame payload of \(size) bytes exceeds the \(Frame.maximumPayloadSize) byte limit."
    case .truncated:
      "Frame ended before its declared payload was complete."
    case .connectionClosed:
      "The peer closed the connection."
    }
  }
}

/// Header fields parsed ahead of the payload.
public struct FrameHeader: Sendable, Equatable {
  public let kind: FrameKind
  public let requestID: UInt32
  public let payloadLength: Int

  /// Parses exactly ``Frame/headerSize`` bytes.
  public init(_ bytes: Data) throws {
    guard bytes.count == Frame.headerSize else { throw FrameError.truncated }
    let raw = [UInt8](bytes)
    guard raw[0] == Frame.magic else { throw FrameError.badMagic(raw[0]) }
    guard let kind = FrameKind(rawValue: raw[1]) else { throw FrameError.unknownKind(raw[1]) }
    let flags = UInt16(raw[2]) | UInt16(raw[3]) << 8
    guard flags == 0 else { throw FrameError.unsupportedFlags(flags) }
    let requestID =
      UInt32(raw[4]) | UInt32(raw[5]) << 8 | UInt32(raw[6]) << 16 | UInt32(raw[7]) << 24
    let length =
      UInt32(raw[8]) | UInt32(raw[9]) << 8 | UInt32(raw[10]) << 16 | UInt32(raw[11]) << 24
    guard length <= UInt32(Frame.maximumPayloadSize) else {
      throw FrameError.payloadTooLarge(Int(length))
    }
    self.kind = kind
    self.requestID = requestID
    self.payloadLength = Int(length)
  }
}

extension Data {
  fileprivate mutating func append(littleEndian value: UInt32) {
    var value = value.littleEndian
    Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
  }
}
