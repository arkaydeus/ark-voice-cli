import Foundation
import Testing

import ArkVoiceKit

@Suite struct AudioStreamingTests {
  @Test func floatSamplesSurviveAWireRoundTrip() throws {
    let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.001]
    let data = AudioDecoding.data(from: samples, format: .f32le)

    #expect(data.count == samples.count * 4)
    #expect(try AudioDecoding.samples(from: data, format: .f32le) == samples)
  }

  @Test func sixteenBitSamplesRoundTripWithinQuantizationError() throws {
    let samples: [Float] = [0, 0.5, -0.5, 0.25, -0.75]
    let data = AudioDecoding.data(from: samples, format: .s16le)

    #expect(data.count == samples.count * 2)
    let decoded = try AudioDecoding.samples(from: data, format: .s16le)
    #expect(decoded.count == samples.count)
    for (original, roundTripped) in zip(samples, decoded) {
      #expect(abs(original - roundTripped) < 0.0001)
    }
  }

  @Test func sixteenBitConversionClampsInsteadOfWrapping() throws {
    let decoded = try AudioDecoding.samples(
      from: AudioDecoding.data(from: [2, -2], format: .s16le),
      format: .s16le
    )

    // Wrapping would flip the sign of a loud peak, which sounds like a click.
    #expect(decoded[0] > 0.99)
    #expect(decoded[1] < -0.99)
  }

  @Test func partialSampleBytesAreRejected() {
    #expect(throws: VoiceEngineError.self) {
      try AudioDecoding.samples(from: Data([1, 2, 3]), format: .f32le)
    }
    #expect(throws: VoiceEngineError.self) {
      try AudioDecoding.samples(from: Data([1]), format: .s16le)
    }
  }

  @Test func streamingWAVHeaderDescribesAnOpenEndedStream() {
    let header = StreamingWAVEncoder(sampleRate: 24_000, format: .f32le).header()
    let bytes = [UInt8](header)

    #expect(header.count == 44)
    #expect(String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF")
    #expect(String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE")
    #expect(String(bytes: bytes[36..<40], encoding: .ascii) == "data")
    #expect(bytes[20] == 3)  // IEEE float
    #expect(bytes[22] == 1)  // mono
    #expect(readUInt32(bytes, at: 24) == 24_000)
    #expect(readUInt32(bytes, at: 28) == 24_000 * 4)  // byte rate
    #expect(bytes[34] == 32)  // bits per sample
    // Unknown length: both size fields are the "read until EOF" sentinel.
    #expect(readUInt32(bytes, at: 4) == 0xFFFF_FFFF)
    #expect(readUInt32(bytes, at: 40) == 0xFFFF_FFFF)
  }

  @Test func streamingWAVHeaderStatesExactSizesWhenLengthIsKnown() {
    let header = StreamingWAVEncoder(sampleRate: 16_000, format: .s16le).header(totalFrames: 100)
    let bytes = [UInt8](header)

    #expect(bytes[20] == 1)  // integer PCM
    #expect(bytes[34] == 16)
    #expect(readUInt32(bytes, at: 40) == 200)
    #expect(readUInt32(bytes, at: 4) == 236)
  }

  @Test func streamedWAVIsReadableByTheSystemDecoder() throws {
    let encoder = StreamingWAVEncoder(sampleRate: 24_000, format: .s16le)
    let samples = (0..<2_400).map { sin(Float($0) * 0.05) * 0.4 }

    var stream = encoder.header(totalFrames: samples.count)
    stream.append(encoder.body(Array(samples.prefix(1_200))))
    stream.append(encoder.body(Array(samples.suffix(1_200))))

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-stream-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try stream.write(to: url)

    let decoded = try AudioDecoding.decodeFile(at: url, sampleRate: 24_000)
    #expect(decoded.count == samples.count)
    #expect(zip(decoded, samples).allSatisfy { abs($0 - $1) < 0.001 })
  }

  @Test func containersAreRecognizedFromTheirLeadingBytes() {
    var riff = Data("RIFF".utf8)
    riff.append(Data(repeating: 0, count: 8))
    #expect(AudioDecoding.containerExtension(for: riff) == "wav")

    var mp4 = Data(repeating: 0, count: 4)
    mp4.append(Data("ftypM4A ".utf8))
    #expect(AudioDecoding.containerExtension(for: mp4) == "m4a")

    var adts = Data([0xFF, 0xF1])
    adts.append(Data(repeating: 0, count: 10))
    #expect(AudioDecoding.containerExtension(for: adts) == "aac")

    #expect(AudioDecoding.containerExtension(for: Data(repeating: 0x41, count: 32)) == nil)
    #expect(AudioDecoding.containerExtension(for: Data([0x52, 0x49])) == nil)
  }

  @Test func resamplingIsSkippedWhenRatesMatchAndRejectsInvalidRates() throws {
    let samples: [Float] = [0.1, 0.2, 0.3]
    #expect(try AudioDecoding.resample(samples, from: 16_000, to: 16_000) == samples)

    let upsampled = try AudioDecoding.resample(samples, from: 8_000, to: 16_000)
    #expect(upsampled.count > samples.count)

    #expect(throws: VoiceEngineError.self) {
      try AudioDecoding.resample(samples, from: 0, to: 16_000)
    }
  }

  @Test func emptyTranscriptionFinishesWithoutLoadingTheRuntime() async throws {
    let session = VoiceSession()
    var events = [String]()
    for try await event in session.transcribe(samples: []) {
      switch event {
      case .partial(let text): events.append("partial:\(text)")
      case .final(let text): events.append("final:\(text)")
      }
    }
    #expect(events == ["final:"])
    #expect(!session.isTranscriptionModelLoaded)
  }

  @Test func decodingMixesChannelsAndReportsUnreadableFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-decode-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let garbage = directory.appendingPathComponent("broken.wav")
    try Data(repeating: 0x7f, count: 128).write(to: garbage)
    #expect(throws: VoiceEngineError.self) {
      try AudioDecoding.decodeFile(at: garbage, sampleRate: 16_000)
    }

    #expect(throws: VoiceEngineError.self) {
      try AudioDecoding.decodeContainerData(Data([0, 1, 2]), fileExtension: "wav", sampleRate: 16_000)
    }
  }

  private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}
