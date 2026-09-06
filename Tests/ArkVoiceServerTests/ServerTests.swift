import Darwin
import Foundation
import Testing

import ArkVoiceKit

@testable import ArkVoiceServer

/// End-to-end coverage of the socket, framing, dispatch, and error mapping.
///
/// No models are required: the session points at an empty model root, so
/// requests that would need weights come back as errors instead of loading a
/// gigabyte of them. Everything up to that point is the real server.
@Suite(.serialized) struct ServerTests {
  @Test func handshakeStatusAndVoiceListing() async throws {
    try await withServer { socketPath in
      try await onThread {
        let client = try VoiceClient(socketPath: socketPath)
        defer { client.close() }

        let status = try client.status()
        #expect(status.event == .status)
        #expect(status.version == arkVoiceProtocolVersion)
        #expect(status.synthesisModelLoaded == false)
        #expect(status.transcriptionModelLoaded == false)

        #expect(try client.voices().isEmpty)
        try client.unload()
      }
    }
  }

  @Test func requestsWithoutModelsFailWithoutKillingTheConnection() async throws {
    try await withServer { socketPath in
      try await onThread {
        let client = try VoiceClient(socketPath: socketPath)
        defer { client.close() }

        let failure = #expect(throws: ServerRefusedError.self) {
          try client.synthesize(text: "hello", onChunk: { _, _ in })
        }
        #expect(failure?.code == .modelsMissing || failure?.code == .failed)

        // The connection is still usable for the next request.
        #expect(try client.voices().isEmpty)
      }
    }
  }

  @Test func operationsBeforeTheHandshakeAreRefused() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }

        var request = ClientMessage(op: .tts)
        request.text = "hello"
        connection.sendSynchronously(
          Frame(kind: .json, requestID: 1, payload: try ProtocolCoder.encode(request))
        )

        let reply = try ProtocolCoder.decodeServer(try connection.readFrame().payload)
        #expect(reply.event == .error)
        #expect(reply.code == .badRequest)
        #expect(reply.message?.contains("hello") == true)
      }
    }
  }

  @Test func aMismatchedProtocolVersionIsRejected() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }

        var hello = ClientMessage(op: .hello)
        hello.version = arkVoiceProtocolVersion + 1
        connection.sendSynchronously(
          Frame(kind: .json, requestID: 1, payload: try ProtocolCoder.encode(hello))
        )

        let reply = try ProtocolCoder.decodeServer(try connection.readFrame().payload)
        #expect(reply.event == .error)
        #expect(reply.code == .unsupportedVersion)
        #expect(reply.version == arkVoiceProtocolVersion)
      }
    }
  }

  @Test func audioForAnUnopenedRequestIsReportedNotBuffered() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)

        connection.sendSynchronously(
          Frame(kind: .pcm, requestID: 41, payload: Data([0, 0, 0, 0]))
        )
        let stray = try ProtocolCoder.decodeServer(try connection.readFrame().payload)
        #expect(stray.event == .error)
        #expect(stray.code == .unknownRequest)

        connection.sendSynchronously(
          Frame(
            kind: .json,
            requestID: 42,
            payload: try ProtocolCoder.encode(ClientMessage(op: .end))
          )
        )
        let unopened = try ProtocolCoder.decodeServer(try connection.readFrame().payload)
        #expect(unopened.event == .error)
        #expect(unopened.code == .unknownRequest)
      }
    }
  }

  @Test func transcriptionAcceptsAudioAndAnswersOnTheSameRequest() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)

        var request = ClientMessage(op: .stt)
        request.format = .s16le
        request.sampleRate = 16_000
        connection.sendSynchronously(
          Frame(kind: .json, requestID: 5, payload: try ProtocolCoder.encode(request))
        )
        connection.sendSynchronously(
          Frame(
            kind: .pcm,
            requestID: 5,
            payload: AudioDecoding.data(
              from: [Float](repeating: 0.1, count: 1_600), format: .s16le)
          )
        )
        connection.sendSynchronously(
          Frame(
            kind: .json,
            requestID: 5,
            payload: try ProtocolCoder.encode(ClientMessage(op: .end))
          )
        )

        // Without models this ends in an error, but it must be this request's
        // error, addressed to this request.
        let frame = try connection.readFrame()
        #expect(frame.requestID == 5)
        let reply = try ProtocolCoder.decodeServer(frame.payload)
        #expect(reply.event == .error)
      }
    }
  }

  @Test func voiceCreationAcceptsAudioAndAnswersOnTheSameRequest() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)

        var request = ClientMessage(op: .createVoice)
        request.name = "narrator"
        request.format = .s16le
        request.sampleRate = 24_000
        try send(request, requestID: 8, on: connection)
        connection.sendSynchronously(
          Frame(kind: .pcm, requestID: 8, payload: Data(repeating: 0, count: 400)))
        try send(ClientMessage(op: .end), requestID: 8, on: connection)

        let reply = try readMessage(on: connection, requestID: 8)
        #expect(reply.event == .error)
        #expect(reply.code == .modelsMissing || reply.code == .failed)
      }
    }
  }

  @Test func nonPositiveUploadSampleRatesAreRejectedImmediately() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)
        var request = ClientMessage(op: .stt)
        request.sampleRate = 0
        try send(request, requestID: 5, on: connection)
        let reply = try readMessage(on: connection, requestID: 5)
        #expect(reply.event == .error)
        #expect(reply.code == .badRequest)
      }
    }
  }

  @Test func cancellingPendingAudioReleasesTheRequest() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)

        try send(ClientMessage(op: .stt), requestID: 5, on: connection)
        connection.sendSynchronously(
          Frame(kind: .pcm, requestID: 5, payload: Data([0, 0, 0, 0])))
        try send(ClientMessage(op: .cancel), requestID: 5, on: connection)

        let cancelled = try readMessage(on: connection, requestID: 5)
        #expect(cancelled.event == .error)
        #expect(cancelled.code == .cancelled)

        try send(ClientMessage(op: .end), requestID: 5, on: connection)
        let ended = try readMessage(on: connection, requestID: 5)
        #expect(ended.event == .error)
        #expect(ended.code == .unknownRequest)
      }
    }
  }

  @Test func cancellingARunningRequestProducesTheTerminalCancellationError() async throws {
    try await withServerAndSession { socketPath, session in
      let enteredGate = DispatchSemaphore(value: 0)
      let releaseGate = DispatchSemaphore(value: 0)
      let blocker = Task {
        await session.unloadModels {
          enteredGate.signal()
          releaseGate.wait()
          return false
        }
      }
      try await onThread { enteredGate.wait() }

      try await onThread {
        var released = false
        defer { if !released { releaseGate.signal() } }
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)
        try send(ClientMessage(op: .unload), requestID: 5, on: connection)
        try send(ClientMessage(op: .cancel), requestID: 5, on: connection)
        // The frame consumer is serial. Receiving this later status response
        // proves it has already applied the cancellation before the gate opens.
        try send(ClientMessage(op: .status), requestID: 6, on: connection)
        #expect(try readMessage(on: connection, requestID: 6).event == .status)
        releaseGate.signal()
        released = true
        let cancelled = try readMessage(on: connection, requestID: 5)
        #expect(cancelled.event == .error)
        #expect(cancelled.code == .cancelled)
      }
      _ = await blocker.value
    }
  }

  @Test func duplicateRequestIDsAreRejectedWithoutDestroyingTheOriginal() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)

        var request = ClientMessage(op: .stt)
        request.format = .s16le
        request.sampleRate = 16_000
        try send(request, requestID: 5, on: connection)
        try send(request, requestID: 5, on: connection)

        let duplicate = try readMessage(on: connection, requestID: 5)
        #expect(duplicate.event == .error)
        #expect(duplicate.code == .badRequest)
        #expect(duplicate.message?.contains("already in flight") == true)

        connection.sendSynchronously(
          Frame(kind: .pcm, requestID: 5, payload: Data([0, 0])))
        try send(ClientMessage(op: .end), requestID: 5, on: connection)
        let original = try readMessage(on: connection, requestID: 5)
        #expect(original.event == .error)
        #expect(original.code == .modelsMissing || original.code == .failed)
      }
    }
  }

  @Test func pendingAudioStreamsAreBoundedPerConnection() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)

        for requestID in UInt32(100)..<UInt32(109) {
          try send(ClientMessage(op: .stt), requestID: requestID, on: connection)
        }
        let refused = try connection.readFrame()
        #expect(refused.requestID == 108)
        let message = try ProtocolCoder.decodeServer(refused.payload)
        #expect(message.event == .error)
        #expect(message.code == .badRequest)
        #expect(message.message?.contains("Too many audio streams") == true)

        for requestID in UInt32(100)..<UInt32(108) {
          try send(ClientMessage(op: .cancel), requestID: requestID, on: connection)
          #expect(try readMessage(on: connection, requestID: requestID).code == .cancelled)
        }
      }
    }
  }

  @Test func perRequestAndAggregateAudioBudgetsReleaseOverflowingStreams() async throws {
    try await withServer(
      audioBufferLimits: AudioBufferLimits(
        perRequestSamples: 4,
        totalSamples: 6,
        streamCount: 8
      )
    ) { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)

        try send(ClientMessage(op: .stt), requestID: 5, on: connection)
        connection.sendSynchronously(
          Frame(kind: .pcm, requestID: 5, payload: Data(repeating: 0, count: 8)))

        try send(ClientMessage(op: .stt), requestID: 6, on: connection)
        connection.sendSynchronously(
          Frame(kind: .pcm, requestID: 6, payload: Data(repeating: 0, count: 6)))
        let aggregate = try readMessage(on: connection, requestID: 6)
        #expect(aggregate.event == .error)
        #expect(aggregate.code == .badRequest)

        try send(ClientMessage(op: .stt), requestID: 7, on: connection)
        connection.sendSynchronously(
          Frame(kind: .pcm, requestID: 7, payload: Data(repeating: 0, count: 10)))
        let perRequest = try readMessage(on: connection, requestID: 7)
        #expect(perRequest.event == .error)
        #expect(perRequest.code == .badRequest)

        try send(ClientMessage(op: .cancel), requestID: 5, on: connection)
        #expect(try readMessage(on: connection, requestID: 5).code == .cancelled)
      }
    }
  }

  @Test func aggregateAudioBudgetSpansConnections() async throws {
    try await withServer(
      audioBufferLimits: AudioBufferLimits(
        perRequestSamples: 6,
        totalSamples: 6,
        streamCount: 8
      )
    ) { socketPath in
      try await onThread {
        let first = try connectToSocket(path: socketPath)
        let second = try connectToSocket(path: socketPath)
        defer {
          first.close()
          second.close()
        }
        try handshake(on: first)
        try handshake(on: second)

        try send(ClientMessage(op: .stt), requestID: 5, on: first)
        first.sendSynchronously(
          Frame(kind: .pcm, requestID: 5, payload: Data(repeating: 0, count: 8)))
        // Each connection has its own consumer task. A later response on the
        // first connection proves its PCM frame has reserved the global budget
        // before the second connection competes for the remainder.
        try send(ClientMessage(op: .status), requestID: 7, on: first)
        #expect(try readMessage(on: first, requestID: 7).event == .status)

        try send(ClientMessage(op: .stt), requestID: 6, on: second)
        second.sendSynchronously(
          Frame(kind: .pcm, requestID: 6, payload: Data(repeating: 0, count: 6)))
        let refused = try readMessage(on: second, requestID: 6)
        #expect(refused.event == .error)
        #expect(refused.code == .badRequest)

        try send(ClientMessage(op: .cancel), requestID: 5, on: first)
        #expect(try readMessage(on: first, requestID: 5).code == .cancelled)
      }
    }
  }

  @Test func pipelinedRequestsKeepTheirResponseIdentifiers() async throws {
    try await withServer { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)

        try send(ClientMessage(op: .tts, text: "one"), requestID: 20, on: connection)
        try send(ClientMessage(op: .tts, text: "two"), requestID: 21, on: connection)

        var answered = Set<UInt32>()
        while answered.count < 2 {
          let frame = try connection.readFrame()
          let message = try ProtocolCoder.decodeServer(frame.payload)
          if message.event == .error { answered.insert(frame.requestID) }
        }
        #expect(answered == Set([20, 21]))
      }
    }
  }

  @Test func activeUploadsPreventIdleExit() async throws {
    try await withServer(idleExitSeconds: 0.2) { socketPath in
      try await onThread {
        let connection = try connectToSocket(path: socketPath)
        defer { connection.close() }
        try handshake(on: connection)
        try send(ClientMessage(op: .stt), requestID: 5, on: connection)

        for _ in 0..<7 {
          connection.sendSynchronously(
            Frame(kind: .pcm, requestID: 5, payload: Data([0, 0])))
          Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(FileManager.default.fileExists(atPath: socketPath))
        try send(ClientMessage(op: .end), requestID: 5, on: connection)
        #expect(try readMessage(on: connection, requestID: 5).event == .error)
      }
    }
  }

  @Test func controlTrafficRefreshesTheIdleDeadline() async throws {
    try await withServer(idleExitSeconds: 0.2) { socketPath in
      try await onThread {
        let client = try VoiceClient(socketPath: socketPath)
        defer { client.close() }
        for _ in 0..<6 {
          _ = try client.status()
          Thread.sleep(forTimeInterval: 0.06)
        }
        #expect(FileManager.default.fileExists(atPath: socketPath))
      }
    }
  }

  @Test func disconnectingPendingAndRunningRequestsAllowsIdleExit() async throws {
    try await withServer(idleExitSeconds: 0.2) { socketPath in
      try await onThread {
        let pending = try connectToSocket(path: socketPath)
        try handshake(on: pending)
        try send(ClientMessage(op: .stt), requestID: 5, on: pending)
        pending.close()

        let running = try connectToSocket(path: socketPath)
        try handshake(on: running)
        try send(ClientMessage(op: .unload), requestID: 6, on: running)
        running.close()
      }
      for _ in 0..<100 {
        if !FileManager.default.fileExists(atPath: socketPath) { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      Issue.record("The server stayed busy after both clients disconnected.")
    }
  }

  @Test func aSecondServerWillNotStealALiveSocket() async throws {
    try await withServer { socketPath in
      #expect(throws: SocketError.self) { _ = try SocketListener(path: socketPath) }
    }
  }

  @Test func aStaleSocketIsReplaced() throws {
    let path = Self.temporarySocketPath()
    try Self.createStaleSocket(at: path)
    defer { Self.removeSocketArtifacts(path) }

    let listener = try SocketListener(path: path)
    listener.close()
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test func aRegularFileAtTheSocketPathIsPreserved() throws {
    let path = Self.temporarySocketPath()
    let contents = Data("keep me".utf8)
    #expect(FileManager.default.createFile(atPath: path, contents: contents))
    defer { Self.removeSocketArtifacts(path) }

    let error = #expect(throws: SocketError.self) { _ = try SocketListener(path: path) }
    if case .unsafeExistingPath? = error {
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == contents)
    } else {
      Issue.record("Expected unsafeExistingPath, got \(String(describing: error)).")
    }
  }

  @Test func listenerCloseDoesNotDeleteAReplacementFile() throws {
    let path = Self.temporarySocketPath()
    defer { Self.removeSocketArtifacts(path) }
    let listener = try SocketListener(path: path)

    #expect(Darwin.unlink(path) == 0)
    let contents = Data("replacement".utf8)
    #expect(FileManager.default.createFile(atPath: path, contents: contents))
    listener.close()

    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == contents)
  }

  @Test func listeningSocketIsPrivateFromCreationOnward() throws {
    let path = Self.temporarySocketPath()
    defer { Self.removeSocketArtifacts(path) }
    let listener = try SocketListener(path: path)
    defer { listener.close() }

    var info = stat()
    #expect(lstat(path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
  }

  @Test func concurrentStartupAgainstAStaleSocketHasOneWinner() async throws {
    let path = Self.temporarySocketPath()
    try Self.createStaleSocket(at: path)
    defer { Self.removeSocketArtifacts(path) }

    async let first = onThread { try? SocketListener(path: path) }
    async let second = onThread { try? SocketListener(path: path) }
    let firstListener = try await first
    let secondListener = try await second
    let listeners = [firstListener, secondListener].compactMap { $0 }
    #expect(listeners.count == 1)
    #expect(SocketListener.isLive(path: path))
    listeners.forEach { $0.close() }
  }

  @Test func malformedLiveFramesReturnAGlobalProtocolError() async throws {
    try await withServer { socketPath in
      try await onThread {
        var badMagic = Frame(kind: .json, requestID: 99, payload: Data()).encoded()
        badMagic[0] = 0
        var badKind = Frame(kind: .json, requestID: 99, payload: Data()).encoded()
        badKind[1] = 9
        var badFlags = Frame(kind: .json, requestID: 99, payload: Data()).encoded()
        badFlags[2] = 1
        var oversized = Frame(kind: .json, requestID: 99, payload: Data()).encoded()
        oversized.replaceSubrange(8..<12, with: [1, 0, 0, 4])

        for malformed in [badMagic, badKind, badFlags, oversized] {
          let descriptor = try Self.connectRaw(to: socketPath)
          let connection = SocketConnection(
            descriptor: descriptor, label: "ark-voice.test.raw")
          try Self.writeAll(malformed, to: descriptor)
          let frame = try connection.readFrame()
          #expect(frame.requestID == 0)
          let reply = try ProtocolCoder.decodeServer(frame.payload)
          #expect(reply.event == .error)
          #expect(reply.code == .badRequest)
          connection.close()
        }

        let descriptor = try Self.connectRaw(to: socketPath)
        let connection = SocketConnection(descriptor: descriptor, label: "ark-voice.test.truncated")
        try Self.writeAll(Data([Frame.magic, FrameKind.json.rawValue, 0]), to: descriptor)
        shutdown(descriptor, SHUT_WR)
        let frame = try connection.readFrame()
        #expect(frame.requestID == 0)
        #expect(try ProtocolCoder.decodeServer(frame.payload).code == .badRequest)
        connection.close()
      }
    }
  }

  @Test func voiceClientSurfacesGlobalProtocolErrors() async throws {
    let path = Self.temporarySocketPath()
    defer { Self.removeSocketArtifacts(path) }
    let listener = try SocketListener(path: path)
    defer { listener.close() }

    async let serverSide: Void = onThread {
      let connection = try listener.accept()
      defer { connection.close() }
      let hello = try connection.readFrame()
      var helloOK = ServerMessage(event: .helloOK)
      helloOK.version = arkVoiceProtocolVersion
      connection.sendSynchronously(
        Frame(kind: .json, requestID: hello.requestID, payload: ProtocolCoder.encode(helloOK)))

      _ = try connection.readFrame()
      var failure = ServerMessage(event: .error)
      failure.code = .badRequest
      failure.message = "global protocol failure"
      connection.sendSynchronously(
        Frame(kind: .json, requestID: 0, payload: ProtocolCoder.encode(failure)))
    }

    try await onThread {
      let client = try VoiceClient(socketPath: path)
      defer { client.close() }
      let error = #expect(throws: ServerRefusedError.self) { _ = try client.status() }
      #expect(error?.code == .badRequest)
      #expect(error?.message == "global protocol failure")
    }
    try await serverSide
  }

  @Test func connectingToNothingSaysSoPlainly() {
    let error = #expect(throws: SocketError.self) {
      _ = try connectToSocket(path: Self.temporarySocketPath())
    }
    #expect(error?.localizedDescription.contains("ark-voice serve") == true)
  }

  // MARK: - Harness

  /// Runs `body` against a live server on a private socket.
  private func withServer(
    idleExitSeconds: Double? = nil,
    audioBufferLimits: AudioBufferLimits = AudioBufferLimits(),
    _ body: @escaping @Sendable (String) async throws -> Void
  ) async throws {
    let modelRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-server-tests-\(UUID().uuidString)", isDirectory: true)
    let socketPath = Self.temporarySocketPath()
    defer {
      try? FileManager.default.removeItem(at: modelRoot)
      Self.removeSocketArtifacts(socketPath)
    }

    let session = VoiceSession(configuration: SessionConfiguration(modelRoot: modelRoot))
    var configuration = VoiceServer.Configuration(
      socketPath: socketPath,
      idleUnloadSeconds: nil,
      idleExitSeconds: idleExitSeconds
    )
    configuration.audioBufferLimits = audioBufferLimits
    let server = VoiceServer(session: session, configuration: configuration)

    let running = Task { try await server.run() }
    try await waitForSocket(at: socketPath)
    do {
      try await body(socketPath)
    } catch {
      server.stop()
      _ = try? await running.value
      throw error
    }
    server.stop()
    _ = try? await running.value
  }

  private func withServerAndSession(
    _ body: @escaping @Sendable (String, VoiceSession) async throws -> Void
  ) async throws {
    let modelRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-server-tests-\(UUID().uuidString)", isDirectory: true)
    let socketPath = Self.temporarySocketPath()
    defer {
      try? FileManager.default.removeItem(at: modelRoot)
      Self.removeSocketArtifacts(socketPath)
    }

    let session = VoiceSession(configuration: SessionConfiguration(modelRoot: modelRoot))
    let server = VoiceServer(
      session: session,
      configuration: VoiceServer.Configuration(
        socketPath: socketPath,
        idleUnloadSeconds: nil,
        idleExitSeconds: nil
      )
    )
    let running = Task { try await server.run() }
    try await waitForSocket(at: socketPath)
    do {
      try await body(socketPath, session)
    } catch {
      server.stop()
      _ = try? await running.value
      throw error
    }
    server.stop()
    _ = try? await running.value
  }

  private func waitForSocket(at path: String) async throws {
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The server never bound \(path).")
  }

  /// Socket paths are limited to about 100 bytes, which the sandboxed temporary
  /// directory can exceed on its own.
  private static func temporarySocketPath() -> String {
    "/tmp/ark-voice-test-\(UUID().uuidString.prefix(8)).sock"
  }

  private func handshake(on connection: SocketConnection) throws {
    var hello = ClientMessage(op: .hello)
    hello.version = arkVoiceProtocolVersion
    connection.sendSynchronously(
      Frame(kind: .json, requestID: 1, payload: try ProtocolCoder.encode(hello))
    )
    let reply = try ProtocolCoder.decodeServer(try connection.readFrame().payload)
    #expect(reply.event == .helloOK)
  }

  private func send(
    _ message: ClientMessage,
    requestID: UInt32,
    on connection: SocketConnection
  ) throws {
    connection.sendSynchronously(
      Frame(kind: .json, requestID: requestID, payload: try ProtocolCoder.encode(message)))
  }

  private func readMessage(
    on connection: SocketConnection,
    requestID: UInt32
  ) throws -> ServerMessage {
    while true {
      let frame = try connection.readFrame()
      guard frame.requestID == requestID, frame.kind == .json else { continue }
      return try ProtocolCoder.decodeServer(frame.payload)
    }
  }

  private static func createStaleSocket(at path: String) throws {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SocketError.systemCall("socket", errno) }
    defer { Darwin.close(descriptor) }
    var address = try SocketListener.address(for: path)
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, size)
      }
    }
    guard result == 0 else { throw SocketError.systemCall("bind", errno) }
  }

  private static func connectRaw(to path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SocketError.systemCall("socket", errno) }
    var address = try SocketListener.address(for: path)
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, size)
      }
    }
    guard result == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw SocketError.systemCall("connect", code)
    }
    return descriptor
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
      guard var pointer = raw.baseAddress else { return }
      var remaining = raw.count
      while remaining > 0 {
        let written = Darwin.write(descriptor, pointer, remaining)
        if written > 0 {
          pointer = pointer.advanced(by: written)
          remaining -= written
        } else if written < 0, errno == EINTR {
          continue
        } else {
          throw SocketError.systemCall("write", errno)
        }
      }
    }
  }

  private static func removeSocketArtifacts(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + ".lock")
  }
}

/// Runs blocking socket work off the cooperative thread pool.
private func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    let thread = Thread {
      do {
        continuation.resume(returning: try body())
      } catch {
        continuation.resume(throwing: error)
      }
    }
    thread.name = "ark-voice.test-client"
    thread.start()
  }
}
