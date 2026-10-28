# ark-voice socket protocol

`ark-voice serve` listens on a Unix domain socket and answers synthesis and
transcription requests with models already in memory. This document is the
whole contract; `Scripts/client.py` is a working implementation of it in about
150 lines of standard-library Python.

The protocol exists so that a caller can avoid the cost that dominates
process-per-call use: loading roughly a gigabyte of weights for every request.

## Connecting

Default path: `~/.ark-voice-cli/ark-voice.sock`, mode `0600`. Override with
`ark-voice serve --socket <path>`.

The socket carries speech and voice-profile data, so it stays owned by the user
who started the server. Anything that can open the socket can synthesize speech
in any saved voice.

## Framing

Every message is a 12-byte header followed by its payload:

| Offset | Size | Field      | Notes                                    |
| ------ | ---- | ---------- | ---------------------------------------- |
| 0      | 1    | magic      | always `0x41` (`'A'`)                    |
| 1      | 1    | kind       | `0` = JSON control, `1` = PCM audio      |
| 2      | 2    | flags      | reserved, must be zero                   |
| 4      | 4    | request id | little-endian `uint32`                   |
| 8      | 4    | length     | little-endian `uint32` payload byte count |

Payloads are capped at 64 MiB; a larger declared length is a protocol error, so
a corrupt header cannot make the server allocate without bound.

Control messages are JSON because they should be readable in a packet dump.
Audio is raw little-endian PCM in `pcm` frames and is **never** base64-encoded
inside JSON: speech runs 96 KB per second as float samples, and base64 would add
a third again in bytes plus a parse pass per chunk.

Both directions tag every frame with a request id. Several requests may be in
flight on one connection and their responses may interleave, though the server
runs model work one request at a time.

Request id `0` is reserved for connection-level protocol errors. Clients must
surface an `error` event on id `0` even while waiting for another request id.
The server closes the connection after sending one, so it ends every request
still in flight.

## Sample formats

`f32le` is 32-bit float, the model's native form. `s16le` is 16-bit signed
integer: half the bytes for the same audible result, and the default for both
directions. Synthesis produces 24 kHz mono; transcription expects 16 kHz mono
and resamples anything else the client declares.

## Conversation

A client sends `hello` first. Every other operation is refused until it does,
which is what makes the version field meaningful.

```json
→ {"op": "hello", "version": 1}
← {"event": "hello-ok", "version": 1, "sampleRate": 24000}
```

### Synthesis

```json
→ {"op": "tts", "text": "Hello", "voice": "narrator", "format": "s16le"}
← {"event": "audio-format", "sampleRate": 24000, "format": "s16le"}
← <pcm frame>                       one per synthesized chunk
← <pcm frame>
← {"event": "done", "chunks": 2, "samples": 48000, "seconds": 2.0}
```

`voice` names a profile saved with `create-voice` or `ark-voice voice create`.
Omit it for the built-in voice. Audio starts arriving as soon as the first chunk
of text is generated, so playback need not wait for the whole utterance.

### Transcription

```json
→ {"op": "stt", "format": "s16le", "sampleRate": 16000, "model": "parakeet-ultra"}
→ <pcm frame>                       as many as needed
→ {"op": "end"}
← {"event": "partial", "text": " the quick"}
← {"event": "final", "text": "The quick brown fox."}
← {"event": "done"}
```

`model` is optional: `parakeet`, `parakeet-ultra`, or `qwen`. Without it the
server uses its default, Parakeet v2 unless `ark-voice serve --stt-model` says
otherwise. An unknown name is refused with `bad-request` straight away; a known
one that is not downloaded ends in `models-missing` once the audio is in. The
server keeps one recognizer resident and swaps it when a request asks for
another.

`partial` carries the text recognized since the previous event, with its own
spacing, so concatenating the partials reproduces the transcript. Parakeet
Ultra produces its text only once the whole input is done, so it sends one
`partial` holding all of it. A connection
may have at most eight open audio streams. Across all connections, their
combined buffered audio is capped at about thirty minutes. The same limit also
applies to any one request.

The server accepts raw PCM only. A client holding a container file decodes it
first, or uses `ark-voice stt <file>` for a one-shot transcription.

### Voice profiles

```json
→ {"op": "create-voice", "name": "narrator", "format": "s16le", "sampleRate": 24000}
→ <pcm frame>                       reference recording
→ {"op": "end"}
← {"event": "voice-created", "path": "/Users/you/.ark-voice-cli/voices/narrator.safetensors"}
← {"event": "done"}
```

### Housekeeping

| Request                | Response                                                            |
| ---------------------- | ------------------------------------------------------------------- |
| `{"op": "voices"}`     | `{"event": "voices", "names": [...]}`                               |
| `{"op": "status"}`     | `{"event": "status", "version": 1, "synthesisModelLoaded": true, "transcriptionModelLoaded": true, "transcriptionModel": "qwen", "requestsServed": 4, "uptimeSeconds": 12.5}` |
| `{"op": "unload"}`     | `{"event": "done"}` — releases resident models                      |
| `{"op": "cancel"}`     | the addressed request ends with `{"event": "error", "code": "cancelled"}` |

`cancel` is addressed by the request id in its frame header, not by a field.

A cancel can cross the request's own reply. A request that finishes before the
server reads the cancel ends normally, with `done`. The cancel then has nothing
to stop and is answered with `unknown-request` on that id, after the reply.
`hello`, `voices` and `status` are answered at once, so cancelling them always
does this. A client that cancels should treat the request's normal final event,
or any `error`, as its end, and should ignore frames for ids that have already
ended.

## Errors

```json
← {"event": "error", "code": "models-missing", "message": "Required model data is missing..."}
```

| Code                  | Meaning                                                  |
| --------------------- | -------------------------------------------------------- |
| `bad-request`         | Malformed frame, missing field, or no handshake yet      |
| `unsupported-version` | The server speaks a different protocol version           |
| `models-missing`      | Run `ark-voice download` on the server's machine         |
| `unknown-request`     | Audio or `end` for a request that is not open            |
| `cancelled`           | The request was cancelled                                |
| `failed`              | Anything else; `message` carries the detail              |

An error ends that request. The connection stays usable for the next one.

## A frame, byte by byte

`{"op":"hello","version":1}` as request 1:

```text
41 00 00 00  01 00 00 00  1a 00 00 00  7b 22 6f 70 ...
^magic       ^request 1   ^26 bytes    ^{"op ...
   ^kind 0 (JSON)
      ^flags
```

## Lifecycle

`--idle-unload <seconds>` (default 300) releases the models after a quiet
period; the next request reloads them. `--idle-exit <seconds>` (default off)
stops the server entirely. `SIGINT` and `SIGTERM` shut down cleanly and remove
the socket file. A socket file left behind by a killed server is replaced
automatically; a live one is never stolen.
