import Foundation
import Testing

import ArkVoiceClient

/// The client against a real `ark-voice serve` on a private socket.
///
/// The server binary comes from `ARK_VOICE_BINARY`, or `.build/release/ark-voice`
/// (built by `Scripts/build-release.sh`, which puts `mlx.metallib` beside it).
/// Model-backed tests also need Parakeet v2 and Chatterbox in `~/.ark-voice-cli`;
/// they never ask for a recognizer that may not be downloaded.
@Suite(.serialized) struct IntegrationTests {
  static let binary: String? = {
    if let path = ProcessInfo.processInfo.environment["ARK_VOICE_BINARY"], !path.isEmpty {
      return path
    }
    let release = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/release/ark-voice").path
    return FileManager.default.isExecutableFile(atPath: release) ? release : nil
  }()

  static let modelsPresent: Bool = {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ark-voice-cli/mlx-audio")
    return [
      "sonic-speech_parakeet-tdt-0.6b-v2-int8",
      "mlx-community_chatterbox-turbo-6bit",
      "mlx-community_S3TokenizerV2",
    ].allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
  }()

  @Test(.enabled(if: binary != nil, "No ark-voice binary: set ARK_VOICE_BINARY or run Scripts/build-release.sh"))
  func housekeepingNeedsNoModels() async throws {
    try await withServer { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      defer { client.close() }
      #expect(client.serverVersion == arkVoiceProtocolVersion)
      #expect(client.sampleRate == 24_000)
      let status = try await client.status()
      #expect(status.version == arkVoiceProtocolVersion)
      #expect(!status.synthesisModelLoaded)
      _ = try await client.voices()
      try await client.unload()
    }
  }

  @Test(
    .enabled(if: binary != nil, "No ark-voice binary: set ARK_VOICE_BINARY or run Scripts/build-release.sh"),
    .enabled(if: modelsPresent, "Parakeet v2 and Chatterbox are not in ~/.ark-voice-cli"),
    .timeLimit(.minutes(5))
  )
  func speechRoundTripsThroughTheDaemon() async throws {
    try await withServer { path in
      let client = try await ArkVoiceConnection.connect(socketPath: path)
      defer { client.close() }

      // Streaming synthesis.
      var chunks: [PCMAudio] = []
      var summary: SynthesisSummary?
      for try await event in client.synthesize("The quick brown fox jumps over the lazy dog.") {
        switch event {
        case .audio(let chunk, _): chunks.append(chunk)
        case .done(let done): summary = done
        }
      }
      let done = try #require(summary)
      #expect(!chunks.isEmpty)
      #expect(chunks.allSatisfy { $0.sampleRate == 24_000 && $0.format == .s16le })
      #expect(chunks.reduce(0) { $0 + $1.sampleCount } == done.samples)
      let speech = PCMAudio.joined(chunks, sampleRate: 24_000, format: .s16le)

      let wav = FileManager.default.temporaryDirectory
        .appendingPathComponent("ark-voice-client-\(UUID().uuidString).wav")
      defer { try? FileManager.default.removeItem(at: wav) }
      try speech.writeWAV(to: wav)
      #expect(try PCMAudio(contentsOfWAV: wav) == speech)

      // Transcription from the file, with the server's default recognizer.
      var partials = ""
      var transcript = ""
      for try await event in try client.transcribe(fileAt: wav) {
        switch event {
        case .partial(let text): partials += text
        case .final(let text): transcript = text
        }
      }
      let heard = transcript.lowercased()
      #expect(["quick", "brown", "fox", "lazy", "dog"].contains { heard.contains($0) }, "\(transcript)")
      #expect(!partials.isEmpty)

      // Pipelining: three requests in flight on one connection.
      async let status = client.status()
      async let voices = client.voices()
      async let short = client.synthesizeAudio("Pipelined.")
      #expect(try await status.synthesisModelLoaded)
      _ = try await voices
      #expect(try await short.audio.sampleCount > 0)

      // Cancelling mid-stream leaves the connection usable.
      let story = String(repeating: "This sentence keeps the synthesizer busy for a while. ", count: 8)
      for try await event in client.synthesize(story) {
        if case .audio = event { break }
      }
      #expect(try await client.status().version == arkVoiceProtocolVersion)

      // Voice profiles live under this server's temporary root.
      let name = "bindings-test-swift-\(UUID().uuidString.prefix(8).lowercased())"
      let saved = try await client.createVoice(named: name, from: speech)
      #expect(saved.hasSuffix("\(name).safetensors"))
      #expect(try await client.voices().contains(name))
    }
  }

  @Test(.enabled(if: binary != nil && modelsPresent), .timeLimit(.minutes(5)))
  func profileRootIsRemovedAfterFailure() async throws {
    struct InjectedFailure: Error {}
    let voices = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ark-voice-cli/voices")
    func snapshot() throws -> [String: Data] {
      guard FileManager.default.fileExists(atPath: voices.path) else { return [:] }
      return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: voices, includingPropertiesForKeys: nil)
        .filter { !$0.hasDirectoryPath }.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    let before = try snapshot()
    var directory: String?
    do {
      try await withServer { path in
        directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let client = try await ArkVoiceConnection.connect(socketPath: path)
        defer { client.close() }
        let audio = try await client.synthesizeAudio("An isolated reference voice.").audio
        let saved = try await client.createVoice(named: "failure-test", from: audio)
        #expect(URL(fileURLWithPath: saved).deletingLastPathComponent().path == directory! + "/voices")
        #expect(FileManager.default.fileExists(atPath: saved))
        throw InjectedFailure()
      }
      Issue.record("expected injected failure")
    } catch is InjectedFailure {}
    #expect(directory != nil && !FileManager.default.fileExists(atPath: directory!))
    #expect(try snapshot() == before)
  }

  private func withServer(_ body: (String) async throws -> Void) async throws {
    let binary = try #require(Self.binary)
    // Under /tmp: socket paths are limited to 104 bytes.
    let directory = "/tmp/akc-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer {
      do { try FileManager.default.removeItem(atPath: directory) }
      catch { Issue.record(error, "failed to remove the temporary daemon root") }
    }
    let path = directory + "/ark-voice.sock"
    let models = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ark-voice-cli/mlx-audio").path
    if FileManager.default.fileExists(atPath: models) {
      try FileManager.default.createSymbolicLink(atPath: directory + "/mlx-audio", withDestinationPath: models)
    }

    let server = Process()
    server.executableURL = URL(fileURLWithPath: binary)
    server.arguments = ["serve", "--model-root", directory, "--socket", path, "--idle-unload", "off"]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer {
      server.terminate()
      server.waitUntilExit()
    }

    for _ in 0..<300 where !FileManager.default.fileExists(atPath: path) {
      try await Task.sleep(for: .milliseconds(50))
    }
    try #require(FileManager.default.fileExists(atPath: path), "server did not start")
    try await body(path)
  }
}
