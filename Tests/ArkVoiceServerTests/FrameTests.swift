import Darwin
import Foundation
import Testing

import ArkVoiceKit

@testable import ArkVoiceServer

@Suite struct FrameTests {
  @Test func framesRoundTripThroughTheirEncoding() throws {
    let payload = Data("hello".utf8)
    let frame = Frame(kind: .json, requestID: 7, payload: payload)
    let encoded = frame.encoded()

    #expect(encoded.count == Frame.headerSize + payload.count)
    let header = try FrameHeader(encoded.prefix(Frame.headerSize))
    #expect(header.kind == .json)
    #expect(header.requestID == 7)
    #expect(header.payloadLength == payload.count)
    #expect(encoded.suffix(payload.count) == payload)
  }

  @Test func requestIdentifiersUseTheFullUnsignedRange() throws {
    let header = try FrameHeader(
      Frame(kind: .pcm, requestID: .max, payload: Data()).encoded()
    )
    #expect(header.requestID == .max)
    #expect(header.payloadLength == 0)
  }

  @Test func malformedHeadersAreRejectedRatherThanMisread() {
    var wrongMagic = [UInt8](Frame(kind: .json, requestID: 1, payload: Data()).encoded())
    wrongMagic[0] = 0x42
    #expect(throws: FrameError.badMagic(0x42)) { try FrameHeader(Data(wrongMagic)) }

    var wrongKind = [UInt8](Frame(kind: .json, requestID: 1, payload: Data()).encoded())
    wrongKind[1] = 9
    #expect(throws: FrameError.unknownKind(9)) { try FrameHeader(Data(wrongKind)) }

    var lowFlag = [UInt8](Frame(kind: .json, requestID: 1, payload: Data()).encoded())
    lowFlag[2] = 1
    #expect(throws: FrameError.unsupportedFlags(1)) { try FrameHeader(Data(lowFlag)) }

    var highFlag = [UInt8](Frame(kind: .json, requestID: 1, payload: Data()).encoded())
    highFlag[3] = 2
    #expect(throws: FrameError.unsupportedFlags(0x200)) { try FrameHeader(Data(highFlag)) }

    #expect(throws: FrameError.truncated) { try FrameHeader(Data([Frame.magic, 0, 0])) }
  }

  @Test func oversizedPayloadsAreRefusedBeforeAllocating() {
    var header = [UInt8](Frame(kind: .pcm, requestID: 1, payload: Data()).encoded())
    let huge = UInt32(Frame.maximumPayloadSize) + 1
    header[8] = UInt8(huge & 0xff)
    header[9] = UInt8((huge >> 8) & 0xff)
    header[10] = UInt8((huge >> 16) & 0xff)
    header[11] = UInt8((huge >> 24) & 0xff)

    #expect(throws: FrameError.payloadTooLarge(Int(huge))) { try FrameHeader(Data(header)) }
  }

  @Test func controlMessagesSurviveJSONEncoding() throws {
    var request = ClientMessage(op: .tts)
    request.text = "hello"
    request.voice = "narrator"
    request.format = .s16le

    let decoded = try ProtocolCoder.decodeClient(try ProtocolCoder.encode(request))
    #expect(decoded.op == .tts)
    #expect(decoded.text == "hello")
    #expect(decoded.voice == "narrator")
    #expect(decoded.format == .s16le)

    var reply = ServerMessage(event: .done)
    reply.chunks = 3
    reply.samples = 48_000
    let decodedReply = try ProtocolCoder.decodeServer(ProtocolCoder.encode(reply))
    #expect(decodedReply.event == .done)
    #expect(decodedReply.chunks == 3)
    #expect(decodedReply.samples == 48_000)
  }

  @Test func operationNamesAreStableOnTheWire() throws {
    #expect(ClientOperation.createVoice.rawValue == "create-voice")
    #expect(ServerEvent.helloOK.rawValue == "hello-ok")
    #expect(ServerEvent.audioFormat.rawValue == "audio-format")
    #expect(ServerErrorCode.modelsMissing.rawValue == "models-missing")

    // A client in another language builds requests as plain dictionaries.
    let raw = Data(#"{"op":"create-voice","name":"narrator","format":"s16le"}"#.utf8)
    let decoded = try ProtocolCoder.decodeClient(raw)
    #expect(decoded.op == .createVoice)
    #expect(decoded.name == "narrator")
    #expect(decoded.format == .s16le)
  }

  @Test func socketReadsReassembleFragmentedFrames() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    let connection = SocketConnection(descriptor: descriptors[0], label: "ark-voice.fragment-test")
    defer {
      connection.close()
      Darwin.close(descriptors[1])
    }

    let expected = Frame(kind: .json, requestID: 42, payload: Data("fragmented".utf8))
    let bytes = [UInt8](expected.encoded())
    let writerDescriptor = descriptors[1]
    let writer = Thread {
      for byte in bytes {
        var byte = byte
        _ = Darwin.write(writerDescriptor, &byte, 1)
      }
    }
    writer.start()

    #expect(try connection.readFrame() == expected)
  }

  @Test func closingWhileWritesAreQueuedCompletesWithoutDescriptorRaces() {
    for iteration in 0..<50 {
      var descriptors = [Int32](repeating: -1, count: 2)
      #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
      let connection = SocketConnection(
        descriptor: descriptors[0], label: "ark-voice.close-test.\(iteration)")
      let peer = descriptors[1]
      let payload = Data(repeating: 0x7f, count: 64 * 1024)
      for requestID in UInt32(1)...4 {
        connection.send(Frame(kind: .pcm, requestID: requestID, payload: payload))
      }
      connection.close()
      Darwin.close(peer)
    }
  }
}
