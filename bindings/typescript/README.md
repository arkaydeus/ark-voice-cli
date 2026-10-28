# ark-voice-client (TypeScript)

A TypeScript client for `ark-voice serve`, the ark-voice socket server. It
speaks the protocol in [`PROTOCOL.md`](../../PROTOCOL.md) over the server's
Unix socket. It has no runtime dependencies and runs on Node 18 or later and
on Bun.

The client needs a running server:

```sh
ark-voice serve            # listens on ~/.ark-voice-cli/ark-voice.sock
```

## Install

The package is not published. Build it and install it from this directory:

```sh
cd bindings/typescript
bun install            # or: npm install
bun run build          # or: npm run build  (writes dist/ with .d.ts files)

# in your project
npm install /path/to/ark-voice-cli/bindings/typescript
# or: bun add /path/to/ark-voice-cli/bindings/typescript
```

The package is ESM only (`"type": "module"`).

## Connect

```ts
import { ArkVoiceClient } from "ark-voice-client";

const client = await ArkVoiceClient.connect(); // or { socketPath: "/tmp/voice.sock" }
console.log(client.serverVersion, client.sampleRate, client.socketPath);
// ...
await client.close();

// Or let the scope close it:
await using voice = await ArkVoiceClient.connect();
```

The socket path is the `socketPath` option if you pass one, else
`$ARK_VOICE_SOCKET`, else `~/.ark-voice-cli/ark-voice.sock`. If nothing is
listening there, `connect` throws `NotRunningError`.

## Synthesize

`synthesize` returns an async iterator of events. Audio chunks arrive while
the rest of the sentence is still being generated; a `done` summary comes
last.

```ts
for await (const event of client.synthesize("Hello there.", { voice: "narrator", format: "s16le" })) {
  if (event.type === "audio") {
    play(event.audio.data, event.audio.sampleRate); // PCMAudio: raw little-endian samples
  } else {
    console.log(`${event.chunks} chunks, ${event.samples} samples, ${event.seconds}s at ${event.sampleRate} Hz`);
  }
}
```

To get the whole utterance, or write it to a file:

```ts
const { audio, summary } = await client.synthesizeAudio("Hello there.");
await audio.writeWav("hello.wav");

await client.synthesizeToWav("Hello there.", "hello.wav");
```

Synthesis is 24 kHz mono. `format` is `"s16le"` (the default) or `"f32le"`.

## Transcribe

```ts
import { PCMAudio } from "ark-voice-client";

// From a WAV file (16-bit or float, any channel count, any sample rate):
for await (const event of client.transcribeFile("speech.wav")) {
  console.log(event.type, event.text); // "partial" pieces, then "final"
}

// From samples you already have:
const audio = PCMAudio.fromSamples(float32Samples, 48_000); // the server resamples
const text = await client.transcribeText(audio, { model: "parakeet" });
```

`model` is optional: `"parakeet"`, `"parakeet-ultra"` or `"qwen"`; without it
the server uses its default. Concatenating the `partial` texts reproduces the
transcript.

`PCMAudio` holds `data` (a `Uint8Array`), `sampleRate` and `format`, with
`sampleCount`, `duration`, `samples()`, `PCMAudio.fromSamples()`,
`PCMAudio.concat()`, `toWav()`, `writeWav()`, `PCMAudio.fromWav()` and
`PCMAudio.readWav()`.

## Voices, status, unload

```ts
const path = await client.createVoice("narrator", await PCMAudio.readWav("reference.wav"));
const names = await client.voices();            // ["narrator", ...]
const status = await client.status();
// { version, synthesisModelLoaded, transcriptionModelLoaded, transcriptionModel, requestsServed, uptimeSeconds }
await client.unload();                           // release resident models now
```

## Errors

All errors extend `ArkVoiceError`.

| Error | When |
| --- | --- |
| `ServerError` | The server sent an `error` event; carries `code`, `message` and `requestId`. Subclasses by code: `BadRequestError`, `UnsupportedVersionError`, `ModelsMissingError`, `UnknownRequestError`, `RequestCancelledError`, `ServerFailedError`. An unrecognised code gives a plain `ServerError`. |
| `NotRunningError` | Nothing listens on the socket path. Start `ark-voice serve`. |
| `ConnectionClosedError` | The connection closed, or was already closed, while a request needed it. |
| `ProtocolError` | The server sent a malformed frame (`reason` says which check failed) or control message. |

```ts
try {
  await client.synthesizeAudio("Hello");
} catch (error) {
  if (error instanceof ModelsMissingError) console.error("Run `ark-voice download` on the server.");
  else throw error;
}
```

An error ends only its own request; the connection stays usable. An `error`
on request id 0 is connection-level: it fails every pending request and
closes the connection.

## Cancellation

Leaving a `for await` loop early (`break`, `return`, or a thrown exception)
sends `cancel` for that request. The client then discards the request's
remaining frames until its terminal event, so the connection is ready for the
next request. `stream.cancel()` does the same without a loop.

Every request method also accepts an `AbortSignal`:

```ts
const controller = new AbortController();
setTimeout(() => controller.abort(), 2000);
const { audio } = await client.synthesizeAudio(longText, { signal: controller.signal });
// rejects with the signal's reason (an AbortError by default) and cancels the request
```

## Pipelining

Requests are written to the socket as soon as the method is called, so
several can be in flight on one connection. Replies are routed by request id
and buffered until you read them:

```ts
const synthesis = client.synthesizeAudio("One");
const [status, voices, { audio }] = await Promise.all([client.status(), client.voices(), synthesis]);
```

The server still runs model work one request at a time.

## Low-level pieces

Also exported: `PROTOCOL_VERSION`, `defaultSocketPath()`, `resolveSocketPath()`,
`encodeFrame()`, `parseHeader()`, `FrameDecoder` (accepts bytes split at any
point), `encodeMessage()` / `encodeMessageFrame()` (compact, sorted keys),
`decodeMessage()`, `encodeSamples()` / `decodeSamples()`, `encodeWav()` /
`decodeWav()`, and `serverErrorFor()`.

## Tests

```sh
bun install
bun run typecheck                 # tsc --noEmit over src and test
bun run build                     # tsc to dist/
bun run test                      # bun test: vectors, WAV, fake-server behaviour, integration
bun run test:node                 # builds, then a node:test smoke test of dist/ on Node
```

The unit tests check every byte vector in
[`bindings/test-vectors/protocol.json`](../test-vectors/protocol.json). The
behaviour tests run a scripted fake server on a temporary socket.

The integration tests start a real `ark-voice serve` on a temporary socket.
They use `$ARK_VOICE_BINARY`, else `<repo>/.build/release/ark-voice` (with
`mlx.metallib` beside it), and skip if neither exists. Tests that need models
are skipped if the server reports `models-missing`. The first model-backed
request loads about a gigabyte of weights, so the suite takes tens of seconds.

```sh
ARK_VOICE_BINARY=/path/to/ark-voice bun test test/integration.test.ts
```

The voice-profile test creates `bindings-test-ts-<random>` in
`~/.ark-voice-cli/voices` and deletes it afterwards.
