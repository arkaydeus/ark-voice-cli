import Foundation
import Testing

@testable import ArkVoiceCLI

@Suite struct VoiceEngineTests {
  @Test func strictUTF8Decoding() throws {
    #expect(try VoiceEngine.decodeUTF8(Data("hello".utf8), source: "test") == "hello")
    let error = #expect(throws: VoiceEngineError.self) {
      try VoiceEngine.decodeUTF8(Data([0xff, 0xfe]), source: "stdin")
    }
    #expect(error?.localizedDescription == "Text input is not valid UTF-8: stdin")
  }

  @Test func shortTTSInputRemainsOneChunk() {
    #expect(
      VoiceEngine.chunkText("  Hello,\nworld.  This is a test. ")
        == ["Hello, world. This is a test."]
    )
  }

  @Test func longTTSInputUsesSentenceBoundariesAndHonorsLimit() {
    let text = "One short sentence. Two is also short! Is three short? Four finishes."
    let chunks = VoiceEngine.chunkText(text, maximumCharacters: 35)

    #expect(
      chunks == ["One short sentence.", "Two is also short! Is three short?", "Four finishes."]
    )
    #expect(chunks.allSatisfy { $0.count <= 35 })
    #expect(chunks.joined(separator: " ") == text)
  }

  @Test func oversizedSentencesSplitAtWordsAndOversizedWordsSplitExactly() {
    let sentence = "alpha beta gamma delta epsilon zeta eta theta."
    let sentenceChunks = VoiceEngine.chunkText(sentence, maximumCharacters: 18)
    #expect(sentenceChunks.allSatisfy { $0.count <= 18 })
    #expect(sentenceChunks.joined(separator: " ") == sentence)

    let longWord = "abcdefghijklmnopqrstuvwxyz"
    let wordChunks = VoiceEngine.chunkText(longWord, maximumCharacters: 10)
    #expect(wordChunks == ["abcdefghij", "klmnopqrst", "uvwxyz"])
  }

  @Test func oversizedSentencesPreferCommaBoundaries() {
    let text = "Alpha beta gamma, delta epsilon zeta, eta theta."
    let chunks = VoiceEngine.chunkText(text, maximumCharacters: 20)

    #expect(chunks == ["Alpha beta gamma,", "delta epsilon zeta,", "eta theta."])
    #expect(chunks.allSatisfy { $0.count <= 20 })
    #expect(chunks.joined(separator: " ") == text)
  }

  @Test func missingS3TokenizerFailsInsteadOfFallingBack() {
    let directory = temporaryDirectory()
    let error = #expect(throws: VoiceEngineError.self) {
      try VoiceEngine.loadS3Tokenizer(from: directory)
    }
    #expect(error?.localizedDescription.contains("S3 tokenizer could not be loaded") == true)
  }

  @Test func synthesisRejectsEmptyTextAndNonWAVOutputBeforeInference() async {
    let emptyError = await #expect(throws: VoiceEngineError.self) {
      try await VoiceEngine.speak(
        textSource: .literal(" \n "),
        outputPath: "/tmp/unused.wav",
        referencePath: nil
      )
    }
    #expect(emptyError?.localizedDescription == "Text input is empty.")

    let outputError = await #expect(throws: VoiceEngineError.self) {
      try await VoiceEngine.speak(
        textSource: .literal("hello"),
        outputPath: "/tmp/unused.mp3",
        referencePath: nil
      )
    }
    #expect(outputError?.localizedDescription.contains("must be a .wav file") == true)
  }

  @Test func textFileReadingRejectsMissingAndMalformedFiles() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let valid = directory.appendingPathComponent("valid.txt")
    try Data("words".utf8).write(to: valid)
    #expect(try VoiceEngine.readText(.file(valid.path)) == "words")

    let invalid = directory.appendingPathComponent("invalid.txt")
    try Data([0xff]).write(to: invalid)
    #expect(throws: (any Error).self) { try VoiceEngine.readText(.file(invalid.path)) }
    #expect(throws: (any Error).self) {
      try VoiceEngine.readText(.file(directory.appendingPathComponent("missing.txt").path))
    }
  }

  @Test func audioPathValidation() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    for ext in ["wav", "AAC", "m4a", "mp4"] {
      let file = directory.appendingPathComponent("audio.\(ext)")
      #expect(FileManager.default.createFile(atPath: file.path, contents: Data([0])))
      #expect(try VoiceEngine.audioURL(file.path).standardizedFileURL == file.standardizedFileURL)
    }

    let unsupported = directory.appendingPathComponent("audio.mp3")
    #expect(FileManager.default.createFile(atPath: unsupported.path, contents: Data([0])))
    #expect(throws: (any Error).self) { try VoiceEngine.audioURL(unsupported.path) }
    #expect(throws: (any Error).self) {
      try VoiceEngine.audioURL(directory.appendingPathComponent("missing.wav").path)
    }
  }

  @Test func parentDirectoryCreation() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("nested/path/output.wav")

    try VoiceEngine.createParentDirectory(for: output)
    var isDirectory: ObjCBool = false
    #expect(
      FileManager.default.fileExists(
        atPath: output.deletingLastPathComponent().path,
        isDirectory: &isDirectory
      )
    )
    #expect(isDirectory.boolValue)
  }

  @Test func resolvedURLHandlesAbsoluteRelativeAndTildePaths() {
    let absolute = resolvedURL("/tmp/../tmp/example")
    #expect(absolute.path == "/tmp/example")

    let relative = resolvedURL("nested/file.txt")
    #expect(
      relative.path
        == URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("nested/file.txt").standardizedFileURL.path
    )

    #expect(
      resolvedURL("~/file.txt").path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
    )
  }

  @Test func metalRuntimeLookupIncludesResolvedSymlinkDirectory() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let realDirectory = directory.appendingPathComponent("libexec", isDirectory: true)
    let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

    let executable = realDirectory.appendingPathComponent("ark-voice")
    let symlink = binDirectory.appendingPathComponent("ark-voice")
    let metallib = realDirectory.appendingPathComponent("mlx.metallib")
    #expect(FileManager.default.createFile(atPath: executable.path, contents: Data([0])))
    #expect(FileManager.default.createFile(atPath: metallib.path, contents: Data([0])))
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)

    #expect(VoiceEngine.mlxRuntimeCandidates(for: symlink).contains(metallib))
    try VoiceEngine.requireMLXRuntime(executableURL: symlink)
  }

  @Test func metalRuntimeLookupChecksResourceLayoutsAndReportsMissingRuntime() {
    let executable = URL(fileURLWithPath: "/tmp/ark-voice")
    let candidates = VoiceEngine.mlxRuntimeCandidates(for: executable)
    #expect(candidates.contains(URL(fileURLWithPath: "/tmp/mlx.metallib")))
    #expect(candidates.contains(URL(fileURLWithPath: "/tmp/Resources/mlx.metallib")))
    #expect(
      candidates.contains(URL(fileURLWithPath: "/tmp/mlx-swift_Cmlx.bundle/default.metallib"))
    )
    #expect(throws: VoiceEngineError.self) {
      try VoiceEngine.requireMLXRuntime(executableURL: executable)
    }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ark-voice-engine-tests-\(UUID().uuidString)", isDirectory: true)
  }
}
