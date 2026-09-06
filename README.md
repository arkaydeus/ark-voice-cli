# ark-voice

`ark-voice` is local English speech recognition and synthesis on Apple Silicon, usable three ways:

- as a **command-line tool**, including streaming audio to and from pipes
- as a **Swift library** (`ArkVoiceKit`) linked directly into another app
- as a **server** (`ark-voice serve`) that keeps models resident and answers requests over a Unix socket

It uses MLX Audio Swift with:

- `sonic-speech/parakeet-tdt-0.6b-v2-int8` for English STT
- `mlx-community/chatterbox-turbo-6bit` for English TTS
- `mlx-community/S3TokenizerV2`, required by Chatterbox and voice cloning

Models are not included in the executable. They are downloaded only when you run `ark-voice download`, and are stored under `~/.ark-voice-cli`.

Downloads are pinned to reviewed Hugging Face commit revisions. Required files and sizes are validated, model-weight SHA-256 checksums are verified, and a completed snapshot is activated atomically so an interrupted download cannot be mistaken for a usable model.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Swift 6.2 or newer
- Xcode Command Line Tools
- Internet access for the one-time model download

## Build

```sh
./Scripts/build-release.sh
```

MLX's Swift package cannot build its Metal shaders with plain `swift build`. The build script compiles the Swift executable and retrieves the checksum-pinned Metal runtime from the matching official MLX Swift 0.31.6 release. The runtime archive is about 200 MB and is cached under `.build/artifacts`; it is not a speech model. Keep both output artifacts in the same directory:

```text
.build/release/ark-voice
.build/release/mlx.metallib
```

For a system-wide install:

```sh
sudo install -d /usr/local/libexec/ark-voice /usr/local/bin
sudo install -m 755 .build/release/ark-voice /usr/local/libexec/ark-voice/ark-voice
sudo install -m 644 .build/release/mlx.metallib /usr/local/libexec/ark-voice/mlx.metallib
sudo ln -sfn /usr/local/libexec/ark-voice/ark-voice /usr/local/bin/ark-voice
```

## Use

Download both models and the Chatterbox tokenizer:

```sh
ark-voice download
```

Transcribe WAV, AAC, M4A, or MP4 audio:

```sh
ark-voice stt recording.wav
ark-voice stt voice-note.m4a --output transcript.txt
ark-voice stt interview.mp4 -o interview.txt
```

Print text as it is recognized instead of waiting for the whole transcript, and read audio from
stdin. Container audio on stdin is detected from its leading bytes; headerless PCM needs
`--input-format` (and `--input-rate` if it is not 16 kHz):

```sh
ark-voice stt long-meeting.m4a --stream
cat recording.wav | ark-voice stt -
ark-voice stt - --input-format s16le --input-rate 24000 < raw.pcm
```

Synthesize speech with Chatterbox's included default voice. WAV remains the default output:

```sh
ark-voice tts "Hello from my Mac" --output hello.wav
```

For smaller output, select AAC-LC in an M4A container or ADTS-framed AAC by using the corresponding
extension:

```sh
ark-voice tts "Hello from my Mac" --output hello.m4a
ark-voice tts "Hello from my Mac" --output hello.aac
```

Both AAC forms are mono at Chatterbox's native 24 kHz sample rate and use a 48 kbps target bitrate.

Write audio to stdout as it is generated, so playback starts on the first chunk rather than after the
whole utterance:

```sh
ark-voice tts "Hello from my Mac" -o - | ffplay -autoexit -nodisp -
ark-voice tts --file article.txt -o - > article.wav
```

Streaming to stdout produces a WAV stream whose header declares an unknown length, which players and
ffmpeg read as "until the stream ends". For headerless samples, add `--raw`, and choose the sample
encoding with `--format f32le` (default) or `--format s16le` (half the bytes, no audible loss):

```sh
ark-voice tts "Pipe me" -o - --raw --format s16le | ark-voice stt - --input-format s16le --input-rate 24000
```

Diagnostics always go to stderr, so stdout stays a clean data channel.

Use `--` before inline text that starts with a hyphen:

```sh
ark-voice tts -- "-5 degrees outside" -o weather.wav
```

Read text from a file or stdin:

```sh
ark-voice tts --file article.txt -o article.wav
printf 'Hello there' | ark-voice tts --file - -o hello.wav
```

Long text is automatically split at sentence or word boundaries into chunks of at most 300
characters. Chunks are synthesized in sequence and joined with a short pause in the output audio.

Use a reference recording for zero-shot voice cloning:

```sh
ark-voice tts "This uses the reference voice" \
  --reference speaker.m4a \
  --output cloned.wav
```

Only clone voices you have permission to use.

Create a reusable named voice profile so future generations do not need to decode or process the
reference recording again:

```sh
ark-voice voice create narrator speaker.m4a
ark-voice tts --voice narrator --file article.txt -o narrated.wav
ark-voice voices
```

Voice profiles are stored locally under `~/.ark-voice-cli/voices` as safetensors files. A profile
contains speaker-conditioning data derived from the recording, so protect and share it as carefully
as the original voice sample. Voice names may contain letters, numbers, hyphens, and underscores.
Creating a profile never overwrites an existing voice with the same name.

Check model locations and status:

```sh
ark-voice models
```

You can download only one side of the stack with `ark-voice download stt` or `ark-voice download tts`. The latter also downloads Chatterbox's speech tokenizer.


## Use from another app

Two ways, depending on whether the caller is Swift.

### Link the library

`ArkVoiceKit` is a library product. A Swift host links it and gets the models in its own process —
no IPC, no serialization, and the models stay loaded between calls:

```swift
.package(path: "../ark-voice-cli")
...
.product(name: "ArkVoiceKit", package: "ark-voice-cli")
```

```swift
import ArkVoiceKit

let session = VoiceSession(configuration: SessionConfiguration(
  modelRoot: URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ark-voice-cli"),
  progress: { event in print(event) }   // nothing is written to stdout or stderr for you
))

// Audio arrives chunk by chunk, as it is generated.
for try await chunk in session.synthesize("Hello", voice: .named("narrator")) {
  player.enqueue(chunk.samples)         // mono Float32 at chunk.sampleRate (24 kHz)
}

// Transcription reports text as it is recognized.
for try await event in session.transcribe(samples: recordedAt16kHz) {
  if case .final(let text) = event { print(text) }
}

await session.unloadModels()            // waits for current work, then releases the models
```

A session is safe to share across tasks. Model work is serialized internally because the models
cannot run concurrently. The first call to each side loads that model; every later call pays only
for inference. `AudioDecoding` converts files and raw PCM into the `[Float]` buffers the API takes.

A host that embeds the kit must ship MLX's `mlx.metallib` and point `SessionConfiguration.metallibURL`
at it, or place it beside the executable.

### Talk to the server

For callers that are not Swift, or that would rather keep a gigabyte of weights out of their own
address space, run a daemon:

```sh
ark-voice serve                          # ~/.ark-voice-cli/ark-voice.sock, mode 0600
ark-voice serve --socket /tmp/av.sock --idle-unload 120 --idle-exit off
```

and drive it from anywhere:

```sh
ark-voice client tts "No reload for this one" -o quick.wav
ark-voice client tts "Straight to the speakers" -o - | ffplay -autoexit -nodisp -
ark-voice client stt recording.wav --stream
ark-voice client status
ark-voice client unload
```

Control messages are JSON; audio moves as raw little-endian PCM frames, never base64 inside JSON.
The wire format is documented in [PROTOCOL.md](PROTOCOL.md), and `Scripts/client.py` implements a
complete client with nothing but the Python standard library:

```sh
./Scripts/client.py speak "Hello from Python" out.wav
./Scripts/client.py transcribe recording.wav
```

What this buys, measured on an M-series Mac with the weights already in the page cache:

| | one short utterance |
| --- | --- |
| `ark-voice tts` (process per call) | ~5.9 s |
| `ark-voice client tts` (resident models) | ~0.24 s |

Requests may be pipelined on one connection — every frame carries its request id — though model work
still runs one at a time. `--idle-unload` (default 300 s) releases the models during quiet periods,
and `Scripts/com.ark-voice.serve.plist` is an example launchd agent.

With `stt --stream -o transcript.txt`, incremental text is written to stderr while the final
transcript is installed atomically at the requested path. Without `-o`, incremental text uses stdout.

Live microphone transcription is not supported: the recognizer needs the whole recording before it
starts, so the socket takes a complete utterance and streams the text back. The protocol leaves room
for a `stt-live` operation to be added without breaking clients.

## Notes

- The tool is intentionally English-only and has no language-selection option.
- Input decoding uses AVFoundation. MP4 files must contain an audio track.
- TTS output can be Float32 WAV, AAC-LC in M4A, or ADTS AAC. All are mono at Chatterbox's native
  24 kHz sample rate; WAV is the default.
- Successful TTS writes only the output audio path to stdout, or the audio itself with `--output -`.
  Model progress and diagnostics always go to stderr.
- Successful voice creation writes only the saved profile path to stdout.
- Set `HF_TOKEN` if Hugging Face requires authentication in your environment.

## Tests

Run the model-independent test suite with:

```sh
swift test
```

That covers argument parsing, chunking, audio encoding and decoding, the wire protocol, and the
server end to end over a real socket — the server tests need no models, because a session pointed at
an empty model root answers with errors rather than loading weights.

A debug test run ends with MLX complaining `Failed to load the default metallib`, because the Metal
runtime is only packaged for release builds. The tests still pass. Put the runtime beside the test
binary to silence it and to run the opt-in safetensors tests:

```sh
./Scripts/build-release.sh
cp .build/release/mlx.metallib \
  .build/debug/ark-voice-cliPackageTests.xctest/Contents/MacOS/
ARK_VOICE_TEST_MLX=1 swift test
```

Model-backed integration tests are opt-in because they require downloaded models and the packaged Metal runtime:

```sh
ARK_VOICE_INTEGRATION_BINARY=.build/release/ark-voice \
  ARK_VOICE_INTEGRATION_STT_AUDIO=/path/to/sample.wav \
  swift test
```

Those cover writing a file, streaming a WAV to stdout, and a full round trip through the daemon:
synthesize a sentence, transcribe the result, and confirm the models stayed loaded.
