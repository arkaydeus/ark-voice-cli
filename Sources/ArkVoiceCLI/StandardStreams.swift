import ArkVoiceKit
import Darwin
import Foundation

/// Writes to the process's own streams.
///
/// Streaming audio makes stdout a data channel, so text written there has to go
/// through the same file handle as the audio: mixing buffered `print` with
/// direct writes would interleave them in the wrong order.
func writeStandardError(_ text: String) {
  FileHandle.standardError.write(Data(text.utf8))
}

func writeStandardOutput(_ data: Data) {
  FileHandle.standardOutput.write(data)
}

func writeStandardOutput(_ text: String) {
  writeStandardOutput(Data(text.utf8))
}

func readStandardInput() -> Data {
  FileHandle.standardInput.readDataToEndOfFile()
}

/// Reads the text a `tts` request should speak.
func readText(_ source: TextSource) throws -> String {
  switch source {
  case .literal(let text):
    return text
  case .file(let path):
    let url = resolvedURL(path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw VoiceEngineError.fileNotFound(url.path)
    }
    return try VoiceEngine.decodeUTF8(Data(contentsOf: url), source: url.path)
  case .standardInput:
    return try VoiceEngine.decodeUTF8(readStandardInput(), source: "stdin")
  }
}

/// Decodes transcription input to mono samples at the rate the recognizer wants.
func readTranscriptionSamples(_ options: TranscribeOptions) throws -> [Float] {
  switch options.input {
  case .file(let path):
    return try AudioDecoding.decodeFile(
      at: try VoiceEngine.audioURL(path),
      sampleRate: VoiceSession.transcriptionSampleRate
    )
  case .standardInput:
    let data = readStandardInput()
    guard !data.isEmpty else {
      throw VoiceEngineError.audioDecodingFailed("No audio arrived on stdin.")
    }
    if let format = options.inputFormat {
      let samples = try AudioDecoding.samples(from: data, format: format)
      return try AudioDecoding.resample(
        samples,
        from: options.inputSampleRate,
        to: VoiceSession.transcriptionSampleRate
      )
    }
    guard let container = AudioDecoding.containerExtension(for: data) else {
      throw VoiceEngineError.audioDecodingFailed(
        "Could not recognize the audio on stdin. Pass --input-format \(PCMSampleFormat.optionsDescription) for headerless PCM."
      )
    }
    return try AudioDecoding.decodeContainerData(
      data,
      fileExtension: container,
      sampleRate: VoiceSession.transcriptionSampleRate
    )
  }
}

/// Reads reference audio for voice cloning at the synthesis rate.
func readReferenceSamples(path: String) throws -> [Float] {
  try AudioDecoding.decodeFile(
    at: try VoiceEngine.audioURL(path),
    sampleRate: VoiceSession.synthesisSampleRate
  )
}

/// Renders kit progress for a terminal.
///
/// Diagnostics go to stderr unconditionally: stdout may be carrying audio.
func reportProgress(_ event: ProgressEvent) {
  switch event {
  case .message(let text):
    writeStandardError(text + "\n")
  case .modelDownloadStarted(let model):
    writeStandardError("Downloading \(model)...\n")
  case .modelDownloadProgress(let model, let completed, let total):
    writeStandardError("\(model): \(completed)/\(total) bytes\n")
  case .modelDownloadFinished(let model, let directory):
    writeStandardError("\(model) ready at \(directory.path)\n")
  case .modelLoadStarted(let model):
    writeStandardError("Loading \(model)...\n")
  case .modelLoadFinished(let model):
    writeStandardError("Loaded \(model).\n")
  case .modelsUnloaded:
    writeStandardError("Released resident models.\n")
  case .synthesisChunkStarted(let index, let count, let characters):
    guard count > 1 else { return }
    writeStandardError(
      "Generating speech chunk \(index + 1)/\(count) (\(characters) characters)...\n")
  }
}
