import AVFoundation
import AudioToolbox
import Foundation

public enum AudioOutputFormat: String, CaseIterable, Sendable {
  case wav
  case m4a
  case aac

  public static let aacBitRate = 48_000

  public static var supportedExtensionsDescription: String {
    allCases.map { $0.rawValue }.joined(separator: ", ")
  }

  public init?(url: URL) {
    self.init(rawValue: url.pathExtension.lowercased())
  }

  /// Whether the container can be produced without seeking back over what was
  /// already written, which is what streaming to a pipe requires.
  public var supportsStreaming: Bool {
    self == .wav
  }

  public func settings(sampleRate: Int) throws -> [String: Any] {
    switch self {
    case .wav:
      guard
        let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: Double(sampleRate),
          channels: 1,
          interleaved: false
        )
      else {
        throw VoiceEngineError.audioEncodingFailed("Could not create the WAV audio format.")
      }
      return format.settings
    case .m4a, .aac:
      return [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Double(sampleRate),
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: Self.aacBitRate,
      ]
    }
  }
}

public enum AudioFileWriter {
  public static func write(
    samples: [Float],
    sampleRate: Int,
    to url: URL,
    format: AudioOutputFormat
  ) throws {
    guard !samples.isEmpty else {
      throw VoiceEngineError.audioEncodingFailed("No audio samples were generated.")
    }
    // AVAudioFormat accepts a sample rate of zero on current macOS and writes a
    // file no decoder can read, so the rate is checked here rather than left to
    // the format constructor.
    guard sampleRate > 0 else {
      throw VoiceEngineError.audioEncodingFailed(
        "Could not create an audio output buffer at \(sampleRate) Hz.")
    }

    try writeAtomically(to: url, format: format) { temporaryURL in
      try encode(
        samples: samples,
        sampleRate: sampleRate,
        to: temporaryURL,
        format: format
      )
    }
  }

  public static func writeAtomically(
    to destination: URL,
    format: AudioOutputFormat,
    encode: (URL) throws -> Void
  ) throws {
    let temporaryURL = temporaryURL(for: destination, format: format)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    do {
      try encode(temporaryURL)
      try install(temporaryURL, at: destination)
    } catch let error as VoiceEngineError {
      throw error
    } catch {
      throw VoiceEngineError.audioEncodingFailed(error.localizedDescription)
    }
  }

  private static func encode(
    samples: [Float],
    sampleRate: Int,
    to url: URL,
    format: AudioOutputFormat
  ) throws {
    let frameCount = AVAudioFrameCount(samples.count)
    guard
      let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: processingFormat,
        frameCapacity: frameCount
      ),
      let channel = buffer.floatChannelData?[0]
    else {
      throw VoiceEngineError.audioEncodingFailed("Could not create an audio output buffer.")
    }

    buffer.frameLength = frameCount
    samples.withUnsafeBufferPointer { source in
      guard let baseAddress = source.baseAddress else { return }
      channel.update(from: baseAddress, count: samples.count)
    }

    let file = try AVAudioFile(
      forWriting: url,
      settings: try format.settings(sampleRate: sampleRate),
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    try file.write(from: buffer)
  }

  private static func temporaryURL(for destination: URL, format: AudioOutputFormat) -> URL {
    destination.deletingLastPathComponent().appendingPathComponent(
      ".ark-voice-\(UUID().uuidString).\(format.rawValue)"
    )
  }

  private static func install(_ temporaryURL: URL, at destination: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destination)
    }
  }
}

/// Builds WAV bytes for a destination that cannot be seeked, such as a pipe.
///
/// A normal WAV header states the total length up front, which is unknown while
/// synthesis is still running. Writing `0xFFFFFFFF` in both size fields is the
/// long-standing convention for "read until the stream ends"; ffmpeg, afplay,
/// and VLC all accept it. When the total length is known, pass it so the header
/// stays exact for consumers that trust the field.
public struct StreamingWAVEncoder: Sendable {
  public let sampleRate: Int
  public let format: PCMSampleFormat

  private static let unknownSize: UInt32 = 0xFFFF_FFFF

  public init(sampleRate: Int, format: PCMSampleFormat = .f32le) {
    self.sampleRate = sampleRate
    self.format = format
  }

  public func header(totalFrames: Int? = nil) -> Data {
    let bitsPerSample = UInt16(format.bytesPerSample * 8)
    let channels: UInt16 = 1
    let blockAlign = channels * UInt16(format.bytesPerSample)
    let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
    let audioFormat: UInt16 = format == .f32le ? 3 : 1  // 3 = IEEE float, 1 = integer PCM

    let dataSize: UInt32
    let riffSize: UInt32
    if let totalFrames {
      let bytes = UInt32(clamping: totalFrames * Int(blockAlign))
      dataSize = bytes
      riffSize = 36 &+ bytes
    } else {
      dataSize = Self.unknownSize
      riffSize = Self.unknownSize
    }

    var data = Data(capacity: 44)
    data.append(contentsOf: Array("RIFF".utf8))
    data.append(littleEndian: riffSize)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.append(littleEndian: UInt32(16))
    data.append(littleEndian: audioFormat)
    data.append(littleEndian: channels)
    data.append(littleEndian: UInt32(sampleRate))
    data.append(littleEndian: byteRate)
    data.append(littleEndian: blockAlign)
    data.append(littleEndian: bitsPerSample)
    data.append(contentsOf: Array("data".utf8))
    data.append(littleEndian: dataSize)
    return data
  }

  public func body(_ samples: [Float]) -> Data {
    AudioDecoding.data(from: samples, format: format)
  }
}

extension Data {
  fileprivate mutating func append(littleEndian value: UInt32) {
    var value = value.littleEndian
    Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
  }

  fileprivate mutating func append(littleEndian value: UInt16) {
    var value = value.littleEndian
    Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
  }
}
