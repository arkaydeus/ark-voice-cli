import ArkVoiceKit
import Foundation

/// Delivers synthesized audio to a file or to stdout.
///
/// Streaming to stdout starts writing before synthesis finishes, so playback can
/// begin on the first chunk. File output collects the whole waveform first
/// because the container formats need to know their length.
final class SpeechWriter {
  private enum Destination {
    case file(URL, AudioOutputFormat)
    case streamingWAV(PCMSampleFormat)
    case rawPCM(PCMSampleFormat)
  }

  private let destination: Destination
  private var collected = [Float]()
  private var sampleRate = VoiceSession.synthesisSampleRate
  private var wroteHeader = false

  init(options: SpeakOptions) throws {
    switch options.output {
    case .file(let path):
      let url = resolvedURL(path)
      destination = .file(url, try VoiceEngine.ttsOutputFormat(for: url))
    case .standardOutput:
      destination = options.raw ? .rawPCM(options.sampleFormat) : .streamingWAV(options.sampleFormat)
    }
  }

  /// Describes stdout output on stderr, so a pipeline's other end can be told
  /// what it is about to receive.
  func announce() {
    switch destination {
    case .file:
      break
    case .streamingWAV(let format):
      writeStandardError(
        "Streaming WAV to stdout: \(sampleRate) Hz, mono, \(format.rawValue).\n")
    case .rawPCM(let format):
      writeStandardError(
        "Streaming raw PCM to stdout: rate=\(sampleRate) channels=1 format=\(format.rawValue).\n")
    }
  }

  func write(_ samples: [Float], sampleRate: Int) {
    self.sampleRate = sampleRate
    switch destination {
    case .file:
      collected.append(contentsOf: samples)
    case .streamingWAV(let format):
      if !wroteHeader {
        writeStandardOutput(StreamingWAVEncoder(sampleRate: sampleRate, format: format).header())
        wroteHeader = true
      }
      writeStandardOutput(AudioDecoding.data(from: samples, format: format))
    case .rawPCM(let format):
      writeStandardOutput(AudioDecoding.data(from: samples, format: format))
    }
  }

  func write(_ chunk: AudioChunk) {
    write(chunk.samples, sampleRate: chunk.sampleRate)
  }

  /// Completes the output and returns the path written, if any.
  @discardableResult
  func finish() throws -> String? {
    switch destination {
    case .file(let url, let format):
      try VoiceEngine.createParentDirectory(for: url)
      try AudioFileWriter.write(
        samples: collected,
        sampleRate: sampleRate,
        to: url,
        format: format
      )
      return url.path
    case .streamingWAV(let format):
      if !wroteHeader {
        // Nothing was generated; still emit a valid, empty stream.
        writeStandardOutput(
          StreamingWAVEncoder(sampleRate: sampleRate, format: format).header(totalFrames: 0))
      }
      return nil
    case .rawPCM:
      return nil
    }
  }
}
