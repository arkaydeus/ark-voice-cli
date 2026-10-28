import ArkVoiceClient
import ArkVoiceKit
import ArkVoiceServer
import AVFoundation
import Foundation
import Testing

@testable import ArkVoiceCLI

@Suite struct OutputTests {
  @Test func textIsReadFromLiteralsAndFilesWithStrictDecoding() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    #expect(try readText(.literal("spoken")) == "spoken")

    let valid = directory.appendingPathComponent("valid.txt")
    try Data("words".utf8).write(to: valid)
    #expect(try readText(.file(valid.path)) == "words")

    let invalid = directory.appendingPathComponent("invalid.txt")
    try Data([0xff]).write(to: invalid)
    #expect(throws: VoiceEngineError.self) { try readText(.file(invalid.path)) }
    #expect(throws: VoiceEngineError.self) {
      try readText(.file(directory.appendingPathComponent("missing.txt").path))
    }
  }

  @Test func unsupportedContainersAreRejectedBeforeAnyModelLoads() {
    #expect(throws: VoiceEngineError.self) {
      _ = try SpeechWriter(options: SpeakOptions(text: .literal("x"), output: .file("out.mp3")))
    }
  }

  @Test func fileOutputCollectsChunksIntoOnePlayableFile() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("nested/speech.wav")

    let writer = try SpeechWriter(
      options: SpeakOptions(text: .literal("x"), output: .file(output.path))
    )
    writer.write(AudioChunk(samples: sine(count: 1_200), sampleRate: 24_000, index: 0, isLast: false))
    writer.write(AudioChunk(samples: sine(count: 1_200), sampleRate: 24_000, index: 1, isLast: true))
    let path = try writer.finish()

    #expect(path == output.path)
    let file = try AVAudioFile(forReading: output)
    #expect(file.length == 2_400)
    #expect(file.fileFormat.sampleRate == 24_000)
  }

  @Test func emptySynthesisIsReportedRatherThanWritingAnEmptyFile() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("silent.wav")

    let writer = try SpeechWriter(
      options: SpeakOptions(text: .literal("x"), output: .file(output.path))
    )
    #expect(throws: VoiceEngineError.self) { try writer.finish() }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func transcriptStreamingSelectsTheDocumentedOutputChannel() {
    #expect(
      CLIRunner.partialTranscriptDestination(
        for: TranscribeOptions(input: .file("a.wav"))) == .none
    )
    #expect(
      CLIRunner.partialTranscriptDestination(
        for: TranscribeOptions(input: .file("a.wav"), stream: true)) == .standardOutput
    )
    #expect(
      CLIRunner.partialTranscriptDestination(
        for: TranscribeOptions(input: .file("a.wav"), output: "a.txt", stream: true))
        == .standardError
    )
  }

  @Test func daemonWireFormatUsesCompactPCMUnlessFloatStdoutWasRequested() {
    #expect(
      CLIRunner.wireFormat(
        for: SpeakOptions(text: .literal("x"), output: .file("x.wav"), sampleFormat: .f32le))
        == .s16le
    )
    #expect(
      CLIRunner.wireFormat(
        for: SpeakOptions(text: .literal("x"), output: .standardOutput, sampleFormat: .f32le))
        == .f32le
    )
  }

  @Test func statusShowsRecognizerAndOldServerFallback() {
    var status = ServerStatus(transcriptionModelLoaded: true, transcriptionModel: "qwen")
    #expect(CLIRunner.renderStatus(status).contains("transcription model loaded: qwen"))

    status.transcriptionModel = nil
    #expect(CLIRunner.renderStatus(status).contains("transcription model loaded: yes"))
    status.transcriptionModelLoaded = false
    #expect(CLIRunner.renderStatus(status).contains("transcription model loaded: none"))
  }

  @Test func serverSessionUsesRequestedDefaultRecognizer() {
    let session = CLIRunner.makeSession(transcriptionModel: .qwen)
    #expect(session.configuration.transcriptionModel == .qwen)
  }

  private func sine(count: Int) -> [Float] {
    (0..<count).map { sin(Float($0) * 0.05) * 0.4 }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-cli-tests-\(UUID().uuidString)", isDirectory: true)
  }
}
