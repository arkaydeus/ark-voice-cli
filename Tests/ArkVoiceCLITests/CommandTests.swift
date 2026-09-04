import Testing

@testable import ArkVoiceCLI

@Suite struct CommandTests {
  @Test func topLevelCommandsAndAliases() throws {
    #expect(try CLIParser.parse([]) == .help)
    #expect(try CLIParser.parse(["--help"]) == .help)
    #expect(try CLIParser.parse(["version"]) == .version)
    #expect(try CLIParser.parse(["models"]) == .models)
    #expect(try CLIParser.parse(["voices"]) == .voices)
    #expect(
      try CLIParser.parse(["voice", "create", "narrator", "speaker.wav"])
        == .createVoice(name: "narrator", reference: "speaker.wav")
    )
    #expect(try CLIParser.parse(["download"]) == .download(.all))
    #expect(try CLIParser.parse(["download", "stt"]) == .download(.stt))
    #expect(
      try CLIParser.parse(["transcribe", "clip.m4a", "-o", "clip.txt"])
        == .transcribe(input: "clip.m4a", output: "clip.txt")
    )
  }

  @Test func transcribeRejectsInvalidArguments() {
    assertParseError(["stt"], contains: "Usage:")
    assertParseError(["stt", "a.wav", "b.wav"], contains: "exactly one")
    assertParseError(["stt", "a.wav", "-o"], contains: "requires a path")
    assertParseError(
      ["stt", "a.wav", "-o", "a.txt", "--output", "b.txt"],
      contains: "only be supplied once"
    )
    assertParseError(["stt", "--wat"], contains: "Unknown stt option")
  }

  @Test func speakSourcesOptionsAndDefaults() throws {
    #expect(
      try CLIParser.parse(["tts", "hello"])
        == .speak(text: .literal("hello"), output: "speech.wav", reference: nil, voice: nil)
    )
    #expect(
      try CLIParser.parse(["speak", "--file", "-"])
        == .speak(text: .standardInput, output: "speech.wav", reference: nil, voice: nil)
    )
    #expect(
      try CLIParser.parse(["tts", "--file", "words.txt", "-r", "voice.m4a", "-o", "x.wav"])
        == .speak(
          text: .file("words.txt"),
          output: "x.wav",
          reference: "voice.m4a",
          voice: nil
        )
    )
    #expect(
      try CLIParser.parse(["tts", "hello", "--voice", "narrator"])
        == .speak(
          text: .literal("hello"),
          output: "speech.wav",
          reference: nil,
          voice: "narrator"
        )
    )
  }

  @Test func speakAcceptsHyphenatedInlineTextAfterSeparator() throws {
    #expect(
      try CLIParser.parse(["tts", "--", "-5 degrees outside", "-o", "weather.wav"])
        == .speak(
          text: .literal("-5 degrees outside"),
          output: "weather.wav",
          reference: nil,
          voice: nil
        )
    )
  }

  @Test func speakRejectsDuplicateAndConflictingOptions() {
    assertParseError(
      ["tts", "hello", "-o", "a.wav", "--output", "b.wav"],
      contains: "only be supplied once"
    )
    assertParseError(
      ["tts", "--file", "a.txt", "-f", "b.txt"],
      contains: "--file may only"
    )
    assertParseError(
      ["tts", "hello", "--reference", "a.wav", "-r", "b.wav"],
      contains: "--reference may only"
    )
    assertParseError(["tts", "hello", "--file", "a.txt"], contains: "either inline text")
    assertParseError(
      ["tts", "hello", "--reference", "voice.wav", "--voice", "narrator"],
      contains: "either --reference or --voice"
    )
    assertParseError(
      ["tts", "hello", "--voice", "one", "--voice", "two"],
      contains: "--voice may only"
    )
    assertParseError(["tts", "-5 degrees"], contains: "Unknown tts option")
    assertParseError(["tts", "--"], contains: "requires inline text")
    assertParseError(["voice"], contains: "voice create")
    assertParseError(["voice", "remove", "name"], contains: "voice create")
  }

  private func assertParseError(_ arguments: [String], contains expectedText: String) {
    let error = #expect(throws: CLIParseError.self) {
      try CLIParser.parse(arguments)
    }
    #expect(error?.localizedDescription.contains(expectedText) == true)
  }
}
