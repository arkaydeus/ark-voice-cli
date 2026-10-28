# ArkVoiceClient (Swift)

An async/await client for `ark-voice serve`. It speaks the protocol in
[`PROTOCOL.md`](../../PROTOCOL.md) over the server's Unix socket and depends on
nothing but Foundation, so an app can talk to the daemon without linking MLX,
FluidAudio or a gigabyte of weights.

The source lives in [`Sources/ArkVoiceClient`](../../Sources/ArkVoiceClient); it
is a library product of the root package. To run speech in your own process
instead, link `ArkVoiceKit` (see the top-level README).

The client needs a running server:

```sh
ark-voice serve            # listens on ~/.ark-voice-cli/ark-voice.sock
```

## Install

```swift
.package(path: "../ark-voice-cli"),
...
.product(name: "ArkVoiceClient", package: "ark-voice-cli"),
```

The `ArkVoiceClient` target has no dependencies, so building it compiles only
its own sources.

## Connect

```swift
import ArkVoiceClient

let voice = try await ArkVoiceConnection.connect()   // or connect(socketPath: "/tmp/av.sock")
print(voice.serverVersion, voice.sampleRate)
defer { voice.close() }
```

The socket path is the argument if given, else `$ARK_VOICE_SOCKET`, else
`~/.ark-voice-cli/ark-voice.sock`. `connect` performs the `hello` handshake
and throws `ArkVoiceClientError.notRunning` if nothing is listening, or
`.unsupportedVersion` if the server speaks another protocol version.

## Synthesize

`synthesize` returns an `AsyncThrowingStream`. Audio arrives while the rest of
the text is still being generated; a `.done` summary comes last.

```swift
for try await event in voice.synthesize("Hello there.", voice: "narrator") {
  switch event {
  case .audio(let chunk, let index):
    player.enqueue(chunk.samples)        // [Float] at chunk.sampleRate (24 kHz)
  case .done(let summary):
    print("\(summary.chunks) chunks, \(summary.seconds) s")
  }
}

let result = try await voice.synthesizeAudio("Hello there.")   // every chunk joined
try await voice.synthesize("Hello there.", toWAV: URL(fileURLWithPath: "hello.wav"))
```

`format: .f32le` asks for 32-bit float samples instead of 16-bit integers.

## Audio: `PCMAudio`

Mono PCM as it travels on the wire: `data`, `sampleRate`, `format`, plus
`sampleCount`, `duration` and `samples` (floats).

```swift
let recorded = PCMAudio(samples: floats, sampleRate: 48_000)   // encoded as s16le
let file = try PCMAudio(contentsOfWAV: url)    // 16-bit PCM or 32-bit float; channels are averaged
try file.writeWAV(to: copy)
```

## Transcribe

Audio at any sample rate is accepted; the server resamples to 16 kHz.

```swift
for try await event in voice.transcribe(recorded) {
  switch event {
  case .partial(let text): print(text, terminator: "")   // concatenating partials gives the transcript
  case .final(let text): print("\n" + text)
  }
}

let text = try await voice.transcribeText(recorded, model: .parakeetUltra)
for try await event in try voice.transcribe(fileAt: url) { ... }
```

`model` is optional (`.parakeet`, `.parakeetUltra`, `.qwen`); `nil` uses the
server's default. `STTModel` is a string wrapper, so a newer server's
recognizer can be named with a literal.

## Voices and housekeeping

```swift
let path = try await voice.createVoice(named: "narrator", from: reference)
let names = try await voice.voices()
let status = try await voice.status()      // models loaded, requests served, uptime
try await voice.unload()                   // release the server's models now
```

## Errors

- `ServerError`: the server refused or abandoned a request. `code` is a
  `ServerErrorCode` (`.badRequest`, `.unsupportedVersion`, `.modelsMissing`,
  `.unknownRequest`, `.cancelled`, `.failed`); `rawCode` keeps the string the
  server sent. An error ends only that request, except one on request id 0
  (`isConnectionLevel`), which fails every request and closes the connection.
- `ArkVoiceClientError`: `.notRunning`, `.connectionClosed`,
  `.unsupportedVersion`, `.protocolViolation`, and socket failures.
- `WAVError`: a WAV file this client cannot read.

## Pipelining and cancellation

Every method can be called concurrently on one connection. A stream sends its
request when it is created, not when iteration starts, and each response is
routed to the call that asked for it:

```swift
async let status = voice.status()
async let speech = voice.synthesizeAudio("Both at once.")
print(try await status.requestsServed, try await speech.audio.duration)
```

Breaking out of a `for try await` loop, or cancelling the task that iterates,
sends `cancel` for that request and discards the rest of its frames. The
connection stays usable. The server still runs model work one request at a
time.

## Relation to `VoiceClient`

`ArkVoiceServer` also has `VoiceClient`, a blocking client that takes
`ArkVoiceKit` types. It remains for hosts that already link the kit and for the
server's own tests. New code should use `ArkVoiceConnection`. The CLI's
`ark-voice client` subcommand runs on it.

## Tests

```sh
swift test --filter ArkVoiceClientTests
```

The suite checks the client against the shared byte vectors in
[`bindings/test-vectors/protocol.json`](../test-vectors/protocol.json) and a
scripted fake server. It also includes integration tests against a real
`ark-voice serve`. Those use `$ARK_VOICE_BINARY`, or else
`.build/release/ark-voice` from `./Scripts/build-release.sh`. They are skipped
when neither exists. The model-backed test is also skipped unless Parakeet v2
and Chatterbox are in `~/.ark-voice-cli`. It creates a voice profile named
`bindings-test-swift-…` in `~/.ark-voice-cli/voices` and deletes it afterwards.
