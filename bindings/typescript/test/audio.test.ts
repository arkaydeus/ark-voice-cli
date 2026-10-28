import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { PCMAudio, decodeWav, encodeSamples, encodeWav } from "../src/index.js";

const tempDir = mkdtempSync("/tmp/arkv-ts-audio-");
afterAll(() => rmSync(tempDir, { recursive: true, force: true }));

interface WavSpec {
  tag: number;
  channels: number;
  sampleRate: number;
  bits: number;
  data: Uint8Array;
  dataSize?: number;
  subformat?: number;
  extraChunks?: Array<{ id: string; body: Uint8Array }>;
}

/** Builds a WAV by hand so the reader is tested against bytes it did not write. */
function buildWav(spec: WavSpec): Uint8Array {
  const parts: Uint8Array[] = [];
  const chunk = (id: string, body: Uint8Array, declaredSize = body.length): Uint8Array => {
    const out = new Uint8Array(8 + body.length + (body.length & 1));
    const view = new DataView(out.buffer);
    for (let i = 0; i < 4; i++) out[i] = id.charCodeAt(i);
    view.setUint32(4, declaredSize, true);
    out.set(body, 8);
    return out;
  };
  const extensible = spec.tag === 0xfffe;
  const fmt = new Uint8Array(extensible ? 40 : 16);
  const view = new DataView(fmt.buffer);
  const blockAlign = (spec.bits / 8) * spec.channels;
  view.setUint16(0, spec.tag, true);
  view.setUint16(2, spec.channels, true);
  view.setUint32(4, spec.sampleRate, true);
  view.setUint32(8, spec.sampleRate * blockAlign, true);
  view.setUint16(12, blockAlign, true);
  view.setUint16(14, spec.bits, true);
  if (extensible) {
    view.setUint16(16, 22, true);
    view.setUint16(18, spec.bits, true);
    view.setUint16(24, spec.subformat ?? 1, true);
    fmt.set([0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71], 26);
  }
  parts.push(chunk("fmt ", fmt));
  for (const extra of spec.extraChunks ?? []) parts.push(chunk(extra.id, extra.body));
  const dataChunk = chunk("data", spec.data, spec.dataSize ?? spec.data.length);
  parts.push(spec.dataSize === undefined ? dataChunk : dataChunk.subarray(0, 8 + spec.data.length));
  const body = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(12 + body);
  const outView = new DataView(out.buffer);
  out.set(new TextEncoder().encode("RIFF"), 0);
  outView.setUint32(4, spec.dataSize === 0xffffffff ? 0xffffffff : 4 + body, true);
  out.set(new TextEncoder().encode("WAVE"), 8);
  let offset = 12;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

describe("PCMAudio", () => {
  test("reports sample count and duration", () => {
    const audio = PCMAudio.fromSamples([0, 0.5, -0.5, 1], 4, "s16le");
    expect(audio.data).toBeInstanceOf(Uint8Array);
    expect(audio.sampleCount).toBe(4);
    expect(audio.duration).toBe(1);
    expect(Array.from(audio.samples())).toEqual([0, 16383 / 32768, -0.5, 32767 / 32768]);
  });

  test("f32le stores exact floats", () => {
    const audio = PCMAudio.fromSamples([0.25, -0.75], 24000, "f32le");
    expect(audio.data.byteLength).toBe(8);
    expect(Array.from(audio.samples())).toEqual([0.25, -0.75]);
  });

  test("rejects a partial sample and a bad rate", () => {
    expect(() => new PCMAudio(new Uint8Array(3), 16000, "s16le")).toThrow(RangeError);
    expect(() => new PCMAudio(new Uint8Array(2), 0, "s16le")).toThrow(RangeError);
  });

  test("concat joins chunks and refuses mixed formats", () => {
    const a = PCMAudio.fromSamples([0.5], 24000);
    const b = PCMAudio.fromSamples([-0.5, 0.25], 24000);
    const joined = PCMAudio.concat([a, b]);
    expect(joined.sampleCount).toBe(3);
    expect(Array.from(joined.samples())).toEqual([16383 / 32768, -0.5, 8191 / 32768]);
    expect(() => PCMAudio.concat([a, PCMAudio.fromSamples([0], 16000)])).toThrow(RangeError);
    expect(() => PCMAudio.concat([])).toThrow(RangeError);
    expect(PCMAudio.concat([], { sampleRate: 24000, format: "f32le" }).sampleCount).toBe(0);
  });

  test("convert re-encodes", () => {
    const audio = PCMAudio.fromSamples([0.5, -0.5], 16000, "f32le").convert("s16le");
    expect(audio.format).toBe("s16le");
    expect(Array.from(audio.samples())).toEqual([16383 / 32768, -0.5]);
  });
});

describe("WAV", () => {
  test("s16le round trip uses format tag 1, 16-bit, a 16-byte fmt chunk", () => {
    const audio = PCMAudio.fromSamples([0, 0.5, -0.5, 0.25], 24000, "s16le");
    const wav = audio.toWav();
    const view = new DataView(wav.buffer);
    expect(wav.byteLength).toBe(44 + 8);
    expect(view.getUint32(16, true)).toBe(16);
    expect(view.getUint16(20, true)).toBe(1);
    expect(view.getUint16(22, true)).toBe(1);
    expect(view.getUint16(34, true)).toBe(16);
    const back = PCMAudio.fromWav(wav);
    expect(back.format).toBe("s16le");
    expect(back.sampleRate).toBe(24000);
    expect(back.data).toEqual(audio.data);
  });

  test("f32le round trip uses format tag 3, 32-bit", () => {
    const audio = PCMAudio.fromSamples([0, 0.5, -0.5, 0.125], 16000, "f32le");
    const wav = encodeWav(audio);
    const view = new DataView(wav.buffer);
    expect(view.getUint16(20, true)).toBe(3);
    expect(view.getUint16(34, true)).toBe(32);
    const back = decodeWav(wav);
    expect(back.format).toBe("f32le");
    expect(back.sampleRate).toBe(16000);
    expect(back.data).toEqual(audio.data);
  });

  test("file round trip", async () => {
    const path = join(tempDir, "round.wav");
    const audio = PCMAudio.fromSamples([0.1, -0.2, 0.3], 22050);
    await audio.writeWav(path);
    const back = await PCMAudio.readWav(path);
    expect(back.data).toEqual(audio.data);
    expect(back.sampleRate).toBe(22050);
  });

  test("stereo s16le is averaged to mono", () => {
    // L/R pairs: (0.5, -0.5) -> 0, (0.5, 0.5) -> 0.5, (-1, -1) -> -1, averaged as
    // decoded floats and re-encoded with the s16le rule.
    const interleaved = encodeSamples([0.5, -0.5, 0.5, 0.5, -1, -1], "s16le");
    const audio = decodeWav(buildWav({ tag: 1, channels: 2, sampleRate: 48000, bits: 16, data: interleaved }));
    expect(audio.format).toBe("s16le");
    expect(audio.sampleRate).toBe(48000);
    expect(audio.sampleCount).toBe(3);
    const samples = Array.from(audio.samples());
    // 0.5 encodes to 16383; 16383/32768 * 32767 truncates to 16382.
    expect(samples).toEqual([0, 16382 / 32768, -1]);
  });

  test("three-channel f32le is averaged to mono f32le", () => {
    const interleaved = encodeSamples([0.25, 0.5, 0.75, -0.25, -0.5, -0.75], "f32le");
    const audio = decodeWav(buildWav({ tag: 3, channels: 3, sampleRate: 8000, bits: 32, data: interleaved }));
    expect(audio.format).toBe("f32le");
    expect(Array.from(audio.samples())).toEqual([0.5, -0.5]);
  });

  test("data size 0xFFFFFFFF reads to end of file (streamed WAV)", () => {
    const data = encodeSamples([0.5, -0.5, 0.25], "s16le");
    const audio = decodeWav(buildWav({ tag: 1, channels: 1, sampleRate: 24000, bits: 16, data, dataSize: 0xffffffff }));
    expect(audio.data).toEqual(data);
  });

  test("data size past EOF reads to end of file", () => {
    const data = encodeSamples([0.5, -0.5], "s16le");
    const audio = decodeWav(buildWav({ tag: 1, channels: 1, sampleRate: 24000, bits: 16, data, dataSize: 1000 }));
    expect(audio.data).toEqual(data);
  });

  test("WAVE_FORMAT_EXTENSIBLE takes the subformat from the GUID", () => {
    const pcm = encodeSamples([0.5, -0.5], "s16le");
    expect(decodeWav(buildWav({ tag: 0xfffe, subformat: 1, channels: 1, sampleRate: 16000, bits: 16, data: pcm })).format).toBe(
      "s16le",
    );
    const float = encodeSamples([0.5, -0.5], "f32le");
    const audio = decodeWav(buildWav({ tag: 0xfffe, subformat: 3, channels: 1, sampleRate: 16000, bits: 32, data: float }));
    expect(audio.format).toBe("f32le");
    expect(Array.from(audio.samples())).toEqual([0.5, -0.5]);
  });

  test("skips unknown chunks, padding odd sizes", () => {
    const data = encodeSamples([0.25], "s16le");
    const wav = buildWav({
      tag: 1,
      channels: 1,
      sampleRate: 24000,
      bits: 16,
      data,
      extraChunks: [{ id: "LIST", body: new Uint8Array([1, 2, 3]) }],
    });
    expect(decodeWav(wav).data).toEqual(data);
  });

  test("unsupported encodings name the supported ones", () => {
    const eightBit = buildWav({ tag: 1, channels: 1, sampleRate: 8000, bits: 8, data: new Uint8Array(4) });
    expect(() => decodeWav(eightBit)).toThrow(/16-bit integer PCM.*32-bit IEEE float/);
    const twentyFour = buildWav({ tag: 1, channels: 1, sampleRate: 8000, bits: 24, data: new Uint8Array(6) });
    expect(() => decodeWav(twentyFour)).toThrow(/Supported WAV encodings/);
    const alaw = buildWav({ tag: 6, channels: 1, sampleRate: 8000, bits: 8, data: new Uint8Array(4) });
    expect(() => decodeWav(alaw)).toThrow(/format tag 6/);
    expect(() => decodeWav(new TextEncoder().encode("not a wav file at all"))).toThrow(/Not a WAV file/);
  });
});


test("extensible headers require complete canonical GUIDs and extension size", () => {
  for (const subformat of [1, 3]) {
    const bits = subformat === 1 ? 16 : 32;
    const wav = buildWav({ tag: 0xfffe, subformat, channels: 1, sampleRate: 16000, bits, data: new Uint8Array(bits / 8) });
    expect(decodeWav(wav).format).toBe(subformat === 1 ? "s16le" : "f32le");
    const changed = wav.slice();
    changed[20 + 39]! ^= 1;
    expect(() => decodeWav(changed)).toThrow(/GUID/);
    for (const length of [26, 39]) expect(() => decodeWav(wav.subarray(0, 20 + length))).toThrow(RangeError);
    for (const size of [0, 23]) {
      const bad = wav.slice();
      new DataView(bad.buffer).setUint16(20 + 16, size, true);
      expect(() => decodeWav(bad)).toThrow(RangeError);
    }
  }
});

test("fmt can follow bounded data", () => {
  const audio = new PCMAudio(new Uint8Array(4), 16000);
  const wav = audio.toWav();
  const reordered = new Uint8Array(wav.length);
  reordered.set(wav.subarray(0, 12));
  reordered.set(wav.subarray(36), 12);
  reordered.set(wav.subarray(12, 36), 12 + wav.length - 36);
  expect(decodeWav(reordered).data).toEqual(audio.data);
});


test("shared WAV vectors", () => {
  const vectors = JSON.parse(readFileSync(new URL("../../test-vectors/wav.json", import.meta.url), "utf8")) as
    Array<{ name: string; hex: string; invalid?: boolean; format?: "s16le" | "f32le" }>;
  for (const vector of vectors) {
    const data = new Uint8Array(Buffer.from(vector.hex, "hex"));
    if (vector.invalid) expect(() => decodeWav(data)).toThrow(RangeError);
    else expect(decodeWav(data).format).toBe(vector.format!);
  }
});
