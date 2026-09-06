//
//  MLXAudioLog.swift
//  MLXAudio
//
//  ark-voice patch: routes model diagnostics through a replaceable handler so
//  embedding processes can keep stdout free for data.
//

import Foundation

/// Diagnostic output for model loading and generation.
///
/// Models used to call `print` directly, which made stdout unusable as a data
/// channel for hosts that embed this package. Output now flows through
/// ``MLXAudioLog/handler``, which writes to stderr unless a host replaces it.
public enum MLXAudioLog {
    /// Receives every rendered diagnostic line, without a trailing newline.
    ///
    /// Defaults to writing to stderr. Assign `nil` to silence model
    /// diagnostics entirely.
    public nonisolated(unsafe) static var handler: (@Sendable (String) -> Void)? = { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Emits one diagnostic line. Mirrors `print`'s signature so model code can
    /// be converted mechanically.
    ///
    /// Unlike `print`, a `terminator` of `""` still produces a discrete line;
    /// partial-line progress output becomes one line per call.
    public static func log(
        _ items: Any...,
        separator: String = " ",
        terminator: String = "\n"
    ) {
        guard let handler else { return }
        _ = terminator
        handler(items.map { String(describing: $0) }.joined(separator: separator))
    }
}
