import Foundation
import Testing

@testable import ArkVoiceClient

@Suite struct PCMAudioTests {
  @Test func describesItsLength() {
    let audio = PCMAudio(samples: [Float](repeating: 0.25, count: 24_000), sampleRate: 24_000)
    #expect(audio.data.count == 48_000)
    #expect(audio.sampleCount == 24_000)
    #expect(audio.duration == 1)
  }

  @Test(arguments: [SampleFormat.s16le, .f32le])
  func wavRoundTripsInItsOwnEncoding(format: SampleFormat) throws {
    let audio = PCMAudio(samples: [0, 0.5, -0.5, 0.25], sampleRate: 16_000, format: format)
    let wav = audio.wavData
    #expect(wav.count == 44 + audio.data.count)
    #expect(wav[20] == (format == .f32le ? 3 : 1))
    #expect(try PCMAudio(wavData: wav) == audio)
  }

  @Test func wavWithUnknownDataLengthRunsToTheEndOfTheFile() throws {
    let audio = PCMAudio(samples: [0.5, -0.5, 0.25], sampleRate: 24_000)
    var wav = audio.wavData
    // `ark-voice tts -o -` streams before it knows the length.
    wav.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
    #expect(try PCMAudio(wavData: wav) == audio)
  }

  @Test func stereoIsAveragedToMono() throws {
    let left: [Int16] = [16_384, -16_384, 0]
    let right: [Int16] = [0, -16_384, 32_767]
    var interleaved = Data()
    for (l, r) in zip(left, right) {
      interleaved.appendInt16(l)
      interleaved.appendInt16(r)
    }
    let wav = Self.wav(tag: 1, channels: 2, rate: 8_000, bits: 16, data: interleaved)
    let audio = try PCMAudio(wavData: wav)
    #expect(audio.format == .s16le)
    #expect(audio.sampleRate == 8_000)
    #expect(audio.sampleCount == 3)
    let samples = audio.samples
    #expect(abs(samples[0] - 0.25) < 0.001)
    #expect(abs(samples[1] + 0.5) < 0.001)
    #expect(abs(samples[2] - 0.5) < 0.001)
  }

  @Test func extensibleFloatHeadersAreUnderstood() throws {
    let samples: [Float] = [0.5, -0.25]
    let data = PCMAudio.encode(samples, format: .f32le)
    let wav = Self.wav(tag: 0xFFFE, channels: 1, rate: 48_000, bits: 32, data: data, subformat: 3)
    let audio = try PCMAudio(wavData: wav)
    #expect(audio.format == .f32le)
    #expect(audio.samples == samples)
  }

  @Test func unsupportedEncodingsAreNamed() {
    let wav = Self.wav(tag: 1, channels: 1, rate: 16_000, bits: 24, data: Data(count: 6))
    #expect(throws: WAVError.unsupportedEncoding(formatTag: 1, bitsPerSample: 24)) {
      try PCMAudio(wavData: wav)
    }
    #expect(throws: WAVError.notWAV) { try PCMAudio(wavData: Data("hello".utf8)) }
  }

  /// Builds a WAV by hand, with an odd-sized chunk before `fmt ` to exercise
  /// chunk padding.
  static func wav(
    tag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16, data: Data, subformat: UInt16? = nil
  ) -> Data {
    var fmt = Data()
    fmt.appendLE(tag)
    fmt.appendLE(channels)
    fmt.appendLE(rate)
    fmt.appendLE(rate * UInt32(channels) * UInt32(bits / 8))
    fmt.appendLE(channels * bits / 8)
    fmt.appendLE(bits)
    if let subformat {
      fmt.appendLE(UInt16(22))
      fmt.appendLE(bits)
      fmt.appendLE(UInt32(0))
      fmt.appendLE(subformat)
      fmt.append(Data(count: 14))
    }
    var body = Data("WAVE".utf8)
    body.append(Data("LIST".utf8))
    body.appendLE(UInt32(3))
    body.append(Data([1, 2, 3, 0]))  // three bytes plus a pad byte
    body.append(Data("fmt ".utf8))
    body.appendLE(UInt32(fmt.count))
    body.append(fmt)
    body.append(Data("data".utf8))
    body.appendLE(UInt32(data.count))
    body.append(data)
    var file = Data("RIFF".utf8)
    file.appendLE(UInt32(body.count))
    file.append(body)
    return file
  }
}

extension Data {
  mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    var value = value.littleEndian
    Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
  }

  mutating func appendInt16(_ value: Int16) { appendLE(value) }
}
