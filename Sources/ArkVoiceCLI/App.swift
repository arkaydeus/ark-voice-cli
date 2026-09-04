import Darwin
import Foundation

private let version = "0.1.0"

private let usage = """
  ark-voice — local English speech on Apple Silicon

  USAGE
    ark-voice download [all|stt|tts]
    ark-voice stt <audio> [--output transcript.txt]
    ark-voice tts [--] <text> [--output speech.{wav,m4a,aac}] [--reference voice.wav|--voice name]
    ark-voice tts --file <text-file|-> [--output speech.{wav,m4a,aac}] [--reference voice.wav|--voice name]
    ark-voice voice create <name> <reference-audio>
    ark-voice voices
    ark-voice models

  COMMANDS
    download    Download models to ~/.ark-voice-cli (both models by default)
    stt         Transcribe English audio; accepts wav, aac, m4a, and mp4
    tts         Synthesize English speech to WAV, M4A, or ADTS AAC
    voice       Create a reusable voice profile from reference audio
    voices      List saved voice profiles
    models      Show the configured models and local download status

  ALIASES
    transcribe  Alias for stt
    speak       Alias for tts

  ENVIRONMENT
    HF_TOKEN    Optional Hugging Face token

  EXAMPLES
    ark-voice download
    ark-voice stt meeting.m4a
    ark-voice stt clip.mp4 -o transcript.txt
    ark-voice tts "Hello from my Mac" -o hello.wav
    ark-voice tts -- "-5 degrees outside" -o weather.wav
    printf 'Read this aloud' | ark-voice tts --file - -o stdin.wav
    ark-voice tts "Cloned voice" --reference speaker.aac -o clone.wav
    ark-voice voice create narrator speaker.aac
    ark-voice tts "Cached voice" --voice narrator -o cached.wav
  """

@main
enum ArkVoiceApp {
  static func main() async {
    ModelStore.configureEnvironment()

    do {
      let command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
      try await run(command)
    } catch let error as CLIParseError {
      writeStandardError("Error: \(error.localizedDescription)\n\n\(usage)\n")
      exit(2)
    } catch {
      writeStandardError("Error: \(error.localizedDescription)\n")
      exit(1)
    }
  }

  private static func run(_ command: Command) async throws {
    switch command {
    case .help:
      print(usage)
    case .version:
      print("ark-voice \(version)")
    case .models:
      print("Model directory: \(ModelStore.root.path)")
      for model in ModelStore.all {
        let status = ModelStore.isDownloaded(model) ? "downloaded" : "not downloaded"
        print("\(model.title) [\(status)]")
        print("  \(model.repository) — \(model.purpose)")
      }
    case .voices:
      let names = try VoiceStore.names()
      if names.isEmpty {
        print("No saved voices. Create one with 'ark-voice voice create <name> <audio>'.")
      } else {
        for name in names {
          print(name)
        }
      }
    case .createVoice(let name, let reference):
      try await VoiceEngine.createVoice(name: name, referencePath: reference)
    case .download(let selection):
      let models = ModelStore.selected(selection)
      print("Downloading to \(ModelStore.root.path)")
      try await ModelStore.download(models)
      print("Download complete.")
    case .transcribe(let input, let output):
      try await VoiceEngine.transcribe(inputPath: input, outputPath: output)
    case .speak(let source, let output, let reference, let voice):
      try await VoiceEngine.speak(
        textSource: source,
        outputPath: output,
        referencePath: reference,
        voiceName: voice
      )
    }
  }
}
