/**
 * A scripted stand-in for `ark-voice serve` on a temporary Unix socket.
 *
 * Each test supplies a handler that sees every frame the client sends and
 * answers however the test needs. By default `hello` is answered with
 * `hello-ok` before the handler runs.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { join } from "node:path";

import { FrameDecoder, FrameKind, encodeFrame, type Frame, type JsonMessage } from "../src/index.js";

export interface ReceivedFrame extends Frame {
  /** Parsed JSON for kind-0 frames. */
  message?: JsonMessage;
}

export type FrameHandler = (frame: ReceivedFrame, connection: FakeConnection) => void;

export interface FakeServerOptions {
  /** Answer `hello` with this `hello-ok`, or pass `false` to let the handler do it. */
  helloReply?: JsonMessage | false;
}

export class FakeConnection {
  readonly received: ReceivedFrame[] = [];
  readonly #socket: Socket;
  readonly #decoder = new FrameDecoder();
  readonly #waiters: Array<() => void> = [];

  constructor(socket: Socket, handler: FrameHandler, helloReply: JsonMessage | false) {
    this.#socket = socket;
    socket.on("error", () => {});
    socket.on("data", (chunk: Uint8Array) => {
      for (const frame of this.#decoder.push(chunk)) {
        const received: ReceivedFrame = { ...frame };
        if (frame.kind === FrameKind.JSON) {
          received.message = JSON.parse(new TextDecoder().decode(frame.payload)) as JsonMessage;
        }
        this.received.push(received);
        if (helloReply !== false && received.message?.["op"] === "hello") {
          this.sendJson(frame.requestId, helloReply);
        } else {
          handler(received, this);
        }
        for (const wake of this.#waiters.splice(0)) wake();
      }
    });
  }

  /** JSON messages received, in order. */
  get messages(): Array<{ requestId: number; message: JsonMessage }> {
    return this.received
      .filter((frame) => frame.message !== undefined)
      .map((frame) => ({ requestId: frame.requestId, message: frame.message! }));
  }

  /** Resolves once a received frame matches `predicate`. */
  async waitFor(predicate: (frame: ReceivedFrame) => boolean, timeoutMs = 3000): Promise<ReceivedFrame> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const found = this.received.find(predicate);
      if (found) return found;
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error("Timed out waiting for a frame from the client.");
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, remaining);
        this.#waiters.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }

  sendJson(requestId: number, message: JsonMessage): void {
    this.sendRaw(encodeFrame(FrameKind.JSON, requestId, new TextEncoder().encode(JSON.stringify(message))));
  }

  sendPcm(requestId: number, payload: Uint8Array): void {
    this.sendRaw(encodeFrame(FrameKind.PCM, requestId, payload));
  }

  sendRaw(bytes: Uint8Array): void {
    this.#socket.write(bytes);
  }

  pauseReads(): void { this.#socket.pause(); }
  resumeReads(): void { this.#socket.resume(); }

  /** Closes the connection from the server side (the client sees EOF). */
  end(): void {
    this.#socket.end();
  }

  destroy(): void {
    this.#socket.destroy();
  }
}

export class FakeServer {
  readonly path: string;
  readonly connections: FakeConnection[] = [];
  readonly #dir: string;
  readonly #server: Server;
  readonly #waiters: Array<() => void> = [];

  private constructor(dir: string, server: Server) {
    this.#dir = dir;
    this.path = join(dir, "fake.sock");
    this.#server = server;
  }

  static async start(handler: FrameHandler = () => {}, options: FakeServerOptions = {}): Promise<FakeServer> {
    // Under /tmp, not $TMPDIR: macOS caps socket paths at 104 bytes.
    const dir = mkdtempSync("/tmp/arkv-ts-");
    const helloReply = options.helloReply ?? { event: "hello-ok", version: 1, sampleRate: 24000 };
    let fake!: FakeServer;
    const server = createServer((socket) => {
      fake.connections.push(new FakeConnection(socket, handler, helloReply));
      for (const wake of fake.#waiters.splice(0)) wake();
    });
    fake = new FakeServer(dir, server);
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(fake.path, () => resolve());
    });
    return fake;
  }

  /** The first (usually only) connection, once it exists. */
  async connection(index = 0): Promise<FakeConnection> {
    while (!this.connections[index]) {
      await new Promise<void>((resolve) => this.#waiters.push(resolve));
    }
    return this.connections[index]!;
  }

  async stop(): Promise<void> {
    for (const connection of this.connections) connection.destroy();
    await new Promise<void>((resolve) => this.#server.close(() => resolve()));
    rmSync(this.#dir, { recursive: true, force: true });
  }
}

/** Hex string to bytes. */
export function hex(text: string): Uint8Array {
  const out = new Uint8Array(text.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = Number.parseInt(text.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/** Bytes to hex string. */
export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
