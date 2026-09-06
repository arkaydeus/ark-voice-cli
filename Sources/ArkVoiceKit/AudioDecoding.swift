import AVFoundation
import Foundation
import MLXAudioCore

/// Turns container files and raw PCM into the mono `[Float]` buffers the models
/// expect, and back again.
///
/// Decoding deliberately avoids MLX so that a host, a server connection, or a
/// test can prepare audio without a Metal runtime present.
public enum AudioDecoding {
  /// Sample rate Parakeet expects for transcription input.
  public static let transcriptionSampleRate = 16_000
  /// Sample rate Chatterbox produces and expects for reference audio.
  public static let synthesisSampleRate = 24_000

  /// Decodes any AVFoundation-readable file to mono samples at `sampleRate`.
  ///
  /// Multi-channel input is averaged down to mono rather than taking the first
  /// channel, so one-sided stereo recordings do not come back silent.
  public static func decodeFile(at url: URL, sampleRate: Int) throws -> [Float] {
    guard sampleRate > 0 else { throw VoiceEngineError.invalidSampleRate(sampleRate) }

    let mono: [Float]
    let sourceSampleRate: Int
    do {
      let file = try AVAudioFile(forReading: url)
      let format = file.processingFormat
      sourceSampleRate = Int(format.sampleRate)
      let frameCount = AVAudioFrameCount(file.length)
      guard frameCount > 0 else { return [] }
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw VoiceEngineError.audioDecodingFailed("Could not allocate a decoding buffer.")
      }
      try file.read(into: buffer)
      guard let channels = buffer.floatChannelData else {
        throw VoiceEngineError.audioDecodingFailed("Decoded audio has no float samples.")
      }

      let frames = Int(buffer.frameLength)
      let channelCount = Int(format.channelCount)
      if channelCount == 1 {
        mono = Array(UnsafeBufferPointer(start: channels[0], count: frames))
      } else {
        var mixed = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
          let samples = channels[channel]
          for frame in 0..<frames {
            mixed[frame] += samples[frame]
          }
        }
        let scale = 1 / Float(channelCount)
        for frame in 0..<frames {
          mixed[frame] *= scale
        }
        mono = mixed
      }
    } catch let error as VoiceEngineError {
      throw error
    } catch {
      throw VoiceEngineError.audioDecodingFailed(error.localizedDescription)
    }

    return try resample(mono, from: sourceSampleRate, to: sampleRate)
  }

  /// Decodes container bytes that did not arrive as a file.
  ///
  /// AVFoundation cannot read a pipe, so the bytes are staged in a temporary
  /// file. `fileExtension` tells the decoder which container to expect.
  public static func decodeContainerData(
    _ data: Data,
    fileExtension: String,
    sampleRate: Int
  ) throws -> [Float] {
    let staged = FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-input-\(UUID().uuidString).\(fileExtension)")
    defer { try? FileManager.default.removeItem(at: staged) }
    do {
      try data.write(to: staged, options: .atomic)
    } catch {
      throw VoiceEngineError.audioDecodingFailed(error.localizedDescription)
    }
    return try decodeFile(at: staged, sampleRate: sampleRate)
  }

  /// Guesses a container from leading bytes, for audio that arrived without a
  /// filename.
  ///
  /// AVFoundation reads files, not pipes, so bytes from stdin have to be staged
  /// with an extension it recognises.
  public static func containerExtension(for data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    guard bytes.count >= 12 else { return nil }
    if bytes[0...3] == [0x52, 0x49, 0x46, 0x46] { return "wav" }  // "RIFF"
    if bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return "m4a" }  // "ftyp"
    if bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return "aac" }  // ADTS
    if bytes[0...2] == [0x49, 0x44, 0x33] { return "aac" }  // "ID3"
    return nil
  }

  public static func resample(_ samples: [Float], from source: Int, to target: Int) throws
    -> [Float]
  {
    guard source > 0 else { throw VoiceEngineError.invalidSampleRate(source) }
    guard target > 0 else { throw VoiceEngineError.invalidSampleRate(target) }
    if source == target || samples.isEmpty { return samples }
    do {
      return try resampleAudio(samples, from: source, to: target)
    } catch {
      throw VoiceEngineError.audioDecodingFailed(
        "Could not resample from \(source) Hz to \(target) Hz.")
    }
  }

  /// Reads interleaved mono PCM bytes into samples.
  public static func samples(from data: Data, format: PCMSampleFormat) throws -> [Float] {
    guard data.count % format.bytesPerSample == 0 else {
      throw VoiceEngineError.malformedSampleData(
        "\(data.count) bytes is not a whole number of \(format.rawValue) samples.")
    }
    let count = data.count / format.bytesPerSample
    guard count > 0 else { return [] }

    switch format {
    case .f32le:
      var samples = [Float](repeating: 0, count: count)
      _ = samples.withUnsafeMutableBytes { destination in
        data.copyBytes(to: destination.bindMemory(to: UInt8.self))
      }
      return samples
    case .s16le:
      return data.withUnsafeBytes { raw -> [Float] in
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
          let low = UInt16(raw[index * 2])
          let high = UInt16(raw[index * 2 + 1])
          let value = Int16(bitPattern: low | (high << 8))
          samples[index] = Float(value) / 32_768
        }
        return samples
      }
    }
  }

  /// Writes samples as interleaved mono PCM bytes.
  ///
  /// `s16le` clamps before conversion, so peaks above full scale distort rather
  /// than wrapping to the opposite polarity.
  public static func data(from samples: [Float], format: PCMSampleFormat) -> Data {
    switch format {
    case .f32le:
      return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    case .s16le:
      var bytes = [UInt8]()
      bytes.reserveCapacity(samples.count * 2)
      for sample in samples {
        let clamped = max(-1, min(1, sample))
        let value = Int16(clamped < 0 ? clamped * 32_768 : clamped * 32_767)
        let pattern = UInt16(bitPattern: value)
        bytes.append(UInt8(pattern & 0xff))
        bytes.append(UInt8(pattern >> 8))
      }
      return Data(bytes)
    }
  }
}
