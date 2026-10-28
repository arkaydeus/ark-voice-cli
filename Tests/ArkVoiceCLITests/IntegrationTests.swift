import ArkVoiceKit
import Foundation
import Testing

@Suite(.serialized) struct IntegrationTests {
  @Test func serveHandlesTerminationAndRemovesItsSocket() throws {
    let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/ark-voice")
    #expect(FileManager.default.isExecutableFile(atPath: binary.path))

    let socketPath = "/tmp/ark-voice-signal-\(UUID().uuidString.prefix(8)).sock"
    let process = Process()
    process.executableURL = binary
    process.arguments = [
      "serve", "--socket", socketPath, "--idle-unload", "off", "--idle-exit", "off",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      try? FileManager.default.removeItem(atPath: socketPath)
      try? FileManager.default.removeItem(atPath: socketPath + ".lock")
    }

    for _ in 0..<200 where !FileManager.default.fileExists(atPath: socketPath) {
      usleep(10_000)
    }
    #expect(FileManager.default.fileExists(atPath: socketPath))

    process.interrupt()
    for _ in 0..<200 where process.isRunning { usleep(10_000) }
    #expect(!process.isRunning)
    #expect(!FileManager.default.fileExists(atPath: socketPath))
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_BINARY"] != nil,
      "Set ARK_VOICE_INTEGRATION_BINARY to run model-backed CLI integration tests."
    )
  )
  func ttsOutputAndStreamContractWhenEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let binary = environment["ARK_VOICE_INTEGRATION_BINARY"] else {
      return
    }

    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-integration-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: output) }
    let result = try runBinary(binary, ["tts", "Integration test", "-o", output.path])

    #expect(result.status == 0)
    #expect(result.standardOutput == output.path + "\n")
    #expect(FileManager.default.fileExists(atPath: output.path))
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_BINARY"] != nil
        && ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_STT_AUDIO"] != nil,
      "Set ARK_VOICE_INTEGRATION_BINARY and ARK_VOICE_INTEGRATION_STT_AUDIO to run STT integration."
    )
  )
  func sttOutputWhenEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let binary = environment["ARK_VOICE_INTEGRATION_BINARY"],
      let audio = environment["ARK_VOICE_INTEGRATION_STT_AUDIO"]
    else {
      return
    }

    let result = try runBinary(binary, ["stt", audio])
    #expect(result.status == 0)
    #expect(!result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }


  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_BINARY"] != nil,
      "Set ARK_VOICE_INTEGRATION_BINARY to run model-backed CLI integration tests."
    )
  )
  func streamedStdoutAudioIsAPlayableWAVWhenEnabled() throws {
    guard let binary = ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_BINARY"] else {
      return
    }

    let result = try runBinary(binary, ["tts", "Streaming to standard output.", "-o", "-"])
    #expect(result.status == 0)

    let audio = result.standardOutputData
    #expect(audio.count > 44)
    #expect(audio.prefix(4) == Data("RIFF".utf8))
    #expect(audio[8..<12] == Data("WAVE".utf8))
    // Length is unknown while synthesis is still running.
    #expect(audio[4..<8] == Data([0xFF, 0xFF, 0xFF, 0xFF]))

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-streamed-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try audio.write(to: url)
    #expect(try AudioDecoding.decodeFile(at: url, sampleRate: 24_000).count > 0)
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_BINARY"] != nil,
      "Set ARK_VOICE_INTEGRATION_BINARY to run model-backed CLI integration tests."
    )
  )
  func speechSurvivesARoundTripThroughTheDaemonWhenEnabled() throws {
    guard let binary = ProcessInfo.processInfo.environment["ARK_VOICE_INTEGRATION_BINARY"] else {
      return
    }

    let socketPath = "/tmp/ark-voice-integration-\(UUID().uuidString.prefix(8)).sock"
    let server = Process()
    server.executableURL = URL(fileURLWithPath: binary)
    server.arguments = ["serve", "--socket", socketPath, "--idle-unload", "off"]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer {
      server.terminate()
      server.waitUntilExit()
      try? FileManager.default.removeItem(atPath: socketPath)
    }

    var attempts = 0
    while !FileManager.default.fileExists(atPath: socketPath) && attempts < 200 {
      usleep(25_000)
      attempts += 1
    }
    #expect(FileManager.default.fileExists(atPath: socketPath))

    let spoken = "The daemon keeps its models in memory."
    let audio = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-daemon-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: audio) }

    let synthesis = try runBinary(
      binary,
      ["client", "tts", spoken, "-o", audio.path, "--socket", socketPath]
    )
    #expect(synthesis.status == 0)
    #expect(synthesis.standardOutput == audio.path + "\n")

    let transcription = try runBinary(
      binary, ["client", "stt", audio.path, "--socket", socketPath])
    #expect(transcription.status == 0)

    // Recognition is not exact, so compare the words that carry the meaning.
    // "Daemon" and "demon" sound the same; audio cannot say which was meant.
    let heard = transcription.standardOutput.lowercased()
    #expect(heard.contains("daemon") || heard.contains("demon"))
    for word in ["models", "memory"] {
      #expect(heard.contains(word))
    }

    // A second request must not reload the models.
    let status = try runBinary(binary, ["client", "status", "--socket", socketPath])
    #expect(status.standardOutput.contains("synthesis model loaded: true"))
  }

  private func runBinary(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    // Read before waiting: a streamed response can outgrow the pipe buffer.
    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return ProcessResult(
      status: process.terminationStatus,
      standardOutputData: outputData,
      standardError: String(decoding: errorData, as: UTF8.self)
    )
  }
}

private struct ProcessResult {
  let status: Int32
  let standardOutputData: Data
  let standardError: String

  var standardOutput: String { String(decoding: standardOutputData, as: UTF8.self) }
}
