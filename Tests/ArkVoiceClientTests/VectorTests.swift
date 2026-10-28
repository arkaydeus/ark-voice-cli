import Foundation
import Testing

@testable import ArkVoiceClient

/// Checks the Swift client against the byte vectors every binding shares, so
/// the Swift, TypeScript, and Python clients cannot drift apart on the wire.
@Suite struct VectorTests {
  nonisolated(unsafe) static let vectors: [String: Any] = {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("bindings/test-vectors/protocol.json")
    let data = try! Data(contentsOf: url)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  }()

  static func list(_ key: String) -> [[String: Any]] { vectors[key] as! [[String: Any]] }

  @Test func protocolConstantsMatch() {
    #expect(Self.vectors["protocolVersion"] as? Int == arkVoiceProtocolVersion)
    #expect(Self.vectors["headerSize"] as? Int == Frame.headerSize)
    #expect(Self.vectors["maximumPayloadSize"] as? Int == Frame.maximumPayloadSize)
  }

  @Test func requestsEncodeToTheSharedBytes() throws {
    for vector in Self.list("requests") {
      let name = vector["name"] as! String
      let message = vector["message"] as! [String: Any]
      var request = WireRequest(ClientOperation(rawValue: message["op"] as! String)!)
      request.version = message["version"] as? Int
      request.text = message["text"] as? String
      request.voice = message["voice"] as? String
      request.name = message["name"] as? String
      request.format = (message["format"] as? String).flatMap(SampleFormat.init(rawValue:))
      request.sampleRate = message["sampleRate"] as? Int
      request.model = message["model"] as? String

      let payload = try request.encoded()
      #expect(String(decoding: payload, as: UTF8.self) == vector["payload"] as? String, "\(name)")

      let requestID = UInt32(vector["requestId"] as! Int)
      let frame = Frame(kind: .json, requestID: requestID, payload: payload)
      #expect(frame.encoded().hex == vector["frame"] as? String, "\(name)")
    }
  }

  @Test func eventsDecodeFromTheSharedBytes() throws {
    for vector in Self.list("events") {
      let name = vector["name"] as! String
      let bytes = Data(hex: vector["frame"] as! String)
      let header = try FrameHeader(bytes.prefix(Frame.headerSize))
      #expect(header.kind == .json, "\(name)")
      #expect(header.requestID == UInt32(vector["requestId"] as! Int), "\(name)")
      let payload = bytes.dropFirst(Frame.headerSize)
      #expect(header.payloadLength == payload.count, "\(name)")

      let event = try WireEvent.decode(Data(payload))
      let expected = vector["message"] as! [String: Any]
      #expect(event.event == expected["event"] as? String, "\(name)")
      #expect(event.kind != nil, "\(name)")
      #expect(event.version == expected["version"] as? Int, "\(name)")
      #expect(event.sampleRate == expected["sampleRate"] as? Int, "\(name)")
      #expect(event.text == expected["text"] as? String, "\(name)")
      #expect(event.format == expected["format"] as? String, "\(name)")
      #expect(event.names == expected["names"] as? [String], "\(name)")
      #expect(event.path == expected["path"] as? String, "\(name)")
      #expect(event.code == expected["code"] as? String, "\(name)")
      #expect(event.message == expected["message"] as? String, "\(name)")
      #expect(event.chunks == expected["chunks"] as? Int, "\(name)")
      #expect(event.samples == expected["samples"] as? Int, "\(name)")
      #expect(event.seconds == expected["seconds"] as? Double, "\(name)")
      #expect(event.synthesisModelLoaded == expected["synthesisModelLoaded"] as? Bool, "\(name)")
      #expect(event.transcriptionModel == expected["transcriptionModel"] as? String, "\(name)")
      #expect(event.requestsServed == expected["requestsServed"] as? Int, "\(name)")
      #expect(event.uptimeSeconds == expected["uptimeSeconds"] as? Double, "\(name)")
    }
  }

  @Test func pcmFramesRoundTrip() throws {
    for vector in Self.list("pcmFrames") {
      let payload = Data(hex: vector["payload"] as! String)
      let requestID = UInt32(vector["requestId"] as! Int)
      let encoded = Frame(kind: .pcm, requestID: requestID, payload: payload).encoded()
      #expect(encoded.hex == vector["frame"] as? String)

      let header = try FrameHeader(encoded.prefix(Frame.headerSize))
      #expect(header.kind == .pcm)
      #expect(header.requestID == requestID)
      #expect(header.payloadLength == payload.count)
    }
  }

  @Test func invalidHeadersAreRejectedForTheSharedReasons() {
    for vector in Self.list("invalidHeaders") {
      let reason: String
      do {
        _ = try FrameHeader(Data(hex: vector["header"] as! String))
        reason = "accepted"
      } catch FrameError.badMagic {
        reason = "bad-magic"
      } catch FrameError.unknownKind {
        reason = "unknown-kind"
      } catch FrameError.unsupportedFlags {
        reason = "unsupported-flags"
      } catch FrameError.payloadTooLarge {
        reason = "payload-too-large"
      } catch {
        reason = "\(error)"
      }
      #expect(reason == vector["error"] as? String, "\(vector["name"]!)")
    }
  }

  @Test func validHeadersParse() throws {
    for vector in Self.list("validHeaders") {
      let header = try FrameHeader(Data(hex: vector["header"] as! String))
      #expect(header.kind.rawValue == UInt8(vector["kind"] as! Int))
      #expect(header.requestID == UInt32(vector["requestId"] as! Int))
      #expect(header.payloadLength == vector["payloadLength"] as! Int)
    }
  }

  @Test func sampleConversionMatchesTheServer() {
    let samples = Self.vectors["samples"] as! [String: Any]

    let s16Encode = samples["s16leEncode"] as! [String: Any]
    let floats = (s16Encode["floats"] as! [Double]).map(Float.init)
    #expect(PCMAudio.encode(floats, format: .s16le).hex == s16Encode["hex"] as? String)

    let s16Decode = samples["s16leDecode"] as! [String: Any]
    #expect(
      PCMAudio.decode(Data(hex: s16Decode["hex"] as! String), format: .s16le)
        == (s16Decode["floats"] as! [Double]).map(Float.init))

    let f32 = samples["f32le"] as! [String: Any]
    let f32Floats = (f32["floats"] as! [Double]).map(Float.init)
    #expect(PCMAudio.encode(f32Floats, format: .f32le).hex == f32["hex"] as? String)
    #expect(PCMAudio.decode(Data(hex: f32["hex"] as! String), format: .f32le) == f32Floats)
  }
}

extension Data {
  init(hex: String) {
    var bytes = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    self.init(bytes)
  }

  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
