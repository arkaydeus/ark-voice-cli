import Foundation

enum Command: Equatable {
  case download(ModelSelection)
  case transcribe(input: String, output: String?)
  case speak(text: TextSource, output: String, reference: String?, voice: String?)
  case createVoice(name: String, reference: String)
  case voices
  case models
  case help
  case version
}

enum ModelSelection: String, Equatable {
  case all
  case stt
  case tts
}

enum TextSource: Equatable {
  case literal(String)
  case file(String)
  case standardInput
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
      return try parseTranscribe(rest)
    case "tts", "speak":
      return try parseSpeak(rest)
    default:
      throw CLIParseError.message("Unknown command '\(name)'.")
    }
  }

  private static func parseDownload(_ arguments: [String]) throws -> Command {
    if arguments.isEmpty { return .download(.all) }
    guard arguments.count == 1, let selection = ModelSelection(rawValue: arguments[0]) else {
      throw CLIParseError.message("Usage: ark-voice download [all|stt|tts]")
    }
    return .download(selection)
  }

  private static func parseTranscribe(_ arguments: [String]) throws -> Command {
    var input: String?
    var output: String?
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
      default:
        guard !argument.hasPrefix("-") else {
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
        "Usage: ark-voice stt <audio.{wav,aac,m4a,mp4}> [--output transcript.txt]")
    }
    return .transcribe(input: input, output: output)
  }

  private static func parseSpeak(_ arguments: [String]) throws -> Command {
    var text: String?
    var textFile: String?
    var output: String?
    var reference: String?
    var voice: String?
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
        "Usage: ark-voice tts <text> [--output speech.wav] [--reference voice.wav]")
    }

    return .speak(
      text: source,
      output: output ?? "speech.wav",
      reference: reference,
      voice: voice
    )
  }

  private static func parseVoice(_ arguments: [String]) throws -> Command {
    guard arguments.count == 3, arguments[0] == "create" else {
      throw CLIParseError.message("Usage: ark-voice voice create <name> <reference-audio>")
    }
    return .createVoice(name: arguments[1], reference: arguments[2])
  }

  private static func requireNoArguments(_ arguments: [String], command: String) throws {
    guard arguments.isEmpty else {
      throw CLIParseError.message("'\(command)' does not accept arguments.")
    }
  }
}
