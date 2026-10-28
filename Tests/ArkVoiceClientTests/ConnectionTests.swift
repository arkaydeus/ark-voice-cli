import Darwin
import Foundation
import Testing

@testable import ArkVoiceClient

/// Client behaviour against a scripted server, so routing, cancellation, and
/// error handling are tested without models or the real daemon.
@Suite struct ConnectionTests {
  @Test func handshakeExposesTheServerAndHousekeepingWorks() async throws {
    try await withFakeServer({ peer in
      let hello = try peer.read()
      try peer.expect(hello.json?["op"] as? String == "hello")
      try peer.expect(hello.json?["version"] as? Int == 1)
      try peer.expect(hello.requestID == 1)
      try peer.send(["event": "hello-ok", "version": 1, "sampleRate": 22_050], to: hello.requestID)

      let voices = try peer.read()
      try peer.send(["event": "voices", "names": ["narrator"]], to: voices.requestID)
      let status = try peer.read()
      try peer.send(
        [
          "event": "status", "version": 1, "synthesisModelLoaded": true,
          "transcriptionModelLoaded": false, "requestsServed": 3, "uptimeSeconds": 1.5,
        ], to: status.requestID)
      let unload = try peer.read()
      try peer.expect(unload.json?["op"] as? String == "unload")
      try peer.send(["event": "done"], to: unload.requestID)
    }) { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      #expect(client.serverVersion == 1)
      #expect(client.sampleRate == 22_050)
      #expect(try await client.voices() == ["narrator"])
      let status = try await client.status()
      #expect(status.synthesisModelLoaded)
      #expect(!status.transcriptionModelLoaded)
      #expect(status.transcriptionModel == nil)
      #expect(status.requestsServed == 3)
      try await client.unload()
      client.close()
    }
  }

  @Test func aServerOnAnotherVersionIsRefused() async throws {
    try await withFakeServer({ peer in
      let hello = try peer.read()
      try peer.send(["event": "hello-ok", "version": 2], to: hello.requestID)
    }) { path in
      await #expect(throws: ArkVoiceClientError.unsupportedVersion(2)) {
        _ = try await ArkVoiceConnection.connect(socketPath: path)
      }
    }
  }

  @Test func aRefusedHandshakeCarriesTheServersCode() async throws {
    try await withFakeServer({ peer in
      let hello = try peer.read()
      try peer.send(
        ["event": "error", "code": "unsupported-version", "message": "speaks 1"],
        to: hello.requestID)
    }) { path in
      let error = await #expect(throws: ServerError.self) {
        _ = try await ArkVoiceConnection.connect(socketPath: path)
      }
      #expect(error?.code == .unsupportedVersion)
    }
  }

  @Test func errorCodesMapAndTheConnectionSurvives() async throws {
    try await withFakeServer({ peer in
      try peer.handshake()
      let tts = try peer.read()
      try peer.send(
        ["event": "error", "code": "models-missing", "message": "download first"],
        to: tts.requestID)
      let voices = try peer.read()
      try peer.send(["event": "error", "code": "from-the-future", "message": "?"], to: voices.requestID)
      let status = try peer.read()
      try peer.send(["event": "status", "version": 1], to: status.requestID)
    }) { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      let missing = await #expect(throws: ServerError.self) {
        _ = try await client.synthesizeAudio("hello")
      }
      #expect(missing?.code == .modelsMissing)
      #expect(missing?.message == "download first")

      let unknown = await #expect(throws: ServerError.self) { _ = try await client.voices() }
      #expect(unknown?.code == .failed)
      #expect(unknown?.rawCode == "from-the-future")

      #expect(try await client.status().version == 1)
    }
  }

  @Test func aConnectionLevelErrorFailsEveryPendingRequest() async throws {
    try await withFakeServer({ peer in
      try peer.handshake()
      _ = try peer.read()
      _ = try peer.read()
      try peer.send(["event": "error", "code": "bad-request", "message": "broken frame"], to: 0)
    }) { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      let first = Task { try await client.voices() }
      let second = Task { try await client.status() }
      let firstError = await #expect(throws: ServerError.self) { _ = try await first.value }
      let secondError = await #expect(throws: ServerError.self) { _ = try await second.value }
      #expect(firstError?.isConnectionLevel == true)
      #expect(secondError?.message == "broken frame")
      await #expect(throws: ArkVoiceClientError.connectionClosed) { _ = try await client.voices() }
    }
  }

  @Test func theServerHangingUpFailsPendingRequests() async throws {
    try await withFakeServer({ peer in
      try peer.handshake()
      _ = try peer.read()
      peer.hangUp()
    }) { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      await #expect(throws: ArkVoiceClientError.connectionClosed) { _ = try await client.status() }
    }
  }

  @Test func connectingToNothingSaysSo() async {
    let path = "/tmp/akc-none-\(UUID().uuidString.prefix(8)).sock"
    let error = await #expect(throws: ArkVoiceClientError.self) {
      _ = try await ArkVoiceConnection.connect(socketPath: path)
    }
    #expect(error == .notRunning(path: path))
    #expect(error?.localizedDescription.contains("ark-voice serve") == true)
  }

  @Test func pipelinedResponsesReachTheRightCaller() async throws {
    try await withFakeServer({ peer in
      try peer.handshake()
      var requests: [String: UInt32] = [:]
      for _ in 0..<2 {
        let frame = try peer.read()
        requests[frame.json?["op"] as! String] = frame.requestID
      }
      let tts = requests["tts"]!
      let status = requests["status"]!
      // Interleave, answering the later request first, plus noise for an id
      // nobody asked about.
      try peer.send(["event": "audio-format", "sampleRate": 24_000, "format": "s16le"], to: tts)
      try peer.sendPCM(Data([0xff, 0x3f]), to: tts)
      try peer.send(["event": "partial", "text": "stray"], to: 999)
      try peer.sendPCM(Data([1, 2]), to: 998)
      try peer.send(["event": "status", "version": 1, "requestsServed": 7], to: status)
      try peer.sendPCM(Data([0x00, 0xc0]), to: tts)
      try peer.send(["event": "done", "chunks": 2, "samples": 2, "seconds": 0.0001], to: tts)
    }) { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      let speech = client.synthesize("two chunks")
      async let status = client.status()

      var chunks: [PCMAudio] = []
      var summary: SynthesisSummary?
      for try await event in speech {
        switch event {
        case .audio(let chunk, let index):
          #expect(index == chunks.count)
          chunks.append(chunk)
        case .done(let done):
          summary = done
        }
      }
      #expect(try await status.requestsServed == 7)
      #expect(chunks.map(\.data) == [Data([0xff, 0x3f]), Data([0x00, 0xc0])])
      #expect(chunks.allSatisfy { $0.sampleRate == 24_000 && $0.format == .s16le })
      #expect(summary?.chunks == 2)
      #expect(summary?.samples == 2)
    }
  }

  @Test func stoppingEarlySendsCancelAndTheConnectionCarriesOn() async throws {
    try await withFakeServer({ peer in
      try peer.handshake()
      let tts = try peer.read()
      try peer.send(["event": "audio-format", "sampleRate": 24_000, "format": "s16le"], to: tts.requestID)
      try peer.sendPCM(Data(count: 4), to: tts.requestID)
      let cancel = try peer.read()
      try peer.expect(cancel.json?["op"] as? String == "cancel")
      try peer.expect(cancel.requestID == tts.requestID)
      // Frames already in flight before the server saw the cancel.
      try peer.sendPCM(Data(count: 4), to: tts.requestID)
      try peer.send(["event": "error", "code": "cancelled", "message": "cancelled"], to: tts.requestID)

      let status = try peer.read()
      try peer.expect(status.json?["op"] as? String == "status")
      try peer.send(["event": "status", "version": 1], to: status.requestID)
    }) { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      for try await event in client.synthesize("a long story") {
        if case .audio = event { break }
      }
      #expect(try await client.status().version == 1)
    }
  }

  @Test func uploadsAreSplitIntoBoundedFramesThenEnded() async throws {
    let samples = 300_000
    try await withFakeServer({ peer in
      try peer.handshake()
      let start = try peer.read()
      try peer.expect(start.json?["op"] as? String == "stt")
      try peer.expect(start.json?["format"] as? String == "s16le")
      try peer.expect(start.json?["sampleRate"] as? Int == 16_000)
      try peer.expect(start.json?["model"] as? String == "parakeet")
      var sizes: [Int] = []
      while true {
        let frame = try peer.read()
        try peer.expect(frame.requestID == start.requestID)
        if frame.kind == .pcm {
          sizes.append(frame.payload.count)
        } else {
          try peer.expect(frame.json?["op"] as? String == "end")
          break
        }
      }
      try peer.expect(sizes == [262_144, 262_144, samples * 2 - 524_288])
      try peer.send(["event": "partial", "text": " hello"], to: start.requestID)
      try peer.send(["event": "partial", "text": " world"], to: start.requestID)
      try peer.send(["event": "final", "text": "Hello world."], to: start.requestID)
      try peer.send(["event": "done"], to: start.requestID)
    }) { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      let audio = PCMAudio(samples: [Float](repeating: 0.1, count: samples), sampleRate: 16_000)
      var events: [TranscriptionEvent] = []
      for try await event in client.transcribe(audio, model: .parakeet) { events.append(event) }
      #expect(events == [.partial(" hello"), .partial(" world"), .final("Hello world.")])
    }
  }

  @Test func voiceCreationReturnsTheSavedPath() async throws {
    try await withFakeServer({ peer in
      try peer.handshake()
      let start = try peer.read()
      try peer.expect(start.json?["op"] as? String == "create-voice")
      try peer.expect(start.json?["name"] as? String == "narrator")
      try peer.expect(start.json?["sampleRate"] as? Int == 24_000)
      while try peer.read().kind == .pcm {}
      try peer.send(["event": "voice-created", "path": "/voices/narrator.safetensors"], to: start.requestID)
      try peer.send(["event": "done"], to: start.requestID)
    }) { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      let audio = PCMAudio(samples: [0.1, 0.2], sampleRate: 24_000)
      #expect(try await client.createVoice(named: "narrator", from: audio) == "/voices/narrator.safetensors")
    }
  }

  @Test func aStreamOutlivesTheConnectionReferenceThatMadeIt() async throws {
    try await withFakeServer({ peer in
      try peer.handshake()
      let tts = try peer.read()
      try peer.sendPCM(Data(count: 2), to: tts.requestID)
      try peer.send(["event": "done", "chunks": 1, "samples": 1, "seconds": 0], to: tts.requestID)
    }) { path in
      let stream = try await ArkVoiceConnection.connect(socketPath: path).synthesize("hi")
      var count = 0
      for try await _ in stream { count += 1 }
      #expect(count == 2)
    }
  }
}

// MARK: - Fake server

struct ReceivedFrame {
  let kind: FrameKind
  let requestID: UInt32
  let payload: Data

  var json: [String: Any]? {
    kind == .json ? (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] : nil
  }
}

/// The server end of one accepted connection, driven by a test script.
final class FakePeer: @unchecked Sendable {
  let descriptor: Int32

  init(descriptor: Int32) { self.descriptor = descriptor }

  func read() throws -> ReceivedFrame {
    let header = try FrameHeader(try readExactly(Frame.headerSize))
    let payload = try readExactly(header.payloadLength)
    return ReceivedFrame(kind: header.kind, requestID: header.requestID, payload: payload)
  }

  /// Fails the script; `#expect` cannot report from this thread.
  func expect(
    _ condition: Bool, _ comment: String = "", line: Int = #line
  ) throws {
    struct ExpectationFailed: Error, CustomStringConvertible {
      let description: String
    }
    if !condition {
      throw ExpectationFailed(description: "script expectation failed at line \(line) \(comment)")
    }
  }

  func hangUp() {
    shutdown(descriptor, SHUT_RDWR)
  }

  func handshake() throws {
    let hello = try read()
    try send(["event": "hello-ok", "version": 1, "sampleRate": 24_000], to: hello.requestID)
  }

  func send(_ message: [String: Any], to requestID: UInt32) throws {
    let payload = try JSONSerialization.data(withJSONObject: message)
    try write(Frame(kind: .json, requestID: requestID, payload: payload).encoded())
  }

  func sendPCM(_ payload: Data, to requestID: UInt32) throws {
    try write(Frame(kind: .pcm, requestID: requestID, payload: payload).encoded())
  }

  private func write(_ data: Data) throws {
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
        guard written > 0 else { throw ArkVoiceClientError.systemCall("write", errno) }
        offset += written
      }
    }
  }

  private func readExactly(_ count: Int) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
      let received = buffer[filled...].withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, count - filled)
      }
      guard received > 0 else { throw FrameError.connectionClosed }
      filled += received
    }
    return Data(buffer)
  }
}

/// Runs `script` as the server for one connection while `body` acts as the
/// client, then reports anything the script threw.
func withFakeServer(
  _ script: @escaping @Sendable (FakePeer) throws -> Void,
  _ body: (String) async throws -> Void
) async throws {
  let path = "/tmp/akc-\(UUID().uuidString.prefix(8)).sock"
  let listener = socket(AF_UNIX, SOCK_STREAM, 0)
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  try #require(bound == 0 && listen(listener, 1) == 0)
  defer {
    close(listener)
    unlink(path)
  }

  let scriptResult = Task.detached { () -> (any Error)? in
    await withCheckedContinuation { continuation in
      Thread {
        let descriptor = accept(listener, nil, nil)
        let peer = FakePeer(descriptor: descriptor)
        do {
          try script(peer)
          // Hold the connection open until the client hangs up, so the
          // script's last replies are not raced by a reset.
          while (try? peer.read()) != nil {}
          close(descriptor)
          continuation.resume(returning: nil)
        } catch {
          close(descriptor)
          continuation.resume(returning: error)
        }
      }.start()
    }
  }

  // The script finishes once the client hangs up, which dropping it does.
  // Report its failure first: it usually explains the client's.
  var bodyError: (any Error)?
  do { try await body(path) } catch { bodyError = error }
  if let error = await scriptResult.value {
    Issue.record(error, "fake server script failed")
  }
  if let bodyError { throw bodyError }
}
