// Node compatibility smoke test: imports the BUILT package (dist/) and talks to
// a fake server over a Unix socket using only node: modules.
// Run with `npm run test:node` (builds first) or `node --test test-node/`.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { after, before, test } from "node:test";

import {
  ArkVoiceClient,
  FrameDecoder,
  FrameKind,
  ModelsMissingError,
  PCMAudio,
  ServerError,
  encodeFrame,
  encodeSamples,
} from "ark-voice-client";

const encoder = new TextEncoder();
const dir = mkdtempSync("/tmp/arkv-ts-node-");
const socketPath = join(dir, "fake.sock");
const received = [];
let server;

function sendJson(socket, id, message) {
  socket.write(encodeFrame(FrameKind.JSON, id, encoder.encode(JSON.stringify(message))));
}

before(async () => {
  server = createServer((socket) => {
    const decoder = new FrameDecoder();
    socket.on("data", (chunk) => {
      for (const frame of decoder.push(chunk)) {
        if (frame.kind !== FrameKind.JSON) continue;
        const message = JSON.parse(new TextDecoder().decode(frame.payload));
        received.push({ id: frame.requestId, message });
        const id = frame.requestId;
        switch (message.op) {
          case "hello":
            sendJson(socket, id, { event: "hello-ok", version: 1, sampleRate: 24000 });
            break;
          case "tts":
            if (message.text === "fail") {
              sendJson(socket, id, { event: "error", code: "models-missing", message: "Run ark-voice download." });
              break;
            }
            sendJson(socket, id, { event: "audio-format", sampleRate: 24000, format: "s16le" });
            socket.write(encodeFrame(FrameKind.PCM, id, encodeSamples([0.5, -0.5], "s16le")));
            socket.write(encodeFrame(FrameKind.PCM, id, encodeSamples([0.25], "s16le")));
            sendJson(socket, id, { event: "done", chunks: 2, samples: 3, seconds: 0.000125 });
            break;
          case "status":
            sendJson(socket, id, {
              event: "status",
              version: 1,
              synthesisModelLoaded: true,
              transcriptionModelLoaded: false,
              requestsServed: 3,
              uptimeSeconds: 1.5,
            });
            break;
        }
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  rmSync(dir, { recursive: true, force: true });
});

test("connect, stream a synthesis, status, and an error on Node", async () => {
  const client = await ArkVoiceClient.connect({ socketPath });
  try {
    assert.equal(client.serverVersion, 1);
    assert.equal(client.sampleRate, 24000);
    assert.deepEqual(received[0], { id: 1, message: { op: "hello", version: 1 } });

    const events = [];
    for await (const event of client.synthesize("Hello from Node")) events.push(event);
    assert.deepEqual(
      events.map((event) => event.type),
      ["audio", "audio", "done"],
    );
    assert.ok(events[0].audio instanceof PCMAudio);
    assert.ok(!Buffer.isBuffer(events[0].audio.data), "public audio data is a plain Uint8Array");
    assert.equal(PCMAudio.concat([events[0].audio, events[1].audio]).sampleCount, events[2].samples);
    assert.deepEqual(events[2], { type: "done", chunks: 2, samples: 3, seconds: 0.000125, sampleRate: 24000 });

    const status = await client.status();
    assert.equal(status.synthesisModelLoaded, true);
    assert.equal(status.transcriptionModel, null);
    assert.equal(status.requestsServed, 3);

    await assert.rejects(
      async () => {
        for await (const _ of client.synthesize("fail"));
      },
      (error) =>
        error instanceof ModelsMissingError &&
        error instanceof ServerError &&
        error.name === "ModelsMissingError" &&
        error.code === "models-missing",
    );

    // The connection is still usable after an error.
    assert.equal((await client.status()).version, 1);
  } finally {
    await client.close();
  }
  assert.equal(client.closed, true);
});
