import AudioToolbox
import AVFoundation
import Foundation

enum AudioOutputFormat: String, CaseIterable, Sendable {
  case wav
  case m4a
  case aac

  static let aacBitRate = 48_000

  static var supportedExtensionsDescription: String {
    allCases.map { $0.rawValue }.joined(separator: ", ")
  }

  init?(url: URL) {
    self.init(rawValue: url.pathExtension.lowercased())
  }

  func settings(sampleRate: Int) throws -> [String: Any] {
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

enum AudioFileWriter {
  static func write(
    samples: [Float],
    sampleRate: Int,
    to url: URL,
    format: AudioOutputFormat
  ) throws {
    guard !samples.isEmpty else {
      throw VoiceEngineError.audioEncodingFailed("No audio samples were generated.")
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

  static func writeAtomically(
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
