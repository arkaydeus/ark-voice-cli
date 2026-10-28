import Foundation

/// Mono PCM audio as it travels on the wire: raw little-endian samples plus the
/// rate and encoding needed to read them.
///
/// Synthesis hands these back chunk by chunk; transcription and voice creation
/// take one. Keeping the bytes as they arrived means a caller that only writes
/// a file or forwards the audio never pays for a float conversion.
public struct PCMAudio: Sendable, Equatable {
  public var data: Data
  public var sampleRate: Int
  public var format: SampleFormat

  public init(data: Data, sampleRate: Int, format: SampleFormat) {
    self.data = data
    self.sampleRate = sampleRate
    self.format = format
  }

  /// Encodes float samples in `[-1, 1]`.
  ///
  /// `s16le` clamps first, so peaks above full scale distort rather than
  /// wrapping to the opposite polarity.
  public init(samples: [Float], sampleRate: Int, format: SampleFormat = .s16le) {
    self.init(data: Self.encode(samples, format: format), sampleRate: sampleRate, format: format)
  }

  public var sampleCount: Int { data.count / format.bytesPerSample }

  public var duration: Double {
    sampleRate > 0 ? Double(sampleCount) / Double(sampleRate) : 0
  }

  /// The audio as floats in `[-1, 1]`.
  public var samples: [Float] { Self.decode(data, format: format) }

  /// Joins consecutive chunks. All parts must share a rate and format.
  public static func joined(_ parts: [PCMAudio], sampleRate: Int, format: SampleFormat) -> PCMAudio {
    var data = Data(capacity: parts.reduce(0) { $0 + $1.data.count })
    for part in parts {
      precondition(part.format == format, "Cannot join \(part.format) audio into \(format).")
      data.append(part.data)
    }
    return PCMAudio(data: data, sampleRate: sampleRate, format: format)
  }

  // MARK: - Sample conversion

  /// Same arithmetic as the server, so audio survives a round trip unchanged.
  static func encode(_ samples: [Float], format: SampleFormat) -> Data {
    var bytes = [UInt8]()
    bytes.reserveCapacity(samples.count * format.bytesPerSample)
    switch format {
    case .f32le:
      for sample in samples {
        let pattern = sample.bitPattern
        bytes.append(UInt8(pattern & 0xff))
        bytes.append(UInt8((pattern >> 8) & 0xff))
        bytes.append(UInt8((pattern >> 16) & 0xff))
        bytes.append(UInt8(pattern >> 24))
      }
    case .s16le:
      for sample in samples {
        let clamped = max(-1, min(1, sample))
        let value = Int16(clamped < 0 ? clamped * 32_768 : clamped * 32_767)
        let pattern = UInt16(bitPattern: value)
        bytes.append(UInt8(pattern & 0xff))
        bytes.append(UInt8(pattern >> 8))
      }
    }
    return Data(bytes)
  }

  static func decode(_ data: Data, format: SampleFormat) -> [Float] {
    let count = data.count / format.bytesPerSample
    return data.withUnsafeBytes { raw -> [Float] in
      var samples = [Float](repeating: 0, count: count)
      for index in 0..<count {
        switch format {
        case .f32le:
          let base = index * 4
          let pattern =
            UInt32(raw[base]) | UInt32(raw[base + 1]) << 8 | UInt32(raw[base + 2]) << 16
            | UInt32(raw[base + 3]) << 24
          samples[index] = Float(bitPattern: pattern)
        case .s16le:
          let value = Int16(bitPattern: UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8)
          samples[index] = Float(value) / 32_768
        }
      }
      return samples
    }
  }
}

// MARK: - WAV

/// Errors reading a WAV file into ``PCMAudio``.
public enum WAVError: LocalizedError, Equatable, Sendable {
  case invalidFormat
  case notWAV
  case missingChunk(String)
  case unsupportedEncoding(formatTag: Int, bitsPerSample: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidFormat:
      "Invalid WAV format header or partial PCM frame."
    case .notWAV:
      "Not a RIFF/WAVE file."
    case .missingChunk(let name):
      "The WAV file has no '\(name)' chunk."
    case .unsupportedEncoding(let tag, let bits):
      "Unsupported WAV encoding (format \(tag), \(bits)-bit). Use 16-bit PCM or 32-bit float."
    }
  }
}

extension PCMAudio {
  /// A mono WAV file: 16-bit PCM for `s16le`, 32-bit IEEE float for `f32le`.
  public var wavData: Data {
    let bitsPerSample = format.bytesPerSample * 8
    let formatTag: UInt16 = format == .f32le ? 3 : 1
    var header = Data()
    header.append(contentsOf: Array("RIFF".utf8))
    header.appendLittleEndian(UInt32(clamping: 36 + data.count))
    header.append(contentsOf: Array("WAVEfmt ".utf8))
    header.appendLittleEndian(UInt32(16))
    header.appendLittleEndian(formatTag)
    header.appendLittleEndian(UInt16(1))  // mono
    header.appendLittleEndian(UInt32(sampleRate))
    header.appendLittleEndian(UInt32(sampleRate * format.bytesPerSample))
    header.appendLittleEndian(UInt16(format.bytesPerSample))
    header.appendLittleEndian(UInt16(bitsPerSample))
    header.append(contentsOf: Array("data".utf8))
    header.appendLittleEndian(UInt32(clamping: data.count))
    return header + data
  }

  public func writeWAV(to url: URL) throws {
    try wavData.write(to: url, options: .atomic)
  }

  /// Reads a WAV file holding 16-bit PCM or 32-bit float samples.
  ///
  /// Several channels are averaged down to mono. A `data` chunk whose size is
  /// unknown (`0xFFFFFFFF`, as `ark-voice tts -o -` streams it) runs to the end
  /// of the file.
  public init(wavData bytes: Data) throws {
    let raw = [UInt8](bytes)
    func u16(_ at: Int) -> Int { Int(raw[at]) | Int(raw[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

    guard raw.count >= 12, raw[0..<4].elementsEqual("RIFF".utf8),
      raw[8..<12].elementsEqual("WAVE".utf8)
    else { throw WAVError.notWAV }

    var formatTag: Int?
    var channels = 1
    var rate = 0
    var bits = 0
    var payload: ArraySlice<UInt8>?
    var offset = 12
    while offset + 8 <= raw.count {
      let id = String(decoding: raw[offset..<offset + 4], as: UTF8.self)
      let size = u32(offset + 4)
      let start = offset + 8
      let end = size == 0xFFFF_FFFF ? raw.count : min(raw.count, start + size)
      if id == "fmt " {
        guard size >= 16, start + size <= raw.count else { throw WAVError.invalidFormat }
        formatTag = u16(start)
        channels = u16(start + 2)
        rate = u32(start + 4)
        bits = u16(start + 14)
        guard channels > 0, rate > 0 else { throw WAVError.invalidFormat }
        if formatTag == 0xFFFE {
          guard size >= 40, u16(start + 16) >= 22,
            18 + u16(start + 16) <= size, u16(start + 18) == bits
          else { throw WAVError.invalidFormat }
          let guid = Array(raw[start + 24..<start + 40])
          let tail: [UInt8] = [0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]
          guard (guid[0] == 1 || guid[0] == 3), Array(guid.dropFirst()) == tail
          else { throw WAVError.invalidFormat }
          formatTag = Int(guid[0])
        }
      } else if id == "data" {
        payload = raw[start..<end]
        if size == 0xFFFF_FFFF || start + size > raw.count { break }
      }
      offset = start + size + (size & 1)
    }
    guard let formatTag else { throw WAVError.missingChunk("fmt ") }
    guard let payload else { throw WAVError.missingChunk("data") }

    let format: SampleFormat
    switch (formatTag, bits) {
    case (1, 16): format = .s16le
    case (3, 32): format = .f32le
    default: throw WAVError.unsupportedEncoding(formatTag: formatTag, bitsPerSample: bits)
    }

    let frameBytes = format.bytesPerSample * channels
    guard payload.count % frameBytes == 0 else { throw WAVError.invalidFormat }
    let whole = Data(payload)
    guard channels > 1 else {
      self.init(data: whole, sampleRate: rate, format: format)
      return
    }
    let interleaved = Self.decode(whole, format: format)
    var mono = [Float](repeating: 0, count: interleaved.count / channels)
    for frame in mono.indices {
      var sum: Float = 0
      for channel in 0..<channels { sum += interleaved[frame * channels + channel] }
      mono[frame] = sum / Float(channels)
    }
    self.init(samples: mono, sampleRate: rate, format: format)
  }

  public init(contentsOfWAV url: URL) throws {
    try self.init(wavData: Data(contentsOf: url))
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var value = value.littleEndian
    Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
  }
}
