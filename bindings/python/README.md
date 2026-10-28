# ark-voice-client (Python)

A Python client for the `ark-voice serve` Unix-socket protocol
([PROTOCOL.md](../../PROTOCOL.md)). It uses only the standard library and
needs Python 3.10 or later. It has no FFI: you need a running
`ark-voice serve` to talk to.

```sh
ark-voice serve &        # keeps the models resident; socket at ~/.ark-voice-cli/ark-voice.sock
```

## Install

Nothing is published. Install from the repository path:

```sh
pip install ./bindings/python            # or: uv pip install -e ./bindings/python
```

The distribution is `ark-voice-client` and the import package is `ark_voice`.

## Connect

```python
from ark_voice import Client

with Client() as client:                # or Client.connect("/path/to/ark-voice.sock")
    print(client.server_version, client.sample_rate, client.socket_path)
```

The socket path is the argument if given, else `$ARK_VOICE_SOCKET`, else
`~/.ark-voice-cli/ark-voice.sock`. If nothing is listening there you get
`NotRunningError`, which suggests `ark-voice serve`.

## Synthesize

`synthesize` sends the request at once and returns a stream. It yields
`AudioChunk(audio, index)` items as the server produces them, then one
`SynthesisDone(chunks, samples, seconds, sample_rate)`.

```python
from ark_voice import AudioChunk, SynthesisDone

for event in client.synthesize("Hello there.", voice=None, format="s16le"):
    if isinstance(event, AudioChunk):
        play(event.audio.data)                  # raw 24 kHz mono PCM
    else:
        print(f"{event.seconds:.2f}s in {event.chunks} chunks")

result = client.synthesize_audio("Hello there.")   # every chunk joined
result.audio.write_wav("hello.wav")
summary = client.synthesize_to_wav("Hello there.", "hello.wav")
```

`format="f32le"` asks for 32-bit float samples instead of 16-bit integers.

## Audio: `PCMAudio`

An immutable value: `data` (bytes), `sample_rate`, `format` (`"s16le"` or
`"f32le"`), with `sample_count`, `duration`, `samples()` (floats),
`PCMAudio.from_samples(floats, rate, format)`, `PCMAudio.concat(chunks)`,
`to_wav()`, `write_wav(path)`, `PCMAudio.from_wav(bytes)` and
`PCMAudio.read_wav(path)`.

The WAV reader accepts 16-bit PCM and 32-bit float (plain or
`WAVE_FORMAT_EXTENSIBLE`), any channel count (averaged to mono) and streamed
files whose data size is `0xFFFFFFFF`, such as `ark-voice tts -o -` writes.

## Transcribe

```python
from ark_voice import PCMAudio, TranscriptFinal, TranscriptPartial

for event in client.transcribe_file("recording.wav"):
    if isinstance(event, TranscriptPartial):
        print(event.text, end="", flush=True)       # concatenating partials gives the transcript
    elif isinstance(event, TranscriptFinal):
        print("\nfinal:", event.text)

samples = [...]                                      # floats in [-1, 1]
text = client.transcribe_text(PCMAudio.from_samples(samples, 16000))
text = client.transcribe_text(audio, model="parakeet")   # or "parakeet-ultra", "qwen"
```

Any sample rate works; the server resamples. Without `model` the server uses
its default recognizer.

## Voices, status, unload

```python
path = client.create_voice("narrator", PCMAudio.read_wav("reference.wav"))
client.voices()            # ["narrator", ...]
client.status()            # ServerStatus(version, synthesis_model_loaded, transcription_model_loaded,
                           #              transcription_model, requests_served, uptime_seconds)
client.unload()            # release resident models
```

## Errors

Everything derives from `ArkVoiceError`. A server `error` event raises
`ServerError` (`code`, `message`, `request_id`) or its subclass for the code:
`BadRequestError`, `UnsupportedVersionError`, `ModelsMissingError` (run
`ark-voice download`), `UnknownRequestError`, `RequestCancelledError`,
`ServerFailedError`. An error ends only that request; the connection stays
usable.

`NotRunningError` means nothing is listening. `ConnectionClosedError` fails
every pending and later request once the connection ends. `ProtocolError`
(with `reason` for frame errors) means the server sent something malformed.
An error on request id 0 is connection-level: every pending request fails
with it and the connection closes.

## Cancellation

Stop a stream early and the client sends `cancel` for that request, then
discards its remaining frames as they arrive:

```python
with client.synthesize(long_text) as stream:
    for event in stream:
        if done_listening(event):
            break                      # leaving the with-block cancels
```

`stream.close()` / `stream.cancel()` do the same, and so does dropping the
stream object (`for event in client.synthesize(...): break`). No cancel is
sent once the request has already finished.

## Pipelining and threads

Requests are sent when the method is called, so several can be in flight on
one connection. Responses wait in per-request queues until you read them:

```python
stream = client.synthesize("A long paragraph...")
print(client.status())         # answered while synthesis is running
for event in stream: ...
```

`Client` has no background thread. Whichever caller needs a frame reads the
socket and routes what it reads to the right request. Several threads can
share one client.

## asyncio

`AsyncClient` has the same surface. Streams are async iterators; other calls
are awaitable, and the request is sent when you call the method, before you
await it.

```python
import asyncio
from ark_voice import AsyncClient

async def main() -> None:
    async with await AsyncClient.connect() as client:
        status, voices = await asyncio.gather(client.status(), client.voices())
        async for event in client.synthesize("Hello."):
            ...
        text = await client.transcribe_text(audio)

asyncio.run(main())
```

`await stream.aclose()`, `stream.cancel()` or `async with stream:` cancel a
stream early.

## Low-level pieces

`ark_voice` also exports the protocol building blocks: `PROTOCOL_VERSION`,
`default_socket_path()`, `resolve_socket_path()`, `encode_frame`,
`parse_header`, `FrameDecoder` (accepts bytes split anywhere),
`encode_message` (compact, sorted keys, raw UTF-8), `decode_message`,
`encode_samples` / `decode_samples`, and `encode_wav` / `decode_wav`.

## Tests

```sh
uv venv bindings/python/.venv
uv pip install --python bindings/python/.venv/bin/python -e 'bindings/python[test]'
cd bindings/python
.venv/bin/python -m pytest
```

The unit tests check the shared byte vectors in
`bindings/test-vectors/protocol.json` and run the client against a scripted
fake server. The integration tests start a real `ark-voice serve` on a
temporary socket. They use `$ARK_VOICE_BINARY`, else
`<repo>/.build/release/ark-voice`, and skip if neither exists. Tests that
need models skip on `ModelsMissingError`. A test voice
(`bindings-test-python-*`) is created in the daemon's temporary `--model-root` and
deleted again.
