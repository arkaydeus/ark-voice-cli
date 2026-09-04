import Foundation
import Testing

@Suite(.serialized) struct IntegrationTests {
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
    let result = try run(binary, ["tts", "Integration test", "-o", output.path])

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

    let result = try run(binary, ["stt", audio])
    #expect(result.status == 0)
    #expect(!result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    return ProcessResult(
      status: process.terminationStatus,
      standardOutput: String(
        decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      ),
      standardError: String(
        decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      )
    )
  }
}

private struct ProcessResult {
  let status: Int32
  let standardOutput: String
  let standardError: String
}
