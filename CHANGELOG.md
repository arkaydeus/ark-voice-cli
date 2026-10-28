# Changelog

All notable changes to `ark-voice` are recorded here. Versions follow
[Semantic Versioning](https://semver.org/).

## 0.2.0 — 2026-10-28

The first release distributed as a signed, notarized download.

### Added

- **Selectable recognizers.** `stt --model` chooses between Parakeet TDT v2 (the default, English,
  MLX), Parakeet Ultra (25 European languages on Core ML and the Neural Engine) and Qwen3-ASR 1.7B
  (multilingual, MLX). The optional models are downloaded by name with
  `ark-voice download parakeet-ultra` or `ark-voice download qwen`, and `download parakeet-ultra`
  compiles the model for the Neural Engine straight away.
- **Streaming.** `tts -o -` writes a WAV stream to stdout as audio is generated, and `--raw` with
  `--format f32le|s16le` drops the header. `stt -` reads audio from stdin, detecting containers from
  their leading bytes, or headerless PCM with `--input-format` and `--input-rate`. `stt --stream`
  prints text as it is recognized.
- **Server.** `ark-voice serve` keeps models resident and answers requests over a Unix socket
  (`~/.ark-voice-cli/ark-voice.sock`, mode 0600), with `--idle-unload`, `--idle-exit` and
  `--stt-model`. `ark-voice client tts|stt|voices|status|unload` drives it. The framed wire format is
  documented in `PROTOCOL.md`, `Scripts/client.py` is a standard-library Python client, and
  `Scripts/com.ark-voice.serve.plist` is an example launchd agent. Requests may name a recognizer,
  and `status` reports which one is resident.
- **Library products.** `ArkVoiceKit` runs the models in-process for Swift hosts through
  `VoiceSession`, and `ArkVoiceServer` provides the socket server and client.
- `Scripts/ci.sh` runs the local CI: the release build, the unit and MLX tests, and the model-backed
  integration tests when the models are installed.
- `Scripts/package-release.sh` builds, signs, notarizes and zips a release.
- `THIRD_PARTY_NOTICES.md`, covering the bundled code and the downloadable models.

### Changed

- Diagnostics from the vendored MLX Audio models are routed to stderr at the source instead of by
  temporarily redirecting the process's stdout, which was unsafe once several requests could run.
- Release zips include `libswiftCompatibilitySpan.dylib`, which macOS 14 and 15 need to run the
  executable.

### Fixed

- A plain `swift test` no longer aborts on the missing Metal runtime: the remaining tests that touch
  MLX are opt-in with `ARK_VOICE_TEST_MLX=1`.
- `Scripts/build-release.sh` creates its scratch directory under `$TMPDIR`.

## 0.1.0 — 2026-09-04

The first version: local English speech recognition and synthesis on Apple Silicon.

### Added

- `ark-voice stt` transcribes WAV, AAC, M4A and MP4 audio with Parakeet TDT 0.6B v2.
- `ark-voice tts` synthesizes English speech with Chatterbox Turbo to Float32 WAV, AAC-LC in M4A, or
  ADTS AAC, from inline text, a file or stdin. Long text is split into chunks of at most 300
  characters.
- Zero-shot voice cloning with `tts --reference`, and reusable named voice profiles with
  `ark-voice voice create` and `ark-voice voices`.
- `ark-voice download` and `ark-voice models`. Downloads are pinned to reviewed Hugging Face
  revisions, sizes and SHA-256 checksums are verified, and a completed snapshot is activated
  atomically.
- Output files are written atomically, so a failed encode leaves an existing file untouched.
- `Scripts/build-release.sh` builds the executable and fetches the checksum-pinned MLX Metal runtime.
