import Darwin
import Foundation
import MLX
import MLXAudioCodecs
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS

enum VoiceEngineError: LocalizedError {
  case fileNotFound(String)
  case unsupportedAudioFormat(String)
  case emptyText
  case invalidTextEncoding(String)
  case outputMustBeWAV(String)
  case missingMetalLibrary
  case tokenizerUnavailable(String)
  case standardOutputRedirectionFailed

  var errorDescription: String? {
    switch self {
    case .fileNotFound(let path):
      "File not found: \(path)"
    case .unsupportedAudioFormat(let ext):
      "Unsupported audio format '.\(ext)'. Supported inputs: wav, aac, m4a, mp4."
    case .emptyText:
      "Text input is empty."
    case .invalidTextEncoding(let source):
      "Text input is not valid UTF-8: \(source)"
    case .outputMustBeWAV(let path):
      "TTS output must be a .wav file: \(path)"
    case .missingMetalLibrary:
      "MLX's Metal shader library is missing. Build with './Scripts/build-release.sh' and keep mlx.metallib beside the ark-voice executable."
    case .tokenizerUnavailable(let details):
      "Chatterbox's S3 tokenizer could not be loaded: \(details)"
    case .standardOutputRedirectionFailed:
      "Could not redirect model progress output to stderr."
    }
  }
}

enum VoiceEngine {
  private static let supportedAudioExtensions: Set<String> = ["wav", "aac", "m4a", "mp4"]
  private static let maximumTTSChunkCharacters = 300
  private static let silenceBetweenTTSChunksSeconds = 0.15

  static func transcribe(inputPath: String, outputPath: String?) async throws {
    let input = try audioURL(inputPath)
    try requireMLXRuntime()
    let (_, audio) = try loadAudioArray(from: input, sampleRate: 16_000)
    try ModelStore.requireDownloaded([ModelStore.parakeet])

    let model = try ParakeetModel.fromDirectory(
      ModelStore.modelDirectory(for: ModelStore.parakeet)
    )
    let parameters = STTGenerateParameters(language: "English")
    let result = model.generate(audio: audio, generationParameters: parameters)
    let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

    if let outputPath {
      let output = resolvedURL(outputPath)
      try createParentDirectory(for: output)
      try (transcript + "\n").write(to: output, atomically: true, encoding: .utf8)
      writeStandardError("Transcript written to \(output.path)\n")
    } else {
      print(transcript)
    }
  }

  static func speak(
    textSource: TextSource,
    outputPath: String,
    referencePath: String?,
    voiceName: String? = nil
  ) async throws {
    let text = try readText(textSource).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw VoiceEngineError.emptyText }

    let output = resolvedURL(outputPath)
    guard output.pathExtension.lowercased() == "wav" else {
      throw VoiceEngineError.outputMustBeWAV(output.path)
    }
    try requireMLXRuntime()

    let referenceAudio: MLXArray?
    if let referencePath {
      let reference = try audioURL(referencePath)
      (_, referenceAudio) = try loadAudioArray(from: reference, sampleRate: 24_000)
    } else {
      referenceAudio = nil
    }

    try ModelStore.requireDownloaded([ModelStore.chatterbox, ModelStore.s3Tokenizer])

    let chunks = chunkText(text, maximumCharacters: maximumTTSChunkCharacters)
    let (audioSamples, sampleRate) = try await withStandardOutputRedirectedToStandardError {
      let model = try await loadChatterboxModel()
      if let voiceName {
        model.defaultConditioning = try VoiceStore.load(name: voiceName)
      } else if let referenceAudio {
        model.defaultConditioning = try model.prepareConditioning(refAudio: referenceAudio)
      }

      var samples = [Float]()
      let silenceSampleCount = Int(Double(model.sampleRate) * silenceBetweenTTSChunksSeconds)
      for (index, chunk) in chunks.enumerated() {
        try Task.checkCancellation()
        if chunks.count > 1 {
          print(
            "Generating speech chunk \(index + 1)/\(chunks.count) "
              + "(\(chunk.count) characters)..."
          )
        }
        let generated = try await model.generate(
          text: chunk,
          voice: nil,
          refAudio: nil,
          refText: nil,
          language: "English",
          generationParameters: model.defaultGenerationParameters
        )
        if index > 0 {
          samples.append(contentsOf: repeatElement(0, count: silenceSampleCount))
        }
        samples.append(contentsOf: generated.asArray(Float.self))
      }
      return (samples, model.sampleRate)
    }

    try createParentDirectory(for: output)
    try AudioUtils.writeWavFile(
      samples: audioSamples,
      sampleRate: sampleRate,
      fileURL: output
    )
    print(output.path)
  }

  static func createVoice(name: String, referencePath: String) async throws {
    try VoiceStore.requireAvailable(name: name)
    let reference = try audioURL(referencePath)
    try requireMLXRuntime()
    let (_, referenceAudio) = try loadAudioArray(from: reference, sampleRate: 24_000)
    try ModelStore.requireDownloaded([ModelStore.chatterbox, ModelStore.s3Tokenizer])

    let profile = try await withStandardOutputRedirectedToStandardError {
      let model = try await loadChatterboxModel()
      return try model.prepareConditioning(refAudio: referenceAudio)
    }
    let url = try VoiceStore.save(profile, name: name)
    print(url.path)
  }

  private static func loadChatterboxModel() async throws -> ChatterboxModel {
    let model = try await ChatterboxModel.fromModelDirectory(
      ModelStore.modelDirectory(for: ModelStore.chatterbox),
      hfToken: ProcessInfo.processInfo.environment["HF_TOKEN"]
    )
    model.s3Tokenizer = try loadS3Tokenizer(
      from: ModelStore.modelDirectory(for: ModelStore.s3Tokenizer)
    )
    return model
  }

  static func readText(_ source: TextSource) throws -> String {
    switch source {
    case .literal(let text):
      return text
    case .file(let path):
      let url = resolvedURL(path)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw VoiceEngineError.fileNotFound(url.path)
      }
      return try decodeUTF8(Data(contentsOf: url), source: url.path)
    case .standardInput:
      let data = FileHandle.standardInput.readDataToEndOfFile()
      return try decodeUTF8(data, source: "stdin")
    }
  }

  static func decodeUTF8(_ data: Data, source: String) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      throw VoiceEngineError.invalidTextEncoding(source)
    }
    return text
  }

  /// Splits long-form input into model-sized chunks, preferring sentence and word boundaries.
  static func chunkText(_ text: String, maximumCharacters: Int = maximumTTSChunkCharacters)
    -> [String]
  {
    precondition(maximumCharacters > 0)
    let normalized = text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    guard !normalized.isEmpty else { return [] }

    var chunks = [String]()
    var currentChunk = ""

    func appendPiece(_ piece: String) {
      guard !piece.isEmpty else { return }
      if currentChunk.isEmpty {
        currentChunk = piece
      } else if currentChunk.count + 1 + piece.count <= maximumCharacters {
        currentChunk += " " + piece
      } else {
        chunks.append(currentChunk)
        currentChunk = piece
      }
    }

    func appendWithWordWrapping(_ text: String) {
      guard text.count > maximumCharacters else {
        appendPiece(text)
        return
      }

      var wordChunk = ""
      for wordSubstring in text.split(separator: " ") {
        var word = String(wordSubstring)
        if word.count > maximumCharacters {
          if !wordChunk.isEmpty {
            appendPiece(wordChunk)
            wordChunk = ""
          }
          while word.count > maximumCharacters {
            let end = word.index(word.startIndex, offsetBy: maximumCharacters)
            appendPiece(String(word[..<end]))
            word = String(word[end...])
          }
          wordChunk = word
        } else if wordChunk.isEmpty {
          wordChunk = word
        } else if wordChunk.count + 1 + word.count <= maximumCharacters {
          wordChunk += " " + word
        } else {
          appendPiece(wordChunk)
          wordChunk = word
        }
      }
      appendPiece(wordChunk)
    }

    for sentence in splitIntoSentences(normalized) {
      if sentence.count <= maximumCharacters {
        appendPiece(sentence)
        continue
      }

      for clause in splitAtCommas(sentence) {
        appendWithWordWrapping(clause)
      }
    }

    if !currentChunk.isEmpty {
      chunks.append(currentChunk)
    }
    return chunks
  }

  private static func splitIntoSentences(_ text: String) -> [String] {
    let terminators: Set<Character> = [".", "!", "?"]
    let closingCharacters: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}"]
    var sentences = [String]()
    var sentence = ""
    var hasPendingTerminator = false

    for character in text {
      if character.isWhitespace {
        if hasPendingTerminator {
          sentences.append(sentence)
          sentence = ""
          hasPendingTerminator = false
        } else if !sentence.isEmpty && sentence.last != " " {
          sentence.append(" ")
        }
        continue
      }

      if hasPendingTerminator && !closingCharacters.contains(character) {
        hasPendingTerminator = false
      }
      sentence.append(character)
      if terminators.contains(character) {
        hasPendingTerminator = true
      }
    }

    if !sentence.isEmpty {
      sentences.append(sentence)
    }
    return sentences
  }

  private static func splitAtCommas(_ text: String) -> [String] {
    var clauses = [String]()
    var clause = ""

    for character in text {
      clause.append(character)
      if character == "," {
        clauses.append(clause.trimmingCharacters(in: .whitespaces))
        clause = ""
      }
    }

    let remainder = clause.trimmingCharacters(in: .whitespaces)
    if !remainder.isEmpty {
      clauses.append(remainder)
    }
    return clauses
  }

  static func loadS3Tokenizer(from directory: URL) throws -> S3TokenizerV2 {
    do {
      return try S3TokenizerV2.fromModelDirectory(directory)
    } catch {
      throw VoiceEngineError.tokenizerUnavailable(error.localizedDescription)
    }
  }

  static func audioURL(_ path: String) throws -> URL {
    let url = resolvedURL(path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw VoiceEngineError.fileNotFound(url.path)
    }
    let ext = url.pathExtension.lowercased()
    guard supportedAudioExtensions.contains(ext) else {
      throw VoiceEngineError.unsupportedAudioFormat(ext)
    }
    return url
  }

  static func createParentDirectory(for url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }

  static func requireMLXRuntime(executableURL: URL? = nil) throws {
    let executable =
      executableURL
      ?? Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidates = mlxRuntimeCandidates(for: executable)
    guard candidates.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
      throw VoiceEngineError.missingMetalLibrary
    }
  }

  static func mlxRuntimeCandidates(for executable: URL) -> [URL] {
    let invocationDirectory = executable.standardizedFileURL.deletingLastPathComponent()
    let resolvedDirectory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
    var directories = [resolvedDirectory]
    if invocationDirectory != resolvedDirectory {
      directories.append(invocationDirectory)
    }

    return directories.flatMap { directory in
      [
        directory.appendingPathComponent("mlx.metallib"),
        directory.appendingPathComponent("Resources/mlx.metallib"),
        directory.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib"),
      ]
    }
  }

  static func withStandardOutputRedirectedToStandardError<T>(
    _ operation: () async throws -> T
  ) async throws -> T {
    fflush(nil)
    let savedStandardOutput = dup(STDOUT_FILENO)
    guard savedStandardOutput >= 0 else {
      throw VoiceEngineError.standardOutputRedirectionFailed
    }
    guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
      close(savedStandardOutput)
      throw VoiceEngineError.standardOutputRedirectionFailed
    }

    func restoreStandardOutput() {
      fflush(nil)
      _ = dup2(savedStandardOutput, STDOUT_FILENO)
      close(savedStandardOutput)
    }

    do {
      let result = try await operation()
      restoreStandardOutput()
      return result
    } catch {
      restoreStandardOutput()
      throw error
    }
  }
}

func resolvedURL(_ path: String) -> URL {
  let expanded = NSString(string: path).expandingTildeInPath
  if expanded.hasPrefix("/") {
    return URL(fileURLWithPath: expanded).standardizedFileURL
  }
  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(expanded)
    .standardizedFileURL
}

func writeStandardError(_ text: String) {
  FileHandle.standardError.write(Data(text.utf8))
}
