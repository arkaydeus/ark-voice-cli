import AudioToolbox
import AVFoundation
import Foundation
import Testing

@testable import ArkVoiceCLI

@Suite struct AudioOutputTests {
  private enum StubEncodingError: Error {
    case failed
  }

  @Test func recognizesSupportedOutputExtensions() {
    #expect(AudioOutputFormat(url: URL(fileURLWithPath: "speech.wav")) == .wav)
    #expect(AudioOutputFormat(url: URL(fileURLWithPath: "speech.M4A")) == .m4a)
    #expect(AudioOutputFormat(url: URL(fileURLWithPath: "speech.AAC")) == .aac)
    #expect(AudioOutputFormat(url: URL(fileURLWithPath: "speech.mp3")) == nil)
  }

  @Test func compressedFormatsUseAACLCAndSharedBitRate() throws {
    for format in [AudioOutputFormat.m4a, .aac] {
      let settings = try format.settings(sampleRate: 24_000)
      #expect(settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
      #expect(settings[AVSampleRateKey] as? Double == 24_000)
      #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
      #expect(settings[AVEncoderBitRateKey] as? Int == AudioOutputFormat.aacBitRate)
    }
  }

  @Test(arguments: AudioOutputFormat.allCases)
  func writesExpectedOnDiskEncoding(format: AudioOutputFormat) throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let output = directory.appendingPathComponent("speech.\(format.rawValue)")
    let samples = samples(count: 4_800)
    try AudioFileWriter.write(
      samples: samples,
      sampleRate: 24_000,
      to: output,
      format: format
    )

    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0)

    let file = try AVAudioFile(forReading: output)
    let formatID = file.fileFormat.streamDescription.pointee.mFormatID
    switch format {
    case .wav:
      #expect(formatID == kAudioFormatLinearPCM)
    case .m4a, .aac:
      #expect(formatID == kAudioFormatMPEG4AAC)
    }
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.sampleRate == 24_000)

    let capacity = AVAudioFrameCount(max(file.length, 1))
    let decoded = try #require(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
    )
    try file.read(into: decoded)
    #expect(decoded.frameLength > 0)
    switch format {
    case .wav:
      #expect(Int(decoded.frameLength) == samples.count)
    case .m4a, .aac:
      #expect(abs(Int(decoded.frameLength) - samples.count) <= 2_048)
    }

    let channel = try #require(decoded.floatChannelData?[0])
    let decodedSamples = UnsafeBufferPointer(start: channel, count: Int(decoded.frameLength))
    #expect(decodedSamples.contains { abs($0) > 0.001 })

    let bytes = [UInt8](try Data(contentsOf: output).prefix(12))
    switch format {
    case .wav:
      #expect(String(bytes: bytes.prefix(4), encoding: .ascii) == "RIFF")
    case .m4a:
      #expect(String(bytes: bytes.dropFirst(4).prefix(4), encoding: .ascii) == "ftyp")
    case .aac:
      #expect(bytes.count >= 2)
      if bytes.count >= 2 {
        #expect(bytes[0] == 0xff)
        #expect(bytes[1] & 0xf6 == 0xf0)
      }
    }
  }

  @Test func compressedOutputsAreSubstantiallySmallerThanWAV() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = samples(count: 48_000)
    var sizes = [AudioOutputFormat: Int]()
    for format in AudioOutputFormat.allCases {
      let output = directory.appendingPathComponent("speech.\(format.rawValue)")
      try AudioFileWriter.write(
        samples: input,
        sampleRate: 24_000,
        to: output,
        format: format
      )
      sizes[format] = try fileSize(at: output)
    }

    let wavSize = try #require(sizes[.wav])
    let m4aSize = try #require(sizes[.m4a])
    let aacSize = try #require(sizes[.aac])
    #expect(m4aSize < wavSize / 2)
    #expect(aacSize < wavSize / 2)
  }

  @Test func emptySamplesFailClearlyWithoutChangingTheDestination() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let output = directory.appendingPathComponent("speech.wav")
    let original = Data("existing output".utf8)
    try original.write(to: output)

    let error = #expect(throws: VoiceEngineError.self) {
      try AudioFileWriter.write(samples: [], sampleRate: 24_000, to: output, format: .wav)
    }
    #expect(error?.localizedDescription.contains("No audio samples were generated") == true)
    #expect(try Data(contentsOf: output) == original)
    #expect(try temporaryArtifacts(in: directory).isEmpty)
  }

  @Test func fileCreationFailuresAreMappedAndLeaveNoOutput() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let nonDirectory = directory.appendingPathComponent("not-a-directory")
    try Data("blocker".utf8).write(to: nonDirectory)
    let output = nonDirectory.appendingPathComponent("speech.wav")

    let error = #expect(throws: VoiceEngineError.self) {
      try AudioFileWriter.write(
        samples: samples(count: 480),
        sampleRate: 24_000,
        to: output,
        format: .wav
      )
    }
    #expect(error?.localizedDescription.contains("Could not encode audio output") == true)
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func partialTemporaryFilesAreRemovedAndExistingOutputIsPreserved() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let output = directory.appendingPathComponent("speech.wav")
    let original = Data("existing output".utf8)
    try original.write(to: output)

    let error = #expect(throws: VoiceEngineError.self) {
      try AudioFileWriter.writeAtomically(to: output, format: .wav) { temporaryURL in
        try Data("partial encoded output".utf8).write(to: temporaryURL)
        throw StubEncodingError.failed
      }
    }

    #expect(error?.localizedDescription.contains("Could not encode audio output") == true)
    #expect(try Data(contentsOf: output) == original)
    #expect(try temporaryArtifacts(in: directory).isEmpty)
  }

  @Test func invalidSampleRateFailsWithoutCreatingOutput() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let output = directory.appendingPathComponent("speech.wav")
    let error = #expect(throws: VoiceEngineError.self) {
      try AudioFileWriter.write(
        samples: samples(count: 480),
        sampleRate: 0,
        to: output,
        format: .wav
      )
    }

    #expect(error?.localizedDescription.contains("Could not create an audio output buffer") == true)
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try temporaryArtifacts(in: directory).isEmpty)
  }

  @Test func successfulEncodingReplacesAnExistingOutputAndCleansUpTemporaryFiles() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let output = directory.appendingPathComponent("speech.wav")
    let original = Data("old output".utf8)
    try original.write(to: output)

    try AudioFileWriter.write(
      samples: samples(count: 480),
      sampleRate: 24_000,
      to: output,
      format: .wav
    )

    #expect(try Data(contentsOf: output) != original)
    #expect(try temporaryArtifacts(in: directory).isEmpty)
  }

  private func samples(count: Int) -> [Float] {
    (0..<count).map { index in
      Float(sin(2 * Double.pi * 440 * Double(index) / 24_000)) * 0.1
    }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-output-tests-\(UUID().uuidString)", isDirectory: true)
  }

  private func fileSize(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.intValue ?? 0
  }

  private func temporaryArtifacts(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".ark-voice-") }
  }
}
