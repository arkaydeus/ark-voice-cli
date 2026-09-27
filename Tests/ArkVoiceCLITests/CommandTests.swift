import ArkVoiceKit
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
        == .transcribe(TranscribeOptions(input: .file("clip.m4a"), output: "clip.txt"))
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
    assertParseError(["stt", "-", "--input-format", "mp3"], contains: "Unknown --input-format")
    assertParseError(["stt", "-", "--input-rate", "0"], contains: "positive sample rate")
    assertParseError(
      ["stt", "clip.wav", "--input-format", "s16le"],
      contains: "only applies when reading audio from stdin"
    )
  }

  @Test func transcribeAcceptsStreamingStdinInput() throws {
    #expect(
      try CLIParser.parse(["stt", "-", "--input-format", "s16le", "--input-rate", "24000"])
        == .transcribe(
          TranscribeOptions(
            input: .standardInput,
            inputFormat: .s16le,
            inputSampleRate: 24_000
          )
        )
    )
    #expect(
      try CLIParser.parse(["stt", "clip.wav", "--stream"])
        == .transcribe(TranscribeOptions(input: .file("clip.wav"), stream: true))
    )
  }

  @Test func transcribeSelectsARecognizer() throws {
    #expect(
      try CLIParser.parse(["stt", "clip.wav", "--model", "parakeet-ultra"])
        == .transcribe(TranscribeOptions(input: .file("clip.wav"), model: .parakeetUltra))
    )
    #expect(
      try CLIParser.parse(["stt", "-m", "qwen", "clip.wav", "-o", "clip.txt"])
        == .transcribe(TranscribeOptions(input: .file("clip.wav"), output: "clip.txt", model: .qwen))
    )
    #expect(
      try CLIParser.parse(["stt", "clip.wav"])
        == .transcribe(TranscribeOptions(input: .file("clip.wav"), model: nil))
    )
    assertParseError(["stt", "clip.wav", "--model", "whisper"], contains: "Unknown --model 'whisper'")
    assertParseError(["stt", "clip.wav", "--model"], contains: "--model requires one of")
  }

  @Test func downloadAcceptsEachRecognizerByName() throws {
    #expect(try CLIParser.parse(["download", "parakeet-ultra"]) == .download(.parakeetUltra))
    #expect(try CLIParser.parse(["download", "qwen"]) == .download(.qwen))
    #expect(try CLIParser.parse(["download", "parakeet"]) == .download(.parakeet))
    assertParseError(["download", "whisper"], contains: "parakeet-ultra")
  }

  @Test func speakSourcesOptionsAndDefaults() throws {
    #expect(
      try CLIParser.parse(["tts", "hello"]) == .speak(SpeakOptions(text: .literal("hello")))
    )
    #expect(
      try CLIParser.parse(["speak", "--file", "-"]) == .speak(SpeakOptions(text: .standardInput))
    )
    #expect(
      try CLIParser.parse(["tts", "--file", "words.txt", "-r", "voice.m4a", "-o", "x.wav"])
        == .speak(
          SpeakOptions(
            text: .file("words.txt"),
            output: .file("x.wav"),
            reference: "voice.m4a"
          )
        )
    )
    #expect(
      try CLIParser.parse(["tts", "hello", "--voice", "narrator"])
        == .speak(SpeakOptions(text: .literal("hello"), voice: "narrator"))
    )
  }

  @Test func speakStreamsToStandardOutput() throws {
    #expect(
      try CLIParser.parse(["tts", "hello", "-o", "-"])
        == .speak(SpeakOptions(text: .literal("hello"), output: .standardOutput))
    )
    #expect(
      try CLIParser.parse(["tts", "hello", "-o", "-", "--raw", "--format", "s16le"])
        == .speak(
          SpeakOptions(
            text: .literal("hello"),
            output: .standardOutput,
            raw: true,
            sampleFormat: .s16le
          )
        )
    )
    assertParseError(
      ["tts", "hello", "-o", "out.wav", "--raw"],
      contains: "only apply when streaming to stdout"
    )
    assertParseError(["tts", "hello", "-o", "-", "--format", "mp3"], contains: "Unknown --format")
  }

  @Test func speakAcceptsHyphenatedInlineTextAfterSeparator() throws {
    #expect(
      try CLIParser.parse(["tts", "--", "-5 degrees outside", "-o", "weather.wav"])
        == .speak(
          SpeakOptions(text: .literal("-5 degrees outside"), output: .file("weather.wav"))
        )
    )
  }

  @Test func speakRejectsDuplicateAndConflictingOptions() {
    assertParseError(
      ["tts", "hello", "-o", "a.wav", "--output", "b.wav"],
      contains: "only be supplied once"
    )
    assertParseError(["tts", "--file", "a.txt", "-f", "b.txt"], contains: "--file may only")
    assertParseError(
      ["tts", "hello", "--reference", "a.wav", "-r", "b.wav"],
      contains: "--reference may only"
    )
    assertParseError(["tts", "hello", "--file", "a.txt"], contains: "either inline text")
    assertParseError(
      ["tts", "hello", "--reference", "voice.wav", "--voice", "narrator"],
      contains: "either --reference or --voice"
    )
    assertParseError(["tts", "hello", "--voice", "one", "--voice", "two"], contains: "--voice may only")
    assertParseError(["tts", "-5 degrees"], contains: "Unknown tts option")
    assertParseError(["tts", "--"], contains: "requires inline text")
    assertParseError(["voice"], contains: "voice create")
    assertParseError(["voice", "remove", "name"], contains: "voice create")
  }

  @Test func serveOptionsAndDefaults() throws {
    #expect(try CLIParser.parse(["serve"]) == .serve(ServeOptions()))
    #expect(
      try CLIParser.parse(["serve", "--socket", "/tmp/a.sock", "--idle-unload", "60"])
        == .serve(ServeOptions(socketPath: "/tmp/a.sock", idleUnloadSeconds: 60))
    )
    #expect(
      try CLIParser.parse(["serve", "--idle-unload", "off", "--idle-exit", "900"])
        == .serve(ServeOptions(idleUnloadSeconds: nil, idleExitSeconds: 900))
    )
    #expect(
      try CLIParser.parse(["serve", "--stt-model", "parakeet-ultra"])
        == .serve(ServeOptions(transcriptionModel: .parakeetUltra))
    )
    assertParseError(["serve", "--stt-model", "tiny"], contains: "Unknown --stt-model")
    assertParseError(["serve", "--idle-exit", "-3"], contains: "positive number of seconds")
    assertParseError(["serve", "--nope"], contains: "Unknown serve option")
  }

  @Test func clientSubcommandsCarrySocketAndRequest() throws {
    #expect(
      try CLIParser.parse(["client", "tts", "hello", "--socket", "/tmp/a.sock"])
        == .client(.tts(SpeakOptions(text: .literal("hello")), socketPath: "/tmp/a.sock"))
    )
    #expect(
      try CLIParser.parse(["client", "stt", "clip.wav"])
        == .client(.stt(TranscribeOptions(input: .file("clip.wav")), socketPath: nil))
    )
    #expect(
      try CLIParser.parse(["client", "stt", "clip.wav", "--model", "qwen", "-s", "/tmp/a.sock"])
        == .client(
          .stt(TranscribeOptions(input: .file("clip.wav"), model: .qwen), socketPath: "/tmp/a.sock"))
    )
    #expect(try CLIParser.parse(["client", "status"]) == .client(.status(socketPath: nil)))
    #expect(try CLIParser.parse(["client", "unload"]) == .client(.unload(socketPath: nil)))
    #expect(try CLIParser.parse(["client", "voices"]) == .client(.voices(socketPath: nil)))
    assertParseError(["client"], contains: "Usage: ark-voice client")
    assertParseError(["client", "sing"], contains: "Unknown client subcommand")
    assertParseError(["client", "status", "extra"], contains: "does not accept arguments")
  }

  @Test func clientStopsSocketOptionParsingAtTheSeparator() throws {
    #expect(
      try CLIParser.parse(["client", "tts", "--", "--socket"])
        == .client(.tts(SpeakOptions(text: .literal("--socket")), socketPath: nil))
    )
    #expect(
      try CLIParser.parse(["client", "tts", "--", "-s"])
        == .client(.tts(SpeakOptions(text: .literal("-s")), socketPath: nil))
    )
  }

  private func assertParseError(_ arguments: [String], contains expectedText: String) {
    let error = #expect(throws: CLIParseError.self) {
      try CLIParser.parse(arguments)
    }
    #expect(error?.localizedDescription.contains(expectedText) == true)
  }
}
