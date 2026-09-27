import Foundation

/// Turns cumulative tokenizer decodes into Unicode-safe streaming deltas.
/// Byte-level tokenizers may decode an incomplete UTF-8 suffix as U+FFFD;
/// that suffix is held until later tokens complete the character.
public struct QwenStreamText {
    public private(set) var emitted = ""

    public init() {}

    public mutating func append(_ decoded: String) -> String {
        var stable = decoded
        while stable.last == "\u{FFFD}" { stable.removeLast() }
        guard stable.utf8.starts(with: emitted.utf8) else { return "" }
        let delta = String(decoding: stable.utf8.dropFirst(emitted.utf8.count), as: UTF8.self)
        emitted = stable
        return delta
    }

    public mutating func finish(_ decoded: String) -> String {
        guard decoded.utf8.starts(with: emitted.utf8) else { return "" }
        let delta = String(decoding: decoded.utf8.dropFirst(emitted.utf8.count), as: UTF8.self)
        emitted = decoded
        return delta
    }

    public static func separator(previous: String, next: String, language: String?) -> String {
        guard !previous.isEmpty, !next.isEmpty,
              previous.last?.isWhitespace == false,
              next.first?.isWhitespace == false
        else { return "" }
        let language = language?.lowercased() ?? ""
        return language == "chinese" || language == "japanese" ? "" : " "
    }
}
