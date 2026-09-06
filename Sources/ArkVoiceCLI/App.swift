import ArkVoiceKit
import Darwin
import Foundation

let arkVoiceVersion = "0.2.0"

let usage = """
  ark-voice — local English speech on Apple Silicon

  USAGE
    ark-voice download [all|stt|tts]
    ark-voice stt <audio|-> [--output transcript.txt] [--stream]
    ark-voice tts [--] <text> [--output speech.{wav,m4a,aac}|-] [--reference voice.wav|--voice name]
    ark-voice tts --file <text-file|-> [--output speech.{wav,m4a,aac}|-]
    ark-voice voice create <name> <reference-audio>
    ark-voice voices
    ark-voice models
    ark-voice serve [--socket path] [--idle-unload seconds|off] [--idle-exit seconds|off]
    ark-voice client <tts|stt|voices|status|unload> [--socket path] ...

  COMMANDS
    download    Download models to ~/.ark-voice-cli (both models by default)
    stt         Transcribe English audio; accepts wav, aac, m4a, mp4, or stdin
    tts         Synthesize English speech to WAV, M4A, ADTS AAC, or stdout
    voice       Create a reusable voice profile from reference audio
    voices      List saved voice profiles
    models      Show the configured models and local download status
    serve       Keep models resident and serve requests over a Unix socket
    client      Run a request against a server started with 'ark-voice serve'

  ALIASES
    transcribe  Alias for stt
    speak       Alias for tts

  STREAMING
    --output -        Write audio to stdout as it is generated, as a WAV stream
    --raw             With '--output -', omit the WAV header
    --format FORMAT   With '--output -', choose f32le or s16le samples
    --stream          Print partial text to stdout, or stderr when -o is used
    --input-format    Read headerless PCM from stdin: f32le or s16le
    --input-rate HZ   Sample rate of headerless PCM on stdin (default 16000)

  ENVIRONMENT
    HF_TOKEN    Optional Hugging Face token

  EXAMPLES
    ark-voice download
    ark-voice stt meeting.m4a
    ark-voice stt clip.mp4 -o transcript.txt --stream
    ark-voice tts "Hello from my Mac" -o hello.wav
    ark-voice tts "Hello" -o - | ffplay -autoexit -nodisp -
    ark-voice tts -- "-5 degrees outside" -o weather.wav
    printf 'Read this aloud' | ark-voice tts --file - -o stdin.wav
    ark-voice tts "Cloned voice" --reference speaker.aac -o clone.wav
    ark-voice voice create narrator speaker.aac
    ark-voice tts "Cached voice" --voice narrator -o cached.wav
    ark-voice serve &
    ark-voice client tts "No reload for this one" -o quick.wav
  """

@main
enum ArkVoiceApp {
  static func main() async {
    do {
      let command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
      switch command {
      case .help:
        writeStandardOutput(usage + "\n")
      case .version:
        writeStandardOutput("ark-voice \(arkVoiceVersion)\n")
      default:
        try await CLIRunner.run(command)
      }
    } catch let error as CLIParseError {
      writeStandardError("Error: \(error.localizedDescription)\n\n\(usage)\n")
      exit(2)
    } catch {
      writeStandardError("Error: \(error.localizedDescription)\n")
      exit(1)
    }
  }
}
