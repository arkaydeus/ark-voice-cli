/**
 * The shared byte vectors every binding must reproduce exactly.
 */
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  FrameDecoder,
  FrameKind,
  HEADER_SIZE,
  MAX_PAYLOAD_SIZE,
  PROTOCOL_VERSION,
  ProtocolError,
  decodeMessage,
  decodeSamples,
  encodeFrame,
  encodeMessage,
  encodeMessageFrame,
  encodeSamples,
  parseHeader,
  type JsonMessage,
} from "../src/index.js";
import { hex, toHex } from "./fake-server.js";

interface Vectors {
  protocolVersion: number;
  headerSize: number;
  maximumPayloadSize: number;
  requests: Array<{ name: string; requestId: number; message: JsonMessage; payload: string; frame: string }>;
  events: Array<{ name: string; requestId: number; message: JsonMessage; frame: string }>;
  pcmFrames: Array<{ name: string; requestId: number; kind: number; payload: string; frame: string }>;
  invalidHeaders: Array<{ name: string; header: string; error: string }>;
  validHeaders: Array<{ name: string; header: string; kind: number; requestId: number; payloadLength: number }>;
  samples: {
    s16leEncode: { floats: number[]; hex: string };
    s16leDecode: { hex: string; floats: number[] };
    f32le: { floats: number[]; hex: string };
  };
}

const vectorsPath = fileURLToPath(new URL("../../test-vectors/protocol.json", import.meta.url));
const vectors = JSON.parse(readFileSync(vectorsPath, "utf8")) as Vectors;
const utf8 = new TextEncoder();

function decodeAll(bytes: Uint8Array, byteAtATime: boolean) {
  const decoder = new FrameDecoder();
  const frames = [];
  if (byteAtATime) {
    for (let i = 0; i < bytes.length; i++) frames.push(...decoder.push(bytes.subarray(i, i + 1)));
  } else {
    frames.push(...decoder.push(bytes));
  }
  decoder.finish();
  return frames;
}

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

test("constants match the vectors", () => {
  expect(PROTOCOL_VERSION).toBe(vectors.protocolVersion);
  expect(HEADER_SIZE).toBe(vectors.headerSize);
  expect(MAX_PAYLOAD_SIZE).toBe(vectors.maximumPayloadSize);
});

describe("requests", () => {
  test.each(vectors.requests.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    expect(encodeMessage(vector.message)).toEqual(utf8.encode(vector.payload));
    expect(toHex(encodeMessageFrame(vector.requestId, vector.message))).toBe(vector.frame);
    expect(toHex(encodeFrame(FrameKind.JSON, vector.requestId, utf8.encode(vector.payload)))).toBe(vector.frame);
  });

  test("absent fields are omitted whether undefined or null", () => {
    const payload = encodeMessage({ op: "tts", text: "Hi", voice: undefined, model: null, format: "s16le" });
    expect(new TextDecoder().decode(payload)).toBe('{"format":"s16le","op":"tts","text":"Hi"}');
  });
});

describe("events", () => {
  test.each(vectors.events.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    const bytes = hex(vector.frame);
    for (const byteAtATime of [false, true]) {
      const frames = decodeAll(bytes, byteAtATime);
      expect(frames).toHaveLength(1);
      const frame = frames[0]!;
      expect(frame.kind).toBe(FrameKind.JSON);
      expect(frame.requestId).toBe(vector.requestId);
      expect(decodeMessage(frame.payload)).toEqual(vector.message);
    }
  });

  test("all event frames concatenated, whole and byte by byte", () => {
    const bytes = concat(vectors.events.map((vector) => hex(vector.frame)));
    for (const byteAtATime of [false, true]) {
      const frames = decodeAll(bytes, byteAtATime);
      expect(frames.map((frame) => frame.requestId)).toEqual(vectors.events.map((vector) => vector.requestId));
      expect(frames.map((frame) => decodeMessage(frame.payload))).toEqual(
        vectors.events.map((vector) => vector.message),
      );
    }
  });
});

describe("pcm frames", () => {
  test.each(vectors.pcmFrames.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    expect(toHex(encodeFrame(FrameKind.PCM, vector.requestId, hex(vector.payload)))).toBe(vector.frame);
    for (const byteAtATime of [false, true]) {
      const frames = decodeAll(hex(vector.frame), byteAtATime);
      expect(frames).toHaveLength(1);
      expect(frames[0]!.kind).toBe(vector.kind as FrameKind);
      expect(frames[0]!.requestId).toBe(vector.requestId);
      expect(toHex(frames[0]!.payload)).toBe(vector.payload);
    }
  });

  test("every frame kind concatenated, byte by byte", () => {
    const all = [...vectors.events.map((v) => v.frame), ...vectors.pcmFrames.map((v) => v.frame)];
    const frames = decodeAll(concat(all.map(hex)), true);
    expect(frames).toHaveLength(all.length);
    expect(frames.slice(-2).map((frame) => toHex(frame.payload))).toEqual(
      vectors.pcmFrames.map((vector) => vector.payload),
    );
  });
});

describe("invalid headers", () => {
  test.each(vectors.invalidHeaders.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    const header = hex(vector.header);
    let thrown: unknown;
    try {
      parseHeader(header);
    } catch (error) {
      thrown = error;
    }
    expect(thrown).toBeInstanceOf(ProtocolError);
    expect((thrown as ProtocolError).reason).toBe(vector.error as ProtocolError["reason"]);

    const decoder = new FrameDecoder();
    let fromDecoder: unknown;
    try {
      decoder.push(header);
    } catch (error) {
      fromDecoder = error;
    }
    expect((fromDecoder as ProtocolError).reason).toBe(vector.error as ProtocolError["reason"]);
  });

  test("a short header is truncated", () => {
    expect(() => parseHeader(new Uint8Array(11))).toThrow(ProtocolError);
    const decoder = new FrameDecoder();
    decoder.push(hex("41000000010000000400"));
    try {
      decoder.finish();
      throw new Error("expected finish() to throw");
    } catch (error) {
      expect((error as ProtocolError).reason).toBe("truncated");
    }
  });
});

describe("valid headers", () => {
  test.each(vectors.validHeaders.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    expect(parseHeader(hex(vector.header))).toEqual({
      kind: vector.kind as FrameKind,
      requestId: vector.requestId,
      payloadLength: vector.payloadLength,
    });
  });
});

describe("samples", () => {
  test("s16le encode", () => {
    expect(toHex(encodeSamples(vectors.samples.s16leEncode.floats, "s16le"))).toBe(vectors.samples.s16leEncode.hex);
  });

  test("s16le decode", () => {
    expect(Array.from(decodeSamples(hex(vectors.samples.s16leDecode.hex), "s16le"))).toEqual(
      vectors.samples.s16leDecode.floats,
    );
  });

  test("f32le encode and decode", () => {
    expect(toHex(encodeSamples(vectors.samples.f32le.floats, "f32le"))).toBe(vectors.samples.f32le.hex);
    expect(Array.from(decodeSamples(hex(vectors.samples.f32le.hex), "f32le"))).toEqual(vectors.samples.f32le.floats);
  });
});
