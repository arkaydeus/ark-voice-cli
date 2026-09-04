# ark-voice

`ark-voice` is a native Swift command-line tool for local English speech recognition and speech synthesis on Apple Silicon. It uses MLX Audio Swift with:

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

Synthesize speech with Chatterbox's included default voice:

```sh
ark-voice tts "Hello from my Mac" --output hello.wav
```

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
characters. Chunks are synthesized in sequence and joined with a short pause in the output WAV.

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

## Notes

- The tool is intentionally English-only and has no language-selection option.
- Input decoding uses AVFoundation. MP4 files must contain an audio track.
- TTS output is mono WAV at Chatterbox's native 24 kHz sample rate.
- Successful TTS writes only the output WAV path to stdout. Model progress and diagnostics go to stderr.
- Successful voice creation writes only the saved profile path to stdout.
- Set `HF_TOKEN` if Hugging Face requires authentication in your environment.

## Tests

Run the model-independent test suite with:

```sh
swift test
```

Model-backed integration tests are opt-in because they require downloaded models and the packaged Metal runtime:

```sh
ARK_VOICE_INTEGRATION_BINARY=.build/release/ark-voice \
  ARK_VOICE_INTEGRATION_STT_AUDIO=/path/to/sample.wav \
  swift test
```
