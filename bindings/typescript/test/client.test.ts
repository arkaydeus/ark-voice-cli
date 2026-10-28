/**
 * Client behaviour against a scripted fake server on a temporary Unix socket.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import {
  ArkVoiceClient,
  ArkVoiceError,
  BadRequestError,
  ConnectionClosedError,
  ModelsMissingError,
  NotRunningError,
  PCMAudio,
  ProtocolError,
  RequestCancelledError,
  ServerError,
  ServerFailedError,
  UnknownRequestError,
  UnsupportedVersionError,
  defaultSocketPath,
  encodeSamples,
  resolveSocketPath,
  type SynthesisEvent,
  type TranscriptEvent,
} from "../src/index.js";
import { FakeServer, hex, type FakeConnection, type FrameHandler } from "./fake-server.js";

const HELLO_FRAME = "41000000010000001a0000007b226f70223a2268656c6c6f222c2276657273696f6e223a317d";

let servers: FakeServer[] = [];
let clients: ArkVoiceClient[] = [];

afterEach(async () => {
  for (const client of clients) await client.close();
  for (const server of servers) await server.stop();
  clients = [];
  servers = [];
});

async function serve(handler?: FrameHandler, options?: Parameters<typeof FakeServer.start>[1]) {
  const server = await FakeServer.start(handler, options);
  servers.push(server);
  return server;
}

async function connect(server: FakeServer): Promise<{ client: ArkVoiceClient; connection: FakeConnection }> {
  const client = await ArkVoiceClient.connect({ socketPath: server.path });
  clients.push(client);
  return { client, connection: await server.connection() };
}

async function rejection(promise: Promise<unknown>): Promise<unknown> {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error("Expected the promise to reject.");
}

async function collect<T>(stream: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = [];
  for await (const item of stream) out.push(item);
  return out;
}

/** Answers housekeeping requests the way the real server does. */
const housekeeping: FrameHandler = (frame, connection) => {
  switch (frame.message?.["op"]) {
    case "status":
      connection.sendJson(frame.requestId, {
        event: "status",
        version: 1,
        synthesisModelLoaded: false,
        transcriptionModelLoaded: false,
        requestsServed: 1,
        uptimeSeconds: 0.5,
      });
      break;
    case "voices":
      connection.sendJson(frame.requestId, { event: "voices", names: ["narrator", "robot"] });
      break;
    case "unload":
      connection.sendJson(frame.requestId, { event: "done" });
      break;
  }
};

describe("errors", () => {
  test("every class has its name and instanceof chain", () => {
    const cases: Array<[ServerError, string, Function]> = [
      [new BadRequestError("bad-request", "m", 1), "BadRequestError", BadRequestError],
      [new UnsupportedVersionError("unsupported-version", "m", 1), "UnsupportedVersionError", UnsupportedVersionError],
      [new ModelsMissingError("models-missing", "m", 1), "ModelsMissingError", ModelsMissingError],
      [new UnknownRequestError("unknown-request", "m", 1), "UnknownRequestError", UnknownRequestError],
      [new RequestCancelledError("cancelled", "m", 1), "RequestCancelledError", RequestCancelledError],
      [new ServerFailedError("failed", "m", 1), "ServerFailedError", ServerFailedError],
      [new ServerError("whatever", "m", 1), "ServerError", ServerError],
    ];
    for (const [error, name, ErrorClass] of cases) {
      expect(error.name).toBe(name);
      expect(error).toBeInstanceOf(ErrorClass);
      expect(error).toBeInstanceOf(ServerError);
      expect(error).toBeInstanceOf(ArkVoiceError);
      expect(error).toBeInstanceOf(Error);
      expect(String(error)).toBe(`${name}: m`);
    }
    const others: Array<[Error, string]> = [
      [new NotRunningError("/x"), "NotRunningError"],
      [new ConnectionClosedError(), "ConnectionClosedError"],
      [new ProtocolError("p", "bad-magic"), "ProtocolError"],
      [new ArkVoiceError("a"), "ArkVoiceError"],
    ];
    for (const [error, name] of others) {
      expect(error.name).toBe(name);
      expect(error).toBeInstanceOf(ArkVoiceError);
      expect(error).not.toBeInstanceOf(ServerError);
    }
    expect(new NotRunningError("/x").message).toContain("ark-voice serve");
  });
});

describe("socket path", () => {
  test("explicit beats ARK_VOICE_SOCKET beats the default", () => {
    const had = Object.hasOwn(process.env, "ARK_VOICE_SOCKET");
    const previous = process.env["ARK_VOICE_SOCKET"];
    try {
      delete process.env["ARK_VOICE_SOCKET"];
      expect(defaultSocketPath()).toBe(join(homedir(), ".ark-voice-cli", "ark-voice.sock"));
      expect(resolveSocketPath()).toBe(defaultSocketPath());
      process.env["ARK_VOICE_SOCKET"] = "/tmp/from-env.sock";
      expect(resolveSocketPath()).toBe("/tmp/from-env.sock");
      expect(resolveSocketPath("/tmp/explicit.sock")).toBe("/tmp/explicit.sock");
    } finally {
      if (had) process.env["ARK_VOICE_SOCKET"] = previous;
      else delete process.env["ARK_VOICE_SOCKET"];
    }
  });

  test("connect uses ARK_VOICE_SOCKET", async () => {
    const server = await serve();
    const had = Object.hasOwn(process.env, "ARK_VOICE_SOCKET");
    const previous = process.env["ARK_VOICE_SOCKET"];
    try {
      process.env["ARK_VOICE_SOCKET"] = server.path;
      const client = await ArkVoiceClient.connect();
      clients.push(client);
      expect(client.socketPath).toBe(server.path);
    } finally {
      if (had) process.env["ARK_VOICE_SOCKET"] = previous;
      else delete process.env["ARK_VOICE_SOCKET"];
    }
  });

  test("a missing socket is NotRunningError", async () => {
    const error = await rejection(ArkVoiceClient.connect({ socketPath: "/tmp/arkv-ts-does-not-exist.sock" }));
    expect(error).toBeInstanceOf(NotRunningError);
    expect((error as Error).message).toContain("ark-voice serve");
  });

  test("a stale socket nobody listens on (ECONNREFUSED) is NotRunningError", async () => {
    const dir = mkdtempSync("/tmp/arkv-ts-stale-");
    try {
      const path = join(dir, "stale.sock");
      // A process killed while listening leaves its socket file behind.
      const child = spawnSync(
        process.execPath,
        ["-e", "require('node:net').createServer().listen(process.argv.at(-1), () => process.kill(process.pid, 'SIGKILL'))", path],
        { timeout: 10_000 },
      );
      expect(child.signal).toBe("SIGKILL");
      expect(existsSync(path)).toBe(true);
      const error = await rejection(ArkVoiceClient.connect({ socketPath: path }));
      expect(error).toBeInstanceOf(NotRunningError);
      expect(((error as Error).cause as NodeJS.ErrnoException).code).toBe("ECONNREFUSED");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("handshake", () => {
  test("sends hello as request 1 and exposes the reply", async () => {
    const server = await serve(undefined, { helloReply: { sampleRate: 22050, version: 1, event: "hello-ok" } });
    const { client, connection } = await connect(server);
    expect(connection.received).toHaveLength(1);
    const hello = connection.received[0]!;
    expect(hello.requestId).toBe(1);
    expect(hello.payload).toEqual(hex(HELLO_FRAME).subarray(12));
    expect(client.serverVersion).toBe(1);
    expect(client.sampleRate).toBe(22050);
  });

  test("sampleRate defaults to 24000", async () => {
    const server = await serve(undefined, { helloReply: { event: "hello-ok", version: 1 } });
    const { client } = await connect(server);
    expect(client.sampleRate).toBe(24000);
  });

  test("a hello-ok with another version is UnsupportedVersionError", async () => {
    const server = await serve(undefined, { helloReply: { event: "hello-ok", version: 2, sampleRate: 24000 } });
    const error = await rejection(ArkVoiceClient.connect({ socketPath: server.path }));
    expect(error).toBeInstanceOf(UnsupportedVersionError);
    expect((error as UnsupportedVersionError).code).toBe("unsupported-version");
  });

  test("an unsupported-version error reply is UnsupportedVersionError", async () => {
    const server = await serve(
      (frame, connection) => {
        if (frame.message?.["op"] === "hello") {
          connection.sendJson(frame.requestId, {
            event: "error",
            code: "unsupported-version",
            message: "This server speaks protocol version 1.",
            version: 1,
          });
        }
      },
      { helloReply: false },
    );
    const error = await rejection(ArkVoiceClient.connect({ socketPath: server.path }));
    expect(error).toBeInstanceOf(UnsupportedVersionError);
    expect((error as ServerError).message).toBe("This server speaks protocol version 1.");
    expect((error as ServerError).requestId).toBe(1);
  });
});

describe("errors from the server", () => {
  const codes: Array<[string, Function]> = [
    ["bad-request", BadRequestError],
    ["unsupported-version", UnsupportedVersionError],
    ["models-missing", ModelsMissingError],
    ["unknown-request", UnknownRequestError],
    ["cancelled", RequestCancelledError],
    ["failed", ServerFailedError],
  ];

  test("each code maps to its class and the connection stays usable", async () => {
    let nextCode = "";
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] !== "status") return;
      if (nextCode) connection.sendJson(frame.requestId, { event: "error", code: nextCode, message: `boom ${nextCode}` });
      else housekeeping(frame, connection);
    });
    const { client } = await connect(server);
    for (const [code, ErrorClass] of [...codes, ["mystery-code", ServerError] as [string, Function]]) {
      nextCode = code;
      const error = await rejection(client.status());
      expect(error).toBeInstanceOf(ErrorClass);
      expect((error as ServerError).code).toBe(code);
      expect((error as ServerError).message).toBe(`boom ${code}`);
      expect((error as ServerError).requestId).toBeGreaterThan(1);
      if (ErrorClass === ServerError) expect((error as Error).constructor).toBe(ServerError);
    }
    nextCode = "";
    expect((await client.status()).requestsServed).toBe(1);
    expect(client.closed).toBe(false);
  });

  test("an error ends a stream by throwing", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] === "tts") {
        connection.sendJson(frame.requestId, { event: "error", code: "models-missing", message: "Run download." });
      }
    });
    const { client } = await connect(server);
    const error = await rejection(collect(client.synthesize("Hello")));
    expect(error).toBeInstanceOf(ModelsMissingError);
  });

  test("an error on id 0 fails every pending request and closes the connection", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] === "voices") {
        connection.sendJson(0, { event: "error", code: "bad-request", message: "Frame payload exceeds the limit." });
      }
    });
    const { client } = await connect(server);
    const status = rejection(client.status());
    const synthesis = rejection(collect(client.synthesize("Hello")));
    const voices = rejection(client.voices());
    for (const error of await Promise.all([status, synthesis, voices])) {
      expect(error).toBeInstanceOf(BadRequestError);
      expect((error as ServerError).requestId).toBe(0);
      expect((error as Error).message).toBe("Frame payload exceeds the limit.");
    }
    expect(client.closed).toBe(true);
    expect(await rejection(client.status())).toBeInstanceOf(ConnectionClosedError);
  });

  test("EOF fails pending requests and later calls with ConnectionClosedError", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] === "status") connection.end();
    });
    const { client } = await connect(server);
    const synthesis = client.synthesize("pending");
    expect(await rejection(client.status())).toBeInstanceOf(ConnectionClosedError);
    expect(await rejection(collect(synthesis))).toBeInstanceOf(ConnectionClosedError);
    expect(client.closed).toBe(true);
    expect(await rejection(client.voices())).toBeInstanceOf(ConnectionClosedError);
    expect(await rejection(collect(client.synthesize("later")))).toBeInstanceOf(ConnectionClosedError);
  });

  test("a malformed frame is a ProtocolError with its reason", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] === "status") connection.sendRaw(hex("420000000100000000000000"));
    });
    const { client } = await connect(server);
    const error = await rejection(client.status());
    expect(error).toBeInstanceOf(ProtocolError);
    expect((error as ProtocolError).reason).toBe("bad-magic");
    expect(await rejection(client.status())).toBeInstanceOf(ConnectionClosedError);
  });

  test("malformed JSON is a ProtocolError", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] === "status") {
        connection.sendRaw(
          new Uint8Array([0x41, 0, 0, 0, frame.requestId, 0, 0, 0, 3, 0, 0, 0, 0x7b, 0x7b, 0x7b]),
        );
      }
    });
    const { client } = await connect(server);
    expect(await rejection(client.status())).toBeInstanceOf(ProtocolError);
  });
});

describe("routing", () => {
  test("frames for unknown request ids are ignored", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] !== "status") return;
      connection.sendJson(999, { event: "status", requestsServed: 999 });
      connection.sendPcm(998, new Uint8Array([1, 2]));
      connection.sendJson(997, { event: "error", code: "failed", message: "not yours" });
      connection.sendJson(0, { event: "status" });
      housekeeping(frame, connection);
    });
    const { client } = await connect(server);
    expect((await client.status()).requestsServed).toBe(1);
    expect(client.closed).toBe(false);
  });

  test("pipelined requests are sent eagerly and interleaved responses reach the right caller", async () => {
    const server = await serve();
    const { client, connection } = await connect(server);

    const status = client.status();
    const synthesis = client.synthesize("Hello there", { voice: "narrator" });
    const voices = client.voices();
    const transcription = client.transcribe(PCMAudio.fromSamples([0.1, 0.2], 16000));

    // Everything is on the wire before anything is consumed.
    await connection.waitFor((frame) => frame.message?.["op"] === "end");
    const ops = connection.messages.map(({ requestId, message }) => [requestId, message["op"]]);
    expect(ops).toEqual([
      [1, "hello"],
      [2, "status"],
      [3, "tts"],
      [4, "voices"],
      [5, "stt"],
      [5, "end"],
    ]);
    expect(connection.messages[2]!.message).toEqual({ op: "tts", text: "Hello there", voice: "narrator", format: "s16le" });

    // Reply out of order, interleaving the streams.
    connection.sendJson(3, { event: "audio-format", sampleRate: 24000, format: "s16le" });
    connection.sendJson(5, { event: "partial", text: " hello" });
    connection.sendPcm(3, encodeSamples([0.5, -0.5], "s16le"));
    connection.sendJson(4, { event: "voices", names: ["a"] });
    connection.sendJson(5, { event: "final", text: "Hello." });
    connection.sendPcm(3, encodeSamples([0.25], "s16le"));
    connection.sendJson(2, { event: "status", version: 1, synthesisModelLoaded: true, transcriptionModelLoaded: false, requestsServed: 7, uptimeSeconds: 3 });
    connection.sendJson(5, { event: "done" });
    connection.sendJson(3, { event: "done", chunks: 2, samples: 3, seconds: 0.000125 });

    // Consume in yet another order.
    expect(await collect<TranscriptEvent>(transcription)).toEqual([
      { type: "partial", text: " hello" },
      { type: "final", text: "Hello." },
    ]);
    expect(await voices).toEqual(["a"]);
    const events = await collect<SynthesisEvent>(synthesis);
    expect(events.map((event) => event.type)).toEqual(["audio", "audio", "done"]);
    expect(events[2]).toEqual({ type: "done", chunks: 2, samples: 3, seconds: 0.000125, sampleRate: 24000 });
    expect(await status).toEqual({
      version: 1,
      synthesisModelLoaded: true,
      transcriptionModelLoaded: false,
      transcriptionModel: null,
      requestsServed: 7,
      uptimeSeconds: 3,
    });
  });
});

describe("synthesis", () => {
  test("streams chunks in the announced format, then the summary", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] !== "tts") return;
      connection.sendJson(frame.requestId, { event: "audio-format", sampleRate: 22050, format: "f32le" });
      connection.sendPcm(frame.requestId, encodeSamples([0.5, -0.5], "f32le"));
      connection.sendPcm(frame.requestId, encodeSamples([0.25], "f32le"));
      connection.sendJson(frame.requestId, { event: "done", chunks: 2, samples: 3, seconds: 3 / 22050 });
    });
    const { client, connection } = await connect(server);
    const events = await collect(client.synthesize("Hi", { format: "f32le" }));
    expect(connection.messages[1]!.message).toEqual({ op: "tts", text: "Hi", format: "f32le" });
    expect(events).toHaveLength(3);
    const [first, second, done] = events;
    if (first?.type !== "audio" || second?.type !== "audio" || done?.type !== "done") throw new Error("bad events");
    expect(first.index).toBe(0);
    expect(second.index).toBe(1);
    expect(first.audio.format).toBe("f32le");
    expect(first.audio.sampleRate).toBe(22050);
    expect(Array.from(first.audio.samples())).toEqual([0.5, -0.5]);
    expect(done).toEqual({ type: "done", chunks: 2, samples: 3, seconds: 3 / 22050, sampleRate: 22050 });
  });

  test("synthesizeAudio joins the chunks; synthesizeToWav writes them", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] !== "tts") return;
      connection.sendJson(frame.requestId, { event: "audio-format", sampleRate: 24000, format: "s16le" });
      connection.sendPcm(frame.requestId, encodeSamples([0.5], "s16le"));
      connection.sendPcm(frame.requestId, encodeSamples([-0.5, 0.25], "s16le"));
      connection.sendJson(frame.requestId, { event: "done", chunks: 2, samples: 3, seconds: 0.000125 });
    });
    const { client } = await connect(server);
    const { audio, summary } = await client.synthesizeAudio("Hi");
    expect(audio.sampleCount).toBe(summary.samples);
    expect(audio.data).toEqual(encodeSamples([0.5, -0.5, 0.25], "s16le"));

    const dir = mkdtempSync("/tmp/arkv-ts-wav-");
    try {
      const path = join(dir, "out.wav");
      const written = await client.synthesizeToWav("Hi", path);
      expect(written.samples).toBe(3);
      expect((await PCMAudio.readWav(path)).data).toEqual(audio.data);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("without audio-format, chunks use 24000 Hz and the requested format", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] !== "tts") return;
      connection.sendPcm(frame.requestId, encodeSamples([0.5], "f32le"));
      connection.sendJson(frame.requestId, { event: "done", chunks: 1, samples: 1, seconds: 1 / 24000 });
    });
    const { client } = await connect(server);
    const { audio } = await client.synthesizeAudio("Hi", { format: "f32le" });
    expect(audio.sampleRate).toBe(24000);
    expect(audio.format).toBe("f32le");
  });
});

describe("cancellation", () => {
  /** A synthesis that streams one chunk and then waits for cancel. */
  function cancellableSynthesis(terminal: "cancelled" | "done"): FrameHandler {
    return (frame, connection) => {
      const op = frame.message?.["op"];
      if (op === "tts") {
        connection.sendJson(frame.requestId, { event: "audio-format", sampleRate: 24000, format: "s16le" });
        connection.sendPcm(frame.requestId, encodeSamples([0.5, 0.5], "s16le"));
      } else if (op === "cancel") {
        // Frames still in flight when the cancel lands must be discarded.
        connection.sendPcm(frame.requestId, encodeSamples([0.1], "s16le"));
        connection.sendJson(frame.requestId, { event: "partial", text: "stray" });
        if (terminal === "cancelled") {
          connection.sendJson(frame.requestId, { event: "error", code: "cancelled", message: "Request was cancelled." });
        } else {
          connection.sendJson(frame.requestId, { event: "done", chunks: 2, samples: 3, seconds: 1 });
        }
        // A late frame after the terminal event is for an unknown id now.
        connection.sendPcm(frame.requestId, encodeSamples([0.2], "s16le"));
      } else {
        housekeeping(frame, connection);
      }
    };
  }

  for (const terminal of ["cancelled", "done"] as const) {
    test(`breaking out sends cancel and drains until ${terminal}`, async () => {
      const server = await serve(cancellableSynthesis(terminal));
      const { client, connection } = await connect(server);
      const stream = client.synthesize("A long text");
      let chunks = 0;
      for await (const event of stream) {
        if (event.type === "audio") chunks++;
        break;
      }
      expect(chunks).toBe(1);
      const cancel = await connection.waitFor((frame) => frame.message?.["op"] === "cancel");
      expect(cancel.requestId).toBe(stream.requestId);
      expect(cancel.message).toEqual({ op: "cancel" });

      // The connection is still usable and nothing from the cancelled request leaks.
      expect((await client.status()).requestsServed).toBe(1);
      expect(await client.voices()).toEqual(["narrator", "robot"]);
      expect(await stream.next()).toEqual({ done: true, value: undefined });
      expect(connection.messages.filter(({ message }) => message["op"] === "cancel")).toHaveLength(1);
    });
  }

  test("no cancel is sent once the terminal event has arrived", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] === "tts") {
        // All of it in one write: the terminal event is buffered before the first chunk is read.
        const id = frame.requestId;
        connection.sendJson(id, { event: "audio-format", sampleRate: 24000, format: "s16le" });
        connection.sendPcm(id, encodeSamples([0.5], "s16le"));
        connection.sendPcm(id, encodeSamples([0.5], "s16le"));
        connection.sendJson(id, { event: "done", chunks: 2, samples: 2, seconds: 1 });
      } else {
        housekeeping(frame, connection);
      }
    });
    const { client, connection } = await connect(server);
    const stream = client.synthesize("Short");
    await connection.waitFor((frame) => frame.message?.["op"] === "tts");
    // Let every response frame arrive before reading.
    await client.status();
    for await (const _event of stream) break;
    await client.status();
    expect(connection.messages.some(({ message }) => message["op"] === "cancel")).toBe(false);

    // And a fully consumed stream never cancels either.
    await collect(client.synthesize("Short"));
    await client.status();
    expect(connection.messages.some(({ message }) => message["op"] === "cancel")).toBe(false);
  });

  test("cancel() on a transcription that is still running", async () => {
    const server = await serve((frame, connection) => {
      const op = frame.message?.["op"];
      if (op === "end") connection.sendJson(frame.requestId, { event: "partial", text: " the" });
      else if (op === "cancel") connection.sendJson(frame.requestId, { event: "error", code: "cancelled", message: "x" });
      else housekeeping(frame, connection);
    });
    const { client, connection } = await connect(server);
    const stream = client.transcribe(PCMAudio.fromSamples([0], 16000));
    expect(await stream.next()).toEqual({ done: false, value: { type: "partial", text: " the" } });
    await stream.cancel();
    await connection.waitFor((frame) => frame.message?.["op"] === "cancel");
    expect(await stream.next()).toEqual({ done: true, value: undefined });
    expect((await client.status()).version).toBe(1);
  });

  test("return() while a next() is pending ends that next() and cancels", async () => {
    const server = await serve(cancellableSynthesis("cancelled"));
    const { client, connection } = await connect(server);
    const stream = client.synthesize("A long text");
    expect((await stream.next()).value?.type).toBe("audio");
    const pending = stream.next();
    await stream.return();
    expect(await pending).toEqual({ done: true, value: undefined });
    await connection.waitFor((frame) => frame.message?.["op"] === "cancel");
    expect((await client.status()).version).toBe(1);
  });

  test("aborting a stream sends cancel and rejects with the signal's reason", async () => {
    const server = await serve(cancellableSynthesis("cancelled"));
    const { client, connection } = await connect(server);
    const controller = new AbortController();
    const stream = client.synthesize("A long text", { signal: controller.signal });
    const first = await stream.next();
    expect(first.value?.type).toBe("audio");
    const pending = stream.next();
    const reason = new Error("user stopped");
    controller.abort(reason);
    expect(await rejection(pending)).toBe(reason);
    const cancel = await connection.waitFor((frame) => frame.message?.["op"] === "cancel");
    expect(cancel.requestId).toBe(stream.requestId);
    expect(await stream.next()).toEqual({ done: true, value: undefined });
    expect((await client.status()).version).toBe(1);
  });

  test("aborting a pending request without a reason rejects with an AbortError", async () => {
    const server = await serve((frame, connection) => {
      const op = frame.message?.["op"];
      if (op === "cancel") connection.sendJson(frame.requestId, { event: "error", code: "cancelled", message: "x" });
      else if (op === "voices") housekeeping(frame, connection);
      // status is never answered until cancelled
    });
    const { client, connection } = await connect(server);
    const controller = new AbortController();
    const status = client.status({ signal: controller.signal });
    await connection.waitFor((frame) => frame.message?.["op"] === "status");
    controller.abort();
    const error = await rejection(status);
    expect((error as Error).name).toBe("AbortError");
    await connection.waitFor((frame) => frame.message?.["op"] === "cancel");
    expect(await client.voices()).toEqual(["narrator", "robot"]);
  });

  test("an already-aborted signal sends nothing", async () => {
    const server = await serve(housekeeping);
    const { client, connection } = await connect(server);
    const reason = new Error("already");
    const signal = AbortSignal.abort(reason);
    expect(await rejection(client.status({ signal }))).toBe(reason);
    expect(await rejection(collect(client.synthesize("x", { signal })))).toBe(reason);
    expect(await client.voices()).toEqual(["narrator", "robot"]);
    expect(connection.messages.map(({ message }) => message["op"])).toEqual(["hello", "voices"]);
    // Request ids are not consumed by requests that were never sent.
    expect(connection.messages[1]!.requestId).toBe(2);
  });
});

describe("uploads", () => {
  test("transcription sends the start message, 256 KiB PCM frames, then end", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] !== "end") return;
      connection.sendJson(frame.requestId, { event: "partial", text: " the quick" });
      connection.sendJson(frame.requestId, { event: "partial", text: " brown fox" });
      connection.sendJson(frame.requestId, { event: "final", text: "The quick brown fox." });
      connection.sendJson(frame.requestId, { event: "done" });
    });
    const { client, connection } = await connect(server);
    const samples = new Float32Array(300_000).map((_, i) => Math.sin(i / 10) * 0.5);
    const audio = PCMAudio.fromSamples(samples, 44100, "s16le");
    expect(audio.data.byteLength).toBe(600_000);

    const events = await collect(client.transcribe(audio, { model: "parakeet" }));
    expect(events).toEqual([
      { type: "partial", text: " the quick" },
      { type: "partial", text: " brown fox" },
      { type: "final", text: "The quick brown fox." },
    ]);

    const frames = connection.received.filter((frame) => frame.requestId === 2);
    expect(frames[0]!.message).toEqual({ op: "stt", format: "s16le", sampleRate: 44100, model: "parakeet" });
    expect(frames.slice(1, -1).map((frame) => [frame.kind, frame.payload.byteLength])).toEqual([
      [1, 262_144],
      [1, 262_144],
      [1, 600_000 - 2 * 262_144],
    ]);
    expect(frames.at(-1)!.message).toEqual({ op: "end" });
    const uploaded = new Uint8Array(600_000);
    let offset = 0;
    for (const frame of frames.slice(1, -1)) {
      uploaded.set(frame.payload, offset);
      offset += frame.payload.byteLength;
    }
    expect<Uint8Array>(uploaded).toEqual(audio.data);
  });

  test("transcribeText returns the final text, or empty without one", async () => {
    let withFinal = true;
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] !== "end") return;
      connection.sendJson(frame.requestId, { event: "partial", text: "hi" });
      if (withFinal) connection.sendJson(frame.requestId, { event: "final", text: "Hi." });
      connection.sendJson(frame.requestId, { event: "done" });
    });
    const { client, connection } = await connect(server);
    const audio = PCMAudio.fromSamples([0.1, 0.2], 24000, "f32le");
    expect(await client.transcribeText(audio)).toBe("Hi.");
    expect(connection.messages[1]!.message).toEqual({ op: "stt", format: "f32le", sampleRate: 24000 });
    withFinal = false;
    expect(await client.transcribeText(audio)).toBe("");
  });

  test("transcribeFile reads a WAV; a bad file fails on iteration", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] !== "end") return;
      connection.sendJson(frame.requestId, { event: "final", text: "From file." });
      connection.sendJson(frame.requestId, { event: "done" });
    });
    const { client, connection } = await connect(server);
    const dir = mkdtempSync("/tmp/arkv-ts-file-");
    try {
      const path = join(dir, "in.wav");
      await PCMAudio.fromSamples([0.1, -0.1, 0.2], 16000).writeWav(path);
      expect(await collect(client.transcribeFile(path))).toEqual([{ type: "final", text: "From file." }]);
      expect(connection.messages[1]!.message).toEqual({ op: "stt", format: "s16le", sampleRate: 16000 });

      const missing = client.transcribeFile(join(dir, "missing.wav"));
      expect(missing.requestId).toBe(0);
      expect(((await rejection(collect(missing))) as NodeJS.ErrnoException).code).toBe("ENOENT");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("createVoice uploads the reference and returns the saved path", async () => {
    const server = await serve((frame, connection) => {
      if (frame.message?.["op"] !== "end") return;
      connection.sendJson(frame.requestId, { event: "voice-created", path: "/tmp/voices/narrator.safetensors" });
      connection.sendJson(frame.requestId, { event: "done" });
    });
    const { client, connection } = await connect(server);
    const audio = PCMAudio.fromSamples(new Float32Array(70_000), 24000, "f32le");
    expect(await client.createVoice("narrator", audio)).toBe("/tmp/voices/narrator.safetensors");
    const frames = connection.received.filter((frame) => frame.requestId === 2);
    expect(frames[0]!.message).toEqual({ op: "create-voice", name: "narrator", format: "f32le", sampleRate: 24000 });
    expect(frames.slice(1, -1).map((frame) => frame.payload.byteLength)).toEqual([262_144, 280_000 - 262_144]);
    expect(frames.at(-1)!.message).toEqual({ op: "end" });
  });
});

describe("housekeeping and lifecycle", () => {
  test("voices, status and unload", async () => {
    const server = await serve(housekeeping);
    const { client, connection } = await connect(server);
    expect(await client.voices()).toEqual(["narrator", "robot"]);
    expect(await client.status()).toEqual({
      version: 1,
      synthesisModelLoaded: false,
      transcriptionModelLoaded: false,
      transcriptionModel: null,
      requestsServed: 1,
      uptimeSeconds: 0.5,
    });
    expect(await client.unload()).toBeUndefined();
    expect(connection.messages.map(({ requestId, message }) => [requestId, message["op"]])).toEqual([
      [1, "hello"],
      [2, "voices"],
      [3, "status"],
      [4, "unload"],
    ]);
  });

  test("close fails pending requests; later calls fail with ConnectionClosedError", async () => {
    const server = await serve();
    const { client } = await connect(server);
    const pending = rejection(client.status());
    await client.close();
    expect(await pending).toBeInstanceOf(ConnectionClosedError);
    expect(client.closed).toBe(true);
    expect(await rejection(client.voices())).toBeInstanceOf(ConnectionClosedError);
    await client.close();
  });

  test("await using closes the client", async () => {
    const server = await serve(housekeeping);
    let escaped: ArkVoiceClient | undefined;
    {
      await using client = await ArkVoiceClient.connect({ socketPath: server.path });
      escaped = client;
      expect((await client.status()).version).toBe(1);
    }
    expect(escaped.closed).toBe(true);
  });
});
