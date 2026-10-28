/**
 * `ArkVoiceClient`: a pipelining client for `ark-voice serve`.
 *
 * One reader routes every incoming frame by request id to a per-request
 * channel that buffers until the caller consumes it. Requests are written to
 * the socket when the method is called, so several can be in flight at once.
 */
import { existsSync, readFileSync } from "node:fs";
import { createConnection, type Socket } from "node:net";

import { PCMAudio, SYNTHESIS_SAMPLE_RATE, bytesPerSample, decodeWav, type SampleFormat } from "./audio.js";
import {
  ArkVoiceError,
  ConnectionClosedError,
  NotRunningError,
  ProtocolError,
  UnsupportedVersionError,
  serverErrorFor,
} from "./errors.js";
import {
  FrameDecoder,
  FrameKind,
  PROTOCOL_VERSION,
  UPLOAD_CHUNK_BYTES,
  decodeMessage,
  encodeFrame,
  encodeMessageFrame,
  type Frame,
  type JsonMessage,
} from "./frame.js";
import { resolveSocketPath } from "./socket-path.js";

/** Recognizer names the server knows. Any string is accepted; the server refuses unknown ones. */
export type STTModel = "parakeet" | "parakeet-ultra" | "qwen" | (string & {});

export interface ConnectOptions {
  /** Socket path. Defaults to `ARK_VOICE_SOCKET`, else `~/.ark-voice-cli/ark-voice.sock`. */
  socketPath?: string;
  /** Aborts connecting and the handshake. */
  signal?: AbortSignal;
}

export interface RequestOptions {
  /** Aborting sends `cancel` for the request and rejects with the signal's reason. */
  signal?: AbortSignal;
}

export interface SynthesizeOptions extends RequestOptions {
  /** A saved voice profile. Omit for the built-in voice. */
  voice?: string;
  /** Sample encoding of the returned audio. Default `s16le`. */
  format?: SampleFormat;
}

export interface TranscribeOptions extends RequestOptions {
  /** Recognizer to use. Omit for the server's default. */
  model?: STTModel;
}

export interface AudioChunkEvent {
  type: "audio";
  audio: PCMAudio;
  /** Zero-based position of this chunk in the utterance. */
  index: number;
}

export interface SynthesisDoneEvent {
  type: "done";
  chunks: number;
  samples: number;
  seconds: number;
  sampleRate: number;
}

export type SynthesisEvent = AudioChunkEvent | SynthesisDoneEvent;

export type TranscriptEvent = { type: "partial"; text: string } | { type: "final"; text: string };

export interface SynthesisResult {
  /** Every chunk joined. */
  audio: PCMAudio;
  summary: SynthesisDoneEvent;
}

export interface ServerStatus {
  version: number;
  synthesisModelLoaded: boolean;
  transcriptionModelLoaded: boolean;
  /** The resident recognizer, or `null` when none is loaded. */
  transcriptionModel: string | null;
  requestsServed: number;
  uptimeSeconds: number;
}

/**
 * A request's event stream. It is an async iterator: `for await` it, and
 * break out (or call `return()` / `cancel()`) to stop early, which sends
 * `cancel` for the request if it is still running and discards the rest of
 * its frames. Each stream can be iterated once.
 */
export interface RequestEventStream<T> extends AsyncIterableIterator<T, undefined, undefined> {
  /** The request id on the wire; `0` if the request was never sent. */
  readonly requestId: number;
  next(): Promise<IteratorResult<T, undefined>>;
  /** Stops early, cancelling the request if the server is still working on it. */
  return(): Promise<IteratorResult<T, undefined>>;
  /** Same as `return()`. */
  cancel(): Promise<void>;
  [Symbol.asyncIterator](): RequestEventStream<T>;
}

/** Events of one synthesis request: audio chunks, then a `done` summary. */
export interface SynthesisStream extends RequestEventStream<SynthesisEvent> {
  /** Sample rate of the audio chunks (from `audio-format`; 24000 until it arrives). */
  readonly sampleRate: number;
  /** Sample format of the audio chunks. */
  readonly format: SampleFormat;
}

/** Events of one transcription request: partial and final text. Ends after the server's `done`. */
export type TranscriptStream = RequestEventStream<TranscriptEvent>;

type Item = { kind: "json"; message: JsonMessage } | { kind: "pcm"; data: Uint8Array };

function abortReason(signal: AbortSignal): unknown {
  return signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
}

function str(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function num(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/**
 * The client side of one request: frames routed to it wait here until the
 * caller reads them.
 */
class Channel {
  /** `0` when the request was never sent. */
  readonly id: number;
  readonly terminalEvents: ReadonlySet<string>;
  /** A terminal event has been received (it may still be queued). */
  terminalReceived = false;
  /** `cancel` was sent; frames are discarded until the terminal event. */
  draining = false;
  /** The consumer is finished with this request. */
  settled = false;
  failure: unknown;
  hasFailure = false;
  #queue: Item[] = [];
  #waiters: Array<() => void> = [];
  #cleanups: Array<() => void> = [];

  constructor(id: number, terminalEvents: ReadonlySet<string>) {
    this.id = id;
    this.terminalEvents = terminalEvents;
  }

  /** True while a `cancel` would still mean something to the server. */
  get cancellable(): boolean {
    return this.id !== 0 && !this.terminalReceived && !this.hasFailure && !this.draining;
  }

  push(item: Item): void {
    if (this.draining || this.settled) return;
    this.#queue.push(item);
    this.#wake();
  }

  /** Fails the request once its buffered items are consumed. */
  fail(error: unknown): void {
    if (this.hasFailure) return;
    this.failure = error;
    this.hasFailure = true;
    this.#wake();
  }

  /** Fails the request immediately, dropping anything buffered. */
  abort(reason: unknown): void {
    this.#queue = [];
    this.failure = reason;
    this.hasFailure = true;
    this.#wake();
  }

  dropBuffered(): void {
    this.#queue = [];
  }

  onSettle(cleanup: () => void): void {
    this.#cleanups.push(cleanup);
  }

  /** Marks the consumer finished and releases listeners. */
  settle(): void {
    if (this.settled) return;
    this.settled = true;
    this.#queue = [];
    for (const cleanup of this.#cleanups.splice(0)) cleanup();
    this.#wake();
  }

  /** The next buffered item; `undefined` once the terminal event has been consumed. */
  async next(): Promise<Item | undefined> {
    for (;;) {
      const item = this.#queue.shift();
      if (item) return item;
      if (this.hasFailure) throw this.failure;
      if (this.terminalReceived || this.settled) return undefined;
      await new Promise<void>((resolve) => this.#waiters.push(resolve));
    }
  }

  #wake(): void {
    for (const waiter of this.#waiters.splice(0)) waiter();
  }
}

function serverErrorFrom(message: JsonMessage, requestId: number): Error {
  return serverErrorFor(
    str(message["code"]) ?? "failed",
    str(message["message"]) ?? "The server reported a failure.",
    requestId,
  );
}

type StopRequest = (channel: Channel) => void;

/** Shared async-iterator plumbing: `return()` and errors cancel the request if it is still running. */
abstract class RequestStream<T> implements RequestEventStream<T> {
  protected readonly channel: Channel;
  readonly #stop: StopRequest;
  #finished = false;

  constructor(channel: Channel, stop: StopRequest) {
    this.channel = channel;
    this.#stop = stop;
  }

  /** The request id on the wire; `0` if the request was never sent. */
  get requestId(): number {
    return this.channel.id;
  }

  /** Handles one item: return an event to yield, `null` to skip, or `"end"` to finish. */
  protected abstract handle(item: Item): T | null | "end";

  async next(): Promise<IteratorResult<T, undefined>> {
    if (this.#finished) return { done: true, value: undefined };
    try {
      for (;;) {
        const item = await this.channel.next();
        if (item === undefined) {
          this.#finish();
          return { done: true, value: undefined };
        }
        const result = this.handle(item);
        if (result === null) continue;
        if (result === "end") {
          this.#finish();
          return { done: true, value: undefined };
        }
        if (item.kind === "json" && this.channel.terminalReceived && this.#isTerminal(item.message)) {
          this.#finish();
        }
        return { done: false, value: result };
      }
    } catch (error) {
      this.#finish();
      throw error;
    }
  }

  /** Stops early: sends `cancel` if the request is still running and discards its remaining frames. */
  async return(): Promise<IteratorResult<T, undefined>> {
    this.#finish();
    return { done: true, value: undefined };
  }

  /** Same as breaking out of the loop. */
  async cancel(): Promise<void> {
    await this.return();
  }

  [Symbol.asyncIterator](): this {
    return this;
  }

  #isTerminal(message: JsonMessage): boolean {
    const event = str(message["event"]);
    return event === "error" || (event !== undefined && this.channel.terminalEvents.has(event));
  }

  #finish(): void {
    if (this.#finished) return;
    this.#finished = true;
    this.#stop(this.channel);
  }
}

class SynthesisStreamImpl extends RequestStream<SynthesisEvent> implements SynthesisStream {
  #format: SampleFormat;
  #sampleRate = SYNTHESIS_SAMPLE_RATE;
  #index = 0;

  constructor(channel: Channel, stop: StopRequest, format: SampleFormat) {
    super(channel, stop);
    this.#format = format;
  }

  /** Sample rate of the audio chunks (from `audio-format`; 24000 until it arrives). */
  get sampleRate(): number {
    return this.#sampleRate;
  }

  /** Sample format of the audio chunks. */
  get format(): SampleFormat {
    return this.#format;
  }

  protected handle(item: Item): SynthesisEvent | null | "end" {
    if (item.kind === "pcm") {
      if (item.data.byteLength % bytesPerSample(this.#format) !== 0) {
        throw new ProtocolError(
          `The server sent ${item.data.byteLength} bytes, not a whole number of ${this.#format} samples.`,
        );
      }
      return { type: "audio", audio: new PCMAudio(item.data, this.#sampleRate, this.#format), index: this.#index++ };
    }
    const message = item.message;
    switch (message["event"]) {
      case "audio-format": {
        const rate = num(message["sampleRate"]);
        if (rate !== undefined && Number.isInteger(rate) && rate > 0) this.#sampleRate = rate;
        const format = message["format"];
        if (format === "s16le" || format === "f32le") this.#format = format;
        return null;
      }
      case "done": {
        const samples = num(message["samples"]) ?? 0;
        return {
          type: "done",
          chunks: num(message["chunks"]) ?? this.#index,
          samples,
          seconds: num(message["seconds"]) ?? samples / this.#sampleRate,
          sampleRate: this.#sampleRate,
        };
      }
      case "error":
        throw serverErrorFrom(message, this.channel.id);
      default:
        return null;
    }
  }
}

class TranscriptStreamImpl extends RequestStream<TranscriptEvent> {
  protected handle(item: Item): TranscriptEvent | null | "end" {
    if (item.kind === "pcm") return null;
    const message = item.message;
    switch (message["event"]) {
      case "partial":
        return { type: "partial", text: str(message["text"]) ?? "" };
      case "final":
        return { type: "final", text: str(message["text"]) ?? "" };
      case "done":
        return "end";
      case "error":
        throw serverErrorFrom(message, this.channel.id);
      default:
        return null;
    }
  }
}

const TERMINAL = {
  hello: new Set(["hello-ok"]),
  tts: new Set(["done"]),
  stt: new Set(["done"]),
  "create-voice": new Set(["done"]),
  voices: new Set(["voices"]),
  status: new Set(["status"]),
  unload: new Set(["done"]),
} as const;

function openSocket(path: string, signal?: AbortSignal): Promise<Socket> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortReason(signal));
      return;
    }
    const socket = createConnection({ path });
    const onAbort = (): void => {
      socket.destroy();
      cleanup();
      reject(abortReason(signal!));
    };
    const onConnect = (): void => {
      cleanup();
      resolve(socket);
    };
    const onError = (error: NodeJS.ErrnoException): void => {
      cleanup();
      socket.destroy();
      if (error.code === "ENOENT" || error.code === "ECONNREFUSED") {
        reject(new NotRunningError(path, { cause: error }));
      } else {
        reject(new ArkVoiceError(`Could not connect to ${path}: ${error.message}`, { cause: error }));
      }
    };
    const cleanup = (): void => {
      socket.off("connect", onConnect);
      socket.off("error", onError);
      signal?.removeEventListener("abort", onAbort);
    };
    socket.once("connect", onConnect);
    socket.once("error", onError);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

/** A connection to `ark-voice serve`. Create one with `ArkVoiceClient.connect()`. */
export class ArkVoiceClient {
  readonly socketPath: string;
  #serverVersion = PROTOCOL_VERSION;
  #sampleRate = SYNTHESIS_SAMPLE_RATE;

  readonly #socket: Socket;
  readonly #decoder = new FrameDecoder();
  readonly #pending = new Map<number, Channel>();
  #nextId = 1;
  #closed = false;
  #closeReason: unknown;
  #socketClosed: Promise<void>;

  private constructor(socket: Socket, socketPath: string) {
    this.#socket = socket;
    this.socketPath = socketPath;
    this.#socketClosed = new Promise((resolve) => socket.once("close", () => resolve()));
    socket.on("data", (chunk: Uint8Array) => this.#receive(chunk));
    socket.on("error", (error) => {
      this.#shutdown(new ConnectionClosedError(`The connection failed: ${error.message}`, { cause: error }));
    });
    socket.on("close", () => {
      let cause: unknown;
      try {
        this.#decoder.finish();
      } catch (error) {
        cause = error;
      }
      this.#shutdown(
        new ConnectionClosedError(
          cause
            ? "The server closed the connection in the middle of a frame."
            : "The server closed the connection.",
          cause ? { cause } : undefined,
        ),
      );
    });
  }

  /**
   * Connects and performs the `hello` handshake.
   *
   * @throws NotRunningError if nothing is listening on the socket path.
   * @throws UnsupportedVersionError if the server speaks another protocol version.
   */
  static async connect(options: ConnectOptions = {}): Promise<ArkVoiceClient> {
    const socketPath = resolveSocketPath(options.socketPath);
    if (!existsSync(socketPath)) throw new NotRunningError(socketPath);
    const socket = await openSocket(socketPath, options.signal);
    const client = new ArkVoiceClient(socket, socketPath);
    try {
      await client.#handshake(options.signal);
    } catch (error) {
      client.#shutdown(new ConnectionClosedError("The handshake failed.", { cause: error }));
      throw error;
    }
    return client;
  }

  /** Protocol version reported in `hello-ok`. */
  get serverVersion(): number {
    return this.#serverVersion;
  }

  /** Synthesis sample rate reported in `hello-ok` (24000 if absent). */
  get sampleRate(): number {
    return this.#sampleRate;
  }

  /** True once the connection is closed, by either side. */
  get closed(): boolean {
    return this.#closed;
  }

  /**
   * Synthesizes `text`, yielding audio chunks as they are generated and a
   * `done` summary last. Breaking out of the loop cancels the request.
   */
  synthesize(text: string, options: SynthesizeOptions = {}): SynthesisStream {
    const format = options.format ?? "s16le";
    const channel = this.#open(
      { op: "tts", text, voice: options.voice, format },
      TERMINAL.tts,
      options.signal,
    );
    return new SynthesisStreamImpl(channel, this.#stopFn, format);
  }

  /** Synthesizes `text` and returns all of its audio joined, plus the summary. */
  async synthesizeAudio(text: string, options: SynthesizeOptions = {}): Promise<SynthesisResult> {
    const stream = this.synthesize(text, options);
    const chunks: PCMAudio[] = [];
    let summary: SynthesisDoneEvent | undefined;
    for await (const event of stream) {
      if (event.type === "audio") chunks.push(event.audio);
      else summary = event;
    }
    if (!summary) throw new ProtocolError("The synthesis ended without a summary.");
    const audio = PCMAudio.concat(chunks, { sampleRate: stream.sampleRate, format: stream.format });
    return { audio, summary };
  }

  /** Synthesizes `text` into a WAV file at `path` and returns the summary. */
  async synthesizeToWav(text: string, path: string, options: SynthesizeOptions = {}): Promise<SynthesisDoneEvent> {
    const { audio, summary } = await this.synthesizeAudio(text, options);
    await audio.writeWav(path);
    return summary;
  }

  /**
   * Transcribes `audio`, yielding partial and final text; ends after the
   * server's `done`. Any declared sample rate is accepted.
   */
  transcribe(audio: PCMAudio, options: TranscribeOptions = {}): TranscriptStream {
    const channel = this.#open(
      { op: "stt", format: audio.format, sampleRate: audio.sampleRate, model: options.model },
      TERMINAL.stt,
      options.signal,
      audio,
    );
    return new TranscriptStreamImpl(channel, this.#stopFn);
  }

  /** Transcribes `audio` and returns the final text (`""` if there was none). */
  async transcribeText(audio: PCMAudio, options: TranscribeOptions = {}): Promise<string> {
    let text = "";
    for await (const event of this.transcribe(audio, options)) {
      if (event.type === "final") text = event.text;
    }
    return text;
  }

  /** Transcribes a WAV file; the same stream as `transcribe`. File errors surface on iteration. */
  transcribeFile(path: string, options: TranscribeOptions = {}): TranscriptStream {
    let audio: PCMAudio;
    try {
      const bytes = readFileSync(path);
      audio = decodeWav(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength));
    } catch (error) {
      const channel = new Channel(0, TERMINAL.stt);
      channel.fail(error);
      return new TranscriptStreamImpl(channel, this.#stopFn);
    }
    return this.transcribe(audio, options);
  }

  /** Saves a voice profile from reference audio and returns the profile's path on the server. */
  async createVoice(name: string, audio: PCMAudio, options: RequestOptions = {}): Promise<string> {
    const channel = this.#open(
      { op: "create-voice", name, format: audio.format, sampleRate: audio.sampleRate },
      TERMINAL["create-voice"],
      options.signal,
      audio,
    );
    let path = "";
    await this.#collect(channel, (message) => {
      if (message["event"] === "voice-created") path = str(message["path"]) ?? "";
    });
    return path;
  }

  /** Names of the saved voice profiles. */
  async voices(options: RequestOptions = {}): Promise<string[]> {
    const channel = this.#open({ op: "voices" }, TERMINAL.voices, options.signal);
    const reply = await this.#collect(channel);
    const names = reply["names"];
    return Array.isArray(names) ? names.filter((name): name is string => typeof name === "string") : [];
  }

  /** What the server has loaded and how long it has been up. */
  async status(options: RequestOptions = {}): Promise<ServerStatus> {
    const channel = this.#open({ op: "status" }, TERMINAL.status, options.signal);
    const reply = await this.#collect(channel);
    return {
      version: num(reply["version"]) ?? PROTOCOL_VERSION,
      synthesisModelLoaded: reply["synthesisModelLoaded"] === true,
      transcriptionModelLoaded: reply["transcriptionModelLoaded"] === true,
      transcriptionModel: str(reply["transcriptionModel"]) ?? null,
      requestsServed: num(reply["requestsServed"]) ?? 0,
      uptimeSeconds: num(reply["uptimeSeconds"]) ?? 0,
    };
  }

  /** Releases the server's resident models; the next request reloads them. */
  async unload(options: RequestOptions = {}): Promise<void> {
    const channel = this.#open({ op: "unload" }, TERMINAL.unload, options.signal);
    await this.#collect(channel);
  }

  /** Closes the connection. Pending requests fail with `ConnectionClosedError`. */
  async close(): Promise<void> {
    if (!this.#closed) {
      this.#shutdown(new ConnectionClosedError("The client closed the connection."), false);
      // Half-close so frames already written (such as a cancel) still reach the server.
      this.#socket.end();
      const timer = setTimeout(() => this.#socket.destroy(), 2000);
      timer.unref?.();
      await this.#socketClosed;
      clearTimeout(timer);
      return;
    }
    await this.#socketClosed;
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }

  // -- plumbing -----------------------------------------------------------

  async #handshake(signal?: AbortSignal): Promise<void> {
    const channel = this.#open({ op: "hello", version: PROTOCOL_VERSION }, TERMINAL.hello, signal);
    const reply = await this.#collect(channel);
    const version = num(reply["version"]);
    if (version !== PROTOCOL_VERSION) {
      throw new UnsupportedVersionError(
        "unsupported-version",
        `The server speaks protocol version ${String(version)}; this client speaks ${PROTOCOL_VERSION}.`,
        channel.id,
      );
    }
    this.#serverVersion = version;
    const rate = num(reply["sampleRate"]);
    this.#sampleRate = rate !== undefined && rate > 0 ? rate : SYNTHESIS_SAMPLE_RATE;
  }

  /** Reads a request to its terminal event and returns that event; throws on `error`. */
  async #collect(channel: Channel, onMessage?: (message: JsonMessage) => void): Promise<JsonMessage> {
    try {
      for (;;) {
        const item = await channel.next();
        if (item === undefined) throw new ProtocolError("The request ended without a reply.");
        if (item.kind !== "json") continue;
        const message = item.message;
        const event = str(message["event"]);
        if (event === "error") throw serverErrorFrom(message, channel.id);
        onMessage?.(message);
        if (event !== undefined && channel.terminalEvents.has(event)) return message;
      }
    } finally {
      this.#stop(channel);
    }
  }

  #closedError(): ConnectionClosedError {
    const reason = this.#closeReason;
    if (reason instanceof ConnectionClosedError) return reason;
    return new ConnectionClosedError("The connection to the ark-voice server is closed.", { cause: reason });
  }

  #takeId(): number {
    for (;;) {
      const id = this.#nextId;
      this.#nextId = id >= 0xffff_ffff ? 1 : id + 1;
      if (!this.#pending.has(id)) return id;
    }
  }

  /** Registers a request and writes it (and any upload) to the socket now. */
  #open(message: JsonMessage, terminal: ReadonlySet<string>, signal?: AbortSignal, upload?: PCMAudio): Channel {
    if (signal?.aborted) {
      const channel = new Channel(0, terminal);
      channel.fail(abortReason(signal));
      return channel;
    }
    if (this.#closed) {
      const channel = new Channel(0, terminal);
      channel.fail(this.#closedError());
      return channel;
    }

    const id = this.#takeId();
    const channel = new Channel(id, terminal);
    this.#pending.set(id, channel);
    this.#write(encodeMessageFrame(id, message));
    if (upload) {
      const data = upload.data;
      for (let offset = 0; offset < data.byteLength; offset += UPLOAD_CHUNK_BYTES) {
        this.#write(encodeFrame(FrameKind.PCM, id, data.subarray(offset, offset + UPLOAD_CHUNK_BYTES)));
      }
      this.#write(encodeMessageFrame(id, { op: "end" }));
    }

    if (signal) {
      const onAbort = (): void => {
        if (channel.settled) return;
        this.#cancel(channel);
        channel.abort(abortReason(signal));
      };
      signal.addEventListener("abort", onAbort, { once: true });
      channel.onSettle(() => signal.removeEventListener("abort", onAbort));
    }
    return channel;
  }

  #write(bytes: Uint8Array): void {
    if (this.#closed) return;
    this.#socket.write(bytes);
  }

  readonly #stopFn: StopRequest = (channel) => this.#stop(channel);

  /** The consumer is done with `channel`: cancel it if the server is still working on it. */
  #stop(channel: Channel): void {
    if (channel.settled) return;
    this.#cancel(channel);
    channel.settle();
  }

  /** Sends `cancel` and switches the request to draining until its terminal event. */
  #cancel(channel: Channel): void {
    if (!channel.cancellable) return;
    channel.draining = true;
    channel.dropBuffered();
    if (this.#closed) return;
    this.#write(encodeMessageFrame(channel.id, { op: "cancel" }));
  }

  #receive(chunk: Uint8Array): void {
    if (this.#closed) return;
    let frames: Frame[];
    try {
      frames = this.#decoder.push(chunk);
    } catch (error) {
      this.#shutdown(error);
      return;
    }
    for (const frame of frames) {
      if (this.#closed) return;
      try {
        this.#route(frame);
      } catch (error) {
        this.#shutdown(error);
        return;
      }
    }
    if (this.#decoder.error) this.#shutdown(this.#decoder.error);
  }

  #route(frame: Frame): void {
    if (frame.requestId === 0) {
      if (frame.kind !== FrameKind.JSON) return;
      const message = decodeMessage(frame.payload);
      if (message["event"] === "error") this.#shutdown(serverErrorFrom(message, 0));
      return;
    }
    const channel = this.#pending.get(frame.requestId);
    if (!channel) return;
    if (frame.kind === FrameKind.PCM) {
      channel.push({ kind: "pcm", data: frame.payload });
      return;
    }
    const message = decodeMessage(frame.payload);
    const event = str(message["event"]);
    if (event === "error" || (event !== undefined && channel.terminalEvents.has(event))) {
      this.#pending.delete(frame.requestId);
      channel.terminalReceived = true;
    }
    channel.push({ kind: "json", message });
  }

  /** Fails every pending request with `reason` and closes the socket. */
  #shutdown(reason: unknown, destroy = true): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#closeReason = reason;
    const channels = [...this.#pending.values()];
    this.#pending.clear();
    for (const channel of channels) channel.fail(reason);
    if (destroy) this.#socket.destroy();
  }
}
