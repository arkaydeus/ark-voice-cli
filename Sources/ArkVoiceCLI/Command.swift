import ArkVoiceKit
import Foundation

enum Command: Equatable {
  case download(ModelSelection)
  case transcribe(TranscribeOptions)
  case speak(SpeakOptions)
  case createVoice(name: String, reference: String)
  case voices
  case models
  case serve(ServeOptions)
  case client(ClientCommand)
  case help
  case version
}

enum TextSource: Equatable {
  case literal(String)
  case file(String)
  case standardInput
}

/// Where transcription input comes from.
enum AudioSource: Equatable {
  case file(String)
  case standardInput
}

/// Where synthesized audio goes.
enum AudioDestination: Equatable {
  case file(String)
  /// Stream to stdout as the audio is generated.
  case standardOutput
}

struct TranscribeOptions: Equatable {
  var input: AudioSource
  var output: String?
  /// Print incremental text as it is recognized.
  var stream: Bool
  /// Set when stdin carries headerless PCM rather than a container.
  var inputFormat: PCMSampleFormat?
  var inputSampleRate: Int
  /// Recognizer to use; `nil` leaves the choice to the session or server.
  var model: TranscriptionModel?

  init(
    input: AudioSource,
    output: String? = nil,
    stream: Bool = false,
    inputFormat: PCMSampleFormat? = nil,
    inputSampleRate: Int = VoiceSession.transcriptionSampleRate,
    model: TranscriptionModel? = nil
  ) {
    self.input = input
    self.output = output
    self.stream = stream
    self.inputFormat = inputFormat
    self.inputSampleRate = inputSampleRate
    self.model = model
  }
}

struct SpeakOptions: Equatable {
  var text: TextSource
  var output: AudioDestination
  var reference: String?
  var voice: String?
  /// Emit headerless PCM instead of a WAV stream. Only for stdout.
  var raw: Bool
  /// Sample encoding for stdout. Files always hold float samples.
  var sampleFormat: PCMSampleFormat

  init(
    text: TextSource,
    output: AudioDestination = .file("speech.wav"),
    reference: String? = nil,
    voice: String? = nil,
    raw: Bool = false,
    sampleFormat: PCMSampleFormat = .f32le
  ) {
    self.text = text
    self.output = output
    self.reference = reference
    self.voice = voice
    self.raw = raw
    self.sampleFormat = sampleFormat
  }
}

struct ServeOptions: Equatable {
  var socketPath: String?
  /// Release models after this many idle seconds; `nil` keeps them resident.
  var idleUnloadSeconds: Double?
  /// Exit after this many idle seconds; `nil` runs until stopped.
  var idleExitSeconds: Double?
  /// Recognizer for `stt` requests that do not name one.
  var transcriptionModel: TranscriptionModel?

  init(
    socketPath: String? = nil,
    idleUnloadSeconds: Double? = 300,
    idleExitSeconds: Double? = nil,
    transcriptionModel: TranscriptionModel? = nil
  ) {
    self.socketPath = socketPath
    self.idleUnloadSeconds = idleUnloadSeconds
    self.idleExitSeconds = idleExitSeconds
    self.transcriptionModel = transcriptionModel
  }
}

enum ClientCommand: Equatable {
  case tts(SpeakOptions, socketPath: String?)
  case stt(TranscribeOptions, socketPath: String?)
  case voices(socketPath: String?)
  case status(socketPath: String?)
  case unload(socketPath: String?)
}

enum CLIParseError: LocalizedError, Equatable {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let text): text
    }
  }
}

enum CLIParser {
  static func parse(_ arguments: [String]) throws -> Command {
    guard let name = arguments.first else { return .help }
    let rest = Array(arguments.dropFirst())

    switch name {
    case "help", "--help", "-h":
      return .help
    case "version", "--version":
      return .version
    case "models":
      try requireNoArguments(rest, command: "models")
      return .models
    case "voices":
      try requireNoArguments(rest, command: "voices")
      return .voices
    case "voice":
      return try parseVoice(rest)
    case "download":
      return try parseDownload(rest)
    case "stt", "transcribe":
      return .transcribe(try parseTranscribe(rest))
    case "tts", "speak":
      return .speak(try parseSpeak(rest))
    case "serve":
      return .serve(try parseServe(rest))
    case "client":
      return .client(try parseClient(rest))
    default:
      throw CLIParseError.message("Unknown command '\(name)'.")
    }
  }

  private static func parseDownload(_ arguments: [String]) throws -> Command {
    if arguments.isEmpty { return .download(.all) }
    guard arguments.count == 1, let selection = ModelSelection(rawValue: arguments[0]) else {
      throw CLIParseError.message(
        "Usage: ark-voice download [\(ModelSelection.optionsDescription)]")
    }
    return .download(selection)
  }

  private static func parseTranscribe(_ arguments: [String]) throws -> TranscribeOptions {
    var input: String?
    var output: String?
    var stream = false
    var inputFormat: PCMSampleFormat?
    var inputSampleRate: Int?
    var model: TranscriptionModel?
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--model", "-m":
        index += 1
        model = try parseTranscriptionModel(arguments, at: index, option: "--model")
      case "--output", "-o":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("--output requires a path.")
        }
        guard output == nil else {
          throw CLIParseError.message("--output may only be supplied once.")
        }
        output = arguments[index]
      case "--stream":
        stream = true
      case "--input-format":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message(
            "--input-format requires \(PCMSampleFormat.optionsDescription).")
        }
        guard let format = PCMSampleFormat(rawValue: arguments[index]) else {
          throw CLIParseError.message(
            "Unknown --input-format '\(arguments[index])'. Use \(PCMSampleFormat.optionsDescription)."
          )
        }
        inputFormat = format
      case "--input-rate":
        index += 1
        guard index < arguments.count, let rate = Int(arguments[index]), rate > 0 else {
          throw CLIParseError.message("--input-rate requires a positive sample rate in hertz.")
        }
        inputSampleRate = rate
      default:
        guard argument == "-" || !argument.hasPrefix("-") else {
          throw CLIParseError.message("Unknown stt option '\(argument)'.")
        }
        guard input == nil else {
          throw CLIParseError.message("stt accepts exactly one input audio file.")
        }
        input = argument
      }
      index += 1
    }

    guard let input else {
      throw CLIParseError.message(
        "Usage: ark-voice stt <audio.{wav,aac,m4a,mp4}|-> [--output transcript.txt] [--stream] [--model name]"
      )
    }
    guard input == "-" || inputFormat == nil else {
      throw CLIParseError.message("--input-format only applies when reading audio from stdin.")
    }

    return TranscribeOptions(
      input: input == "-" ? .standardInput : .file(input),
      output: output,
      stream: stream,
      inputFormat: inputFormat,
      inputSampleRate: inputSampleRate ?? VoiceSession.transcriptionSampleRate,
      model: model
    )
  }

  private static func parseTranscriptionModel(
    _ arguments: [String],
    at index: Int,
    option: String
  ) throws -> TranscriptionModel {
    guard index < arguments.count else {
      throw CLIParseError.message(
        "\(option) requires one of \(TranscriptionModel.optionsDescription).")
    }
    guard let model = TranscriptionModel(rawValue: arguments[index]) else {
      throw CLIParseError.message(
        "Unknown \(option) '\(arguments[index])'. Use \(TranscriptionModel.optionsDescription).")
    }
    return model
  }

  private static func parseSpeak(_ arguments: [String]) throws -> SpeakOptions {
    var text: String?
    var textFile: String?
    var output: String?
    var reference: String?
    var voice: String?
    var raw = false
    var sampleFormat: PCMSampleFormat?
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--output", "-o":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("--output requires a path.")
        }
        guard output == nil else {
          throw CLIParseError.message("--output may only be supplied once.")
        }
        output = arguments[index]
      case "--file", "-f":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("--file requires a UTF-8 text file path, or '-' for stdin.")
        }
        guard textFile == nil else {
          throw CLIParseError.message("--file may only be supplied once.")
        }
        textFile = arguments[index]
      case "--reference", "-r":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("--reference requires an audio file path.")
        }
        guard reference == nil else {
          throw CLIParseError.message("--reference may only be supplied once.")
        }
        reference = arguments[index]
      case "--voice", "-v":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("--voice requires a saved voice name.")
        }
        guard voice == nil else {
          throw CLIParseError.message("--voice may only be supplied once.")
        }
        voice = arguments[index]
      case "--raw":
        raw = true
      case "--format":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("--format requires \(PCMSampleFormat.optionsDescription).")
        }
        guard let format = PCMSampleFormat(rawValue: arguments[index]) else {
          throw CLIParseError.message(
            "Unknown --format '\(arguments[index])'. Use \(PCMSampleFormat.optionsDescription).")
        }
        sampleFormat = format
      case "--":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("-- requires inline text after it.")
        }
        guard textFile == nil else {
          throw CLIParseError.message("Pass either inline text or --file, not both.")
        }
        guard text == nil else {
          throw CLIParseError.message("Quote multi-word text as a single argument.")
        }
        text = arguments[index]
      default:
        guard !argument.hasPrefix("-") else {
          throw CLIParseError.message("Unknown tts option '\(argument)'.")
        }
        guard text == nil else {
          throw CLIParseError.message("Quote multi-word text as a single argument.")
        }
        text = argument
      }
      index += 1
    }

    guard text == nil || textFile == nil else {
      throw CLIParseError.message("Pass either inline text or --file, not both.")
    }
    guard reference == nil || voice == nil else {
      throw CLIParseError.message("Pass either --reference or --voice, not both.")
    }

    let source: TextSource
    if let text {
      source = .literal(text)
    } else if let textFile {
      source = textFile == "-" ? .standardInput : .file(textFile)
    } else {
      throw CLIParseError.message(
        "Usage: ark-voice tts <text> [--output speech.{wav,m4a,aac}|-] [--reference voice.wav]")
    }

    let destination: AudioDestination =
      (output ?? "speech.wav") == "-" ? .standardOutput : .file(output ?? "speech.wav")
    guard destination == .standardOutput || (!raw && sampleFormat == nil) else {
      throw CLIParseError.message(
        "--raw and --format only apply when streaming to stdout with '--output -'.")
    }

    return SpeakOptions(
      text: source,
      output: destination,
      reference: reference,
      voice: voice,
      raw: raw,
      sampleFormat: sampleFormat ?? .f32le
    )
  }

  private static func parseVoice(_ arguments: [String]) throws -> Command {
    guard arguments.count == 3, arguments[0] == "create" else {
      throw CLIParseError.message("Usage: ark-voice voice create <name> <reference-audio>")
    }
    return .createVoice(name: arguments[1], reference: arguments[2])
  }

  private static func parseServe(_ arguments: [String]) throws -> ServeOptions {
    var options = ServeOptions()
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--socket", "-s":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("--socket requires a path.")
        }
        options.socketPath = arguments[index]
      case "--idle-unload":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("--idle-unload requires seconds, or 'off'.")
        }
        options.idleUnloadSeconds = try parseInterval(arguments[index], option: "--idle-unload")
      case "--idle-exit":
        index += 1
        guard index < arguments.count else {
          throw CLIParseError.message("--idle-exit requires seconds, or 'off'.")
        }
        options.idleExitSeconds = try parseInterval(arguments[index], option: "--idle-exit")
      case "--stt-model":
        index += 1
        options.transcriptionModel = try parseTranscriptionModel(
          arguments, at: index, option: "--stt-model")
      case "--foreground":
        // The server always runs in the foreground; accepted so launchd-style
        // invocations do not have to special-case it.
        break
      default:
        throw CLIParseError.message("Unknown serve option '\(argument)'.")
      }
      index += 1
    }
    return options
  }

  private static func parseInterval(_ value: String, option: String) throws -> Double? {
    if value == "off" || value == "never" { return nil }
    guard let seconds = Double(value), seconds > 0 else {
      throw CLIParseError.message("\(option) requires a positive number of seconds, or 'off'.")
    }
    return seconds
  }

  private static func parseClient(_ arguments: [String]) throws -> ClientCommand {
    guard let subcommand = arguments.first else {
      throw CLIParseError.message(
        "Usage: ark-voice client <tts|stt|voices|status|unload> [--socket path]")
    }

    var rest = Array(arguments.dropFirst())
    var socketPath: String?
    var index = 0
    var filtered = [String]()
    while index < rest.count {
      if rest[index] == "--" {
        filtered.append(contentsOf: rest[index...])
        break
      }
      if rest[index] == "--socket" || rest[index] == "-s" {
        index += 1
        guard index < rest.count else {
          throw CLIParseError.message("--socket requires a path.")
        }
        socketPath = rest[index]
      } else {
        filtered.append(rest[index])
      }
      index += 1
    }
    rest = filtered

    switch subcommand {
    case "tts", "speak":
      return .tts(try parseSpeak(rest), socketPath: socketPath)
    case "stt", "transcribe":
      return .stt(try parseTranscribe(rest), socketPath: socketPath)
    case "voices":
      try requireNoArguments(rest, command: "client voices")
      return .voices(socketPath: socketPath)
    case "status":
      try requireNoArguments(rest, command: "client status")
      return .status(socketPath: socketPath)
    case "unload":
      try requireNoArguments(rest, command: "client unload")
      return .unload(socketPath: socketPath)
    default:
      throw CLIParseError.message("Unknown client subcommand '\(subcommand)'.")
    }
  }

  private static func requireNoArguments(_ arguments: [String], command: String) throws {
    guard arguments.isEmpty else {
      throw CLIParseError.message("'\(command)' does not accept arguments.")
    }
  }
}

extension PCMSampleFormat {
  static var optionsDescription: String {
    allCases.map(\.rawValue).joined(separator: " or ")
  }
}
