/**
 * Wire framing for the ark-voice socket protocol.
 *
 * Every message is a 12-byte header followed by its payload:
 *
 *     magic   u8    always 0x41 ('A')
 *     kind    u8    0 = JSON control, 1 = PCM audio
 *     flags   u16   reserved, must be zero
 *     request u32   little-endian request id
 *     length  u32   little-endian payload byte count
 */
import { ProtocolError } from "./errors.js";

/** Protocol revision carried in the handshake. */
export const PROTOCOL_VERSION = 1;
export const FRAME_MAGIC = 0x41;
export const HEADER_SIZE = 12;
/** Largest payload accepted in either direction (64 MiB, inclusive). */
export const MAX_PAYLOAD_SIZE = 64 * 1024 * 1024;
/** Uploads are split into PCM frames of at most this many bytes. */
export const UPLOAD_CHUNK_BYTES = 262_144;

export const FrameKind = {
  JSON: 0,
  PCM: 1,
} as const;
export type FrameKind = (typeof FrameKind)[keyof typeof FrameKind];

export interface Frame {
  kind: FrameKind;
  requestId: number;
  payload: Uint8Array;
}

export interface FrameHeader {
  kind: FrameKind;
  requestId: number;
  payloadLength: number;
}

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

function checkRequestId(requestId: number): void {
  if (!Number.isInteger(requestId) || requestId < 0 || requestId > 0xffff_ffff) {
    throw new RangeError(`Request id ${requestId} is not an unsigned 32-bit integer.`);
  }
}

/** Encodes one frame: header plus payload. */
export function encodeFrame(kind: FrameKind, requestId: number, payload: Uint8Array): Uint8Array {
  if (kind !== FrameKind.JSON && kind !== FrameKind.PCM) {
    throw new RangeError(`Unknown frame kind ${String(kind)}.`);
  }
  checkRequestId(requestId);
  if (payload.byteLength > MAX_PAYLOAD_SIZE) {
    throw new RangeError(
      `Frame payload of ${payload.byteLength} bytes exceeds the ${MAX_PAYLOAD_SIZE} byte limit.`,
    );
  }
  const frame = new Uint8Array(HEADER_SIZE + payload.byteLength);
  const view = new DataView(frame.buffer);
  view.setUint8(0, FRAME_MAGIC);
  view.setUint8(1, kind);
  view.setUint16(2, 0, true);
  view.setUint32(4, requestId, true);
  view.setUint32(8, payload.byteLength, true);
  frame.set(payload, HEADER_SIZE);
  return frame;
}

/**
 * Parses exactly `HEADER_SIZE` bytes.
 *
 * @throws ProtocolError with `reason` set to one of the frame error reasons.
 */
export function parseHeader(bytes: Uint8Array): FrameHeader {
  if (bytes.byteLength !== HEADER_SIZE) {
    throw new ProtocolError(
      `A frame header is ${HEADER_SIZE} bytes; got ${bytes.byteLength}.`,
      "truncated",
    );
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, HEADER_SIZE);
  const magic = view.getUint8(0);
  if (magic !== FRAME_MAGIC) {
    throw new ProtocolError(
      `Not an ark-voice frame: leading byte 0x${magic.toString(16)}.`,
      "bad-magic",
    );
  }
  const kind = view.getUint8(1);
  if (kind !== FrameKind.JSON && kind !== FrameKind.PCM) {
    throw new ProtocolError(`Unknown frame kind ${kind}.`, "unknown-kind");
  }
  const flags = view.getUint16(2, true);
  if (flags !== 0) {
    throw new ProtocolError(`Unsupported frame flags 0x${flags.toString(16)}.`, "unsupported-flags");
  }
  const requestId = view.getUint32(4, true);
  const payloadLength = view.getUint32(8, true);
  if (payloadLength > MAX_PAYLOAD_SIZE) {
    throw new ProtocolError(
      `Frame payload of ${payloadLength} bytes exceeds the ${MAX_PAYLOAD_SIZE} byte limit.`,
      "payload-too-large",
    );
  }
  return { kind, requestId, payloadLength };
}

/**
 * Reassembles frames from a byte stream split at arbitrary points.
 *
 * Feed bytes with `push`; it returns every frame completed so far. A bad
 * header throws a `ProtocolError` (after first returning any frames that
 * completed before it); from then on the decoder keeps throwing.
 */
export class FrameDecoder {
  #chunks: Uint8Array[] = [];
  #buffered = 0;
  #header: FrameHeader | undefined;
  #error: ProtocolError | undefined;

  /** The error that stopped this decoder, if any. */
  get error(): ProtocolError | undefined {
    return this.#error;
  }

  /** Bytes received but not yet returned as part of a frame. */
  get bufferedBytes(): number {
    return this.#buffered;
  }

  push(bytes: Uint8Array): Frame[] {
    if (this.#error) throw this.#error;
    if (bytes.byteLength > 0) {
      this.#chunks.push(bytes);
      this.#buffered += bytes.byteLength;
    }
    const frames: Frame[] = [];
    for (;;) {
      if (!this.#header) {
        if (this.#buffered < HEADER_SIZE) break;
        try {
          this.#header = parseHeader(this.#take(HEADER_SIZE));
        } catch (error) {
          this.#error = error as ProtocolError;
          // Hand back the frames completed before the bad header; the next
          // call reports the error.
          if (frames.length > 0) return frames;
          throw error;
        }
      }
      const header = this.#header;
      if (this.#buffered < header.payloadLength) break;
      this.#header = undefined;
      frames.push({
        kind: header.kind,
        requestId: header.requestId,
        payload: this.#take(header.payloadLength),
      });
    }
    return frames;
  }

  /**
   * Call at end of stream. Throws a `truncated` ProtocolError if a partial
   * frame is still buffered.
   */
  finish(): void {
    if (this.#error) throw this.#error;
    if (this.#header || this.#buffered > 0) {
      throw new ProtocolError("Frame ended before its declared payload was complete.", "truncated");
    }
  }

  /** Removes and returns the next `count` bytes as a fresh Uint8Array. */
  #take(count: number): Uint8Array {
    const out = new Uint8Array(count);
    let filled = 0;
    while (filled < count) {
      const head = this.#chunks[0]!;
      const needed = count - filled;
      if (head.byteLength <= needed) {
        out.set(head, filled);
        filled += head.byteLength;
        this.#chunks.shift();
      } else {
        out.set(head.subarray(0, needed), filled);
        this.#chunks[0] = head.subarray(needed);
        filled += needed;
      }
    }
    this.#buffered -= count;
    return out;
  }
}

/** A control message as plain JSON. */
export type JsonMessage = Record<string, unknown>;

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === "object") {
    const source = value as Record<string, unknown>;
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(source).sort()) {
      const entry = source[key];
      if (entry === undefined || entry === null) continue;
      sorted[key] = canonical(entry);
    }
    return sorted;
  }
  return value;
}

/**
 * Encodes a control message the way every binding does: compact, keys
 * sorted, absent (`null`/`undefined`) fields omitted, non-ASCII as raw UTF-8.
 */
export function encodeMessage(message: JsonMessage): Uint8Array {
  return textEncoder.encode(JSON.stringify(canonical(message)));
}

/**
 * Decodes a server control message. It must be a JSON object with a string
 * `event` field.
 *
 * @throws ProtocolError for invalid UTF-8, invalid JSON, or a missing `event`.
 */
export function decodeMessage(payload: Uint8Array): JsonMessage {
  let parsed: unknown;
  try {
    parsed = JSON.parse(textDecoder.decode(payload));
  } catch (error) {
    throw new ProtocolError("The server sent a control message that is not valid JSON.", undefined, {
      cause: error,
    });
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new ProtocolError("The server sent a control message that is not a JSON object.");
  }
  if (typeof (parsed as JsonMessage)["event"] !== "string") {
    throw new ProtocolError("The server sent a control message without an 'event' field.");
  }
  return parsed as JsonMessage;
}

/** Encodes a control message as a complete JSON frame. */
export function encodeMessageFrame(requestId: number, message: JsonMessage): Uint8Array {
  return encodeFrame(FrameKind.JSON, requestId, encodeMessage(message));
}
