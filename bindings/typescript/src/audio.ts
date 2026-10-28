/**
 * PCM sample conversion, the `PCMAudio` value type, and WAV encode/decode.
 */
import { readFile, writeFile } from "node:fs/promises";

/** Sample encodings the protocol carries. */
export type SampleFormat = "s16le" | "f32le";

/** Sample rate of synthesized speech. */
export const SYNTHESIS_SAMPLE_RATE = 24_000;
/** Sample rate the recognizers run at; the server resamples anything else. */
export const TRANSCRIPTION_SAMPLE_RATE = 16_000;

/** Bytes per sample for `format`. */
export function bytesPerSample(format: SampleFormat): 2 | 4 {
  switch (format) {
    case "s16le":
      return 2;
    case "f32le":
      return 4;
    default:
      throw new RangeError(`Unknown sample format '${String(format)}'. Use 's16le' or 'f32le'.`);
  }
}

/**
 * Encodes float samples. `s16le` clamps to [-1, 1], scales negatives by 32768
 * and positives by 32767, and truncates toward zero; `f32le` is IEEE float32.
 */
export function encodeSamples(samples: ArrayLike<number>, format: SampleFormat = "s16le"): Uint8Array {
  const width = bytesPerSample(format);
  const out = new Uint8Array(samples.length * width);
  const view = new DataView(out.buffer);
  if (format === "s16le") {
    for (let i = 0; i < samples.length; i++) {
      let value = samples[i]!;
      if (Number.isNaN(value)) value = 0;
      const clamped = value < -1 ? -1 : value > 1 ? 1 : value;
      const scaled = Math.trunc(clamped < 0 ? clamped * 32768 : clamped * 32767);
      view.setInt16(i * 2, scaled, true);
    }
  } else {
    for (let i = 0; i < samples.length; i++) view.setFloat32(i * 4, samples[i]!, true);
  }
  return out;
}

/** Decodes samples to floats; `s16le` divides by 32768. A trailing partial sample is ignored. */
export function decodeSamples(bytes: Uint8Array, format: SampleFormat = "s16le"): Float32Array {
  const width = bytesPerSample(format);
  const count = Math.floor(bytes.byteLength / width);
  const out = new Float32Array(count);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (format === "s16le") {
    for (let i = 0; i < count; i++) out[i] = view.getInt16(i * 2, true) / 32768;
  } else {
    for (let i = 0; i < count; i++) out[i] = view.getFloat32(i * 4, true);
  }
  return out;
}

/** Mono PCM audio: raw little-endian sample bytes plus their rate and encoding. */
export class PCMAudio {
  readonly data: Uint8Array;
  readonly sampleRate: number;
  readonly format: SampleFormat;

  constructor(data: Uint8Array, sampleRate: number, format: SampleFormat = "s16le") {
    const width = bytesPerSample(format);
    if (!Number.isInteger(sampleRate) || sampleRate <= 0) {
      throw new RangeError(`Sample rate must be a positive integer; got ${sampleRate}.`);
    }
    if (data.byteLength % width !== 0) {
      throw new RangeError(
        `${data.byteLength} bytes is not a whole number of ${format} samples (${width} bytes each).`,
      );
    }
    this.data = data;
    this.sampleRate = sampleRate;
    this.format = format;
    Object.freeze(this);
  }

  /** Builds audio by encoding float samples. */
  static fromSamples(
    samples: ArrayLike<number>,
    sampleRate: number,
    format: SampleFormat = "s16le",
  ): PCMAudio {
    return new PCMAudio(encodeSamples(samples, format), sampleRate, format);
  }

  /**
   * Joins chunks that share a sample rate and format. An empty list needs
   * `fallback` to know what kind of empty audio to return.
   */
  static concat(
    chunks: readonly PCMAudio[],
    fallback?: { sampleRate: number; format: SampleFormat },
  ): PCMAudio {
    const first = chunks[0];
    if (!first) {
      if (!fallback) throw new RangeError("Cannot join zero chunks without a sample rate and format.");
      return new PCMAudio(new Uint8Array(0), fallback.sampleRate, fallback.format);
    }
    let total = 0;
    for (const chunk of chunks) {
      if (chunk.sampleRate !== first.sampleRate || chunk.format !== first.format) {
        throw new RangeError(
          `Cannot join ${chunk.format} at ${chunk.sampleRate} Hz with ${first.format} at ${first.sampleRate} Hz.`,
        );
      }
      total += chunk.data.byteLength;
    }
    const data = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      data.set(chunk.data, offset);
      offset += chunk.data.byteLength;
    }
    return new PCMAudio(data, first.sampleRate, first.format);
  }

  /** Number of samples (mono, so also the number of frames). */
  get sampleCount(): number {
    return this.data.byteLength / bytesPerSample(this.format);
  }

  /** Length in seconds. */
  get duration(): number {
    return this.sampleCount / this.sampleRate;
  }

  /** Decodes to float samples in [-1, 1]. */
  samples(): Float32Array {
    return decodeSamples(this.data, this.format);
  }

  /** Re-encodes in another sample format. */
  convert(format: SampleFormat): PCMAudio {
    if (format === this.format) return this;
    return PCMAudio.fromSamples(this.samples(), this.sampleRate, format);
  }

  /** A mono WAV file: 16-bit PCM for `s16le`, 32-bit IEEE float for `f32le`. */
  toWav(): Uint8Array {
    return encodeWav(this);
  }

  async writeWav(path: string): Promise<void> {
    await writeFile(path, this.toWav());
  }

  static fromWav(bytes: Uint8Array): PCMAudio {
    return decodeWav(bytes);
  }

  static async readWav(path: string): Promise<PCMAudio> {
    const bytes = await readFile(path);
    return decodeWav(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength));
  }
}

const WAVE_FORMAT_PCM = 1;
const WAVE_FORMAT_IEEE_FLOAT = 3;
const WAVE_FORMAT_EXTENSIBLE = 0xfffe;
const SUPPORTED_WAV =
  "Supported WAV encodings: 16-bit integer PCM (format 1), 32-bit IEEE float (format 3), " +
  "or WAVE_FORMAT_EXTENSIBLE carrying either.";

function writeAscii(view: DataView, offset: number, text: string): void {
  for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
}

function readAscii(bytes: Uint8Array, offset: number): string {
  return String.fromCharCode(bytes[offset]!, bytes[offset + 1]!, bytes[offset + 2]!, bytes[offset + 3]!);
}

/** Encodes mono audio as a canonical 44-byte-header WAV file. */
export function encodeWav(audio: PCMAudio): Uint8Array {
  const width = bytesPerSample(audio.format);
  const dataLength = audio.data.byteLength;
  const out = new Uint8Array(44 + dataLength);
  const view = new DataView(out.buffer);
  writeAscii(view, 0, "RIFF");
  view.setUint32(4, 36 + dataLength, true);
  writeAscii(view, 8, "WAVE");
  writeAscii(view, 12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, audio.format === "s16le" ? WAVE_FORMAT_PCM : WAVE_FORMAT_IEEE_FLOAT, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, audio.sampleRate, true);
  view.setUint32(28, audio.sampleRate * width, true);
  view.setUint16(32, width, true);
  view.setUint16(34, width * 8, true);
  writeAscii(view, 36, "data");
  view.setUint32(40, dataLength, true);
  out.set(audio.data, 44);
  return out;
}

/**
 * Decodes a WAV file to mono `PCMAudio`.
 *
 * Accepts 16-bit PCM, 32-bit float, and WAVE_FORMAT_EXTENSIBLE carrying either.
 * Several channels are averaged to mono and re-encoded in the source format.
 * A data size of 0xFFFFFFFF, or one running past the end of the file, means
 * "to end of file", which is what a streamed WAV carries.
 */
export function decodeWav(bytes: Uint8Array): PCMAudio {
  if (bytes.byteLength < 12 || readAscii(bytes, 0) !== "RIFF" || readAscii(bytes, 8) !== "WAVE") {
    throw new RangeError("Not a WAV file: missing the RIFF/WAVE header.");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let fmt: { tag: number; channels: number; sampleRate: number; bits: number } | undefined;
  let data: Uint8Array | undefined;

  let offset = 12;
  while (offset + 8 <= bytes.byteLength) {
    const id = readAscii(bytes, offset);
    const size = view.getUint32(offset + 4, true);
    const body = offset + 8;
    if (id === "fmt ") {
      if (size < 16 || body + 16 > bytes.byteLength) throw new RangeError("WAV fmt chunk is too short.");
      let tag = view.getUint16(body, true);
      if (tag === WAVE_FORMAT_EXTENSIBLE) {
        if (size < 40 || body + size > bytes.byteLength) {
          throw new RangeError("WAVE_FORMAT_EXTENSIBLE fmt chunk is too short to carry a subformat.");
        }
        const extensionSize = view.getUint16(body + 16, true);
        if (extensionSize < 22 || 18 + extensionSize > size ||
            view.getUint16(body + 18, true) !== view.getUint16(body + 14, true)) {
          throw new RangeError("Invalid WAVE_FORMAT_EXTENSIBLE structure.");
        }
        const guid = bytes.subarray(body + 24, body + 40);
        const tail = [0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71];
        if ((guid[0] !== 1 && guid[0] !== 3) || !tail.every((byte, i) => guid[i + 1] === byte)) {
          throw new RangeError("Unsupported WAVE_FORMAT_EXTENSIBLE subformat GUID.");
        }
        tag = guid[0]!;
      }
      fmt = {
        tag,
        channels: view.getUint16(body + 2, true),
        sampleRate: view.getUint32(body + 4, true),
        bits: view.getUint16(body + 14, true),
      };
    } else if (id === "data") {
      const toEnd = size === 0xffff_ffff || body + size > bytes.byteLength;
      data = bytes.subarray(body, toEnd ? bytes.byteLength : body + size);
      if (toEnd) break;
    }
    if (body + size > bytes.byteLength) break;
    offset = body + size + (size & 1);
  }

  if (!fmt) throw new RangeError("WAV file has no fmt chunk.");
  if (!data) throw new RangeError("WAV file has no data chunk.");

  let format: SampleFormat;
  if (fmt.tag === WAVE_FORMAT_PCM && fmt.bits === 16) format = "s16le";
  else if (fmt.tag === WAVE_FORMAT_IEEE_FLOAT && fmt.bits === 32) format = "f32le";
  else {
    throw new RangeError(
      `Unsupported WAV encoding: format tag ${fmt.tag} with ${fmt.bits}-bit samples. ${SUPPORTED_WAV}`,
    );
  }
  if (fmt.channels < 1) throw new RangeError("WAV file declares zero channels.");
  if (fmt.sampleRate < 1) throw new RangeError("WAV file declares a zero sample rate.");

  const width = bytesPerSample(format);
  const frameBytes = width * fmt.channels;
  const frames = Math.floor(data.byteLength / frameBytes);

  if (fmt.channels === 1) {
    return new PCMAudio(data.slice(0, frames * width), fmt.sampleRate, format);
  }
  const interleaved = decodeSamples(data.subarray(0, frames * frameBytes), format);
  const mono = new Float32Array(frames);
  for (let frame = 0; frame < frames; frame++) {
    let sum = 0;
    for (let channel = 0; channel < fmt.channels; channel++) {
      sum += interleaved[frame * fmt.channels + channel]!;
    }
    mono[frame] = sum / fmt.channels;
  }
  return PCMAudio.fromSamples(mono, fmt.sampleRate, format);
}
