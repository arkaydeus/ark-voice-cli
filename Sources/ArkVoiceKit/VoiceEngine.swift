import Darwin
import Foundation
import MLXAudioCodecs
import MLXAudioTTS

public enum VoiceEngineError: LocalizedError {
  case fileNotFound(String)
  case unsupportedAudioFormat(String)
  case emptyText
  case invalidTextEncoding(String)
  case unsupportedOutputFormat(String)
  case audioEncodingFailed(String)
  case audioDecodingFailed(String)
  case missingMetalLibrary
  case tokenizerUnavailable(String)
  case invalidSampleRate(Int)
  case malformedSampleData(String)
  case invalidConfiguration(String)

  public var errorDescription: String? {
    switch self {
    case .fileNotFound(let path):
      "File not found: \(path)"
    case .unsupportedAudioFormat(let ext):
      "Unsupported audio format '.\(ext)'. Supported inputs: wav, aac, m4a, mp4."
    case .emptyText:
      "Text input is empty."
    case .invalidTextEncoding(let source):
      "Text input is not valid UTF-8: \(source)"
    case .unsupportedOutputFormat(let path):
      "Unsupported TTS output format: \(path). Supported outputs: \(AudioOutputFormat.supportedExtensionsDescription)."
    case .audioEncodingFailed(let details):
      "Could not encode audio output: \(details)"
    case .audioDecodingFailed(let details):
      "Could not decode audio input: \(details)"
    case .missingMetalLibrary:
      "MLX's Metal shader library is missing. Build with './Scripts/build-release.sh' and keep mlx.metallib beside the ark-voice executable."
    case .tokenizerUnavailable(let details):
      "Chatterbox's S3 tokenizer could not be loaded: \(details)"
    case .invalidSampleRate(let rate):
      "Invalid sample rate: \(rate)."
    case .malformedSampleData(let details):
      "Malformed PCM data: \(details)"
    case .invalidConfiguration(let details):
      "Invalid session configuration: \(details)"
    }
  }
}

/// Pure helpers shared by the session, the CLI, and the server.
///
/// Nothing here loads a model or performs I/O on standard streams; the pieces
/// are separated so they stay testable without downloaded models.
public enum VoiceEngine {
  public static let supportedAudioExtensions: Set<String> = ["wav", "aac", "m4a", "mp4"]
  public static let defaultMaximumChunkCharacters = 300

  public static func ttsOutputFormat(for output: URL) throws -> AudioOutputFormat {
    guard let format = AudioOutputFormat(url: output) else {
      throw VoiceEngineError.unsupportedOutputFormat(output.path)
    }
    return format
  }

  public static func decodeUTF8(_ data: Data, source: String) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      throw VoiceEngineError.invalidTextEncoding(source)
    }
    return text
  }

  /// Splits long-form input into model-sized chunks, preferring sentence and word boundaries.
  public static func chunkText(
    _ text: String,
    maximumCharacters: Int = defaultMaximumChunkCharacters
  ) -> [String] {
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

  public static func loadS3Tokenizer(from directory: URL) throws -> S3TokenizerV2 {
    do {
      return try S3TokenizerV2.fromModelDirectory(directory)
    } catch {
      throw VoiceEngineError.tokenizerUnavailable(error.localizedDescription)
    }
  }

  public static func audioURL(_ path: String) throws -> URL {
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

  public static func createParentDirectory(for url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }

  /// Confirms MLX's Metal shader library is reachable before any model runs.
  ///
  /// `explicitURL` lets an embedding host name its bundled copy; otherwise the
  /// library is looked for beside the executable.
  public static func requireMLXRuntime(
    executableURL: URL? = nil,
    explicitURL: URL? = nil
  ) throws {
    if let explicitURL, FileManager.default.fileExists(atPath: explicitURL.path) {
      return
    }
    let executable =
      executableURL
      ?? Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidates = mlxRuntimeCandidates(for: executable)
    guard candidates.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
      throw VoiceEngineError.missingMetalLibrary
    }
  }

  public static func mlxRuntimeCandidates(for executable: URL) -> [URL] {
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
}

/// Expands `~` and resolves relative paths against the current directory.
public func resolvedURL(_ path: String) -> URL {
  let expanded = NSString(string: path).expandingTildeInPath
  if expanded.hasPrefix("/") {
    return URL(fileURLWithPath: expanded).standardizedFileURL
  }
  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(expanded)
    .standardizedFileURL
}
