# Vendored MLX Audio Swift

This source is vendored from `https://github.com/Blaizzy/mlx-audio-swift.git` at commit
`bf14ae0c26e4e85553dd989571cae29d70fa6735`.

The Chatterbox model has a narrow local extension that exposes reusable voice-conditioning data and
a public `DefaultConditioning` initializer. This allows `ark-voice` to create and load named voice
profiles without reprocessing reference audio. The upstream license is retained in `LICENSE`.

## Local patch: routed diagnostics (`MLXAudioLog`)

`Sources/MLXAudioCore/MLXAudioLog.swift` is a local addition, and every `print(...)` in the
`MLXAudioCore`, `MLXAudioCodecs`, `MLXAudioTTS`, and `MLXAudioSTT` targets was mechanically
rewritten to `MLXAudioLog.log(...)`. The call signature mirrors `print`, so re-vendoring only
requires reapplying the same substitution:

```sh
for t in MLXAudioCore MLXAudioCodecs MLXAudioTTS MLXAudioSTT; do
  grep -rl 'print(' Sources/$t --include='*.swift' | grep -v MLXAudioLog.swift \
    | xargs sed -i '' -E 's/(^|[^.[:alnum:]_])print\(/\1MLXAudioLog.log(/g'
done
```

`MLXAudioLog.handler` defaults to stderr. Without this patch, model progress lands on stdout, which
`ark-voice` needs as a binary audio channel and which a host process cannot safely reclaim: the
previous workaround redirected `STDOUT_FILENO` with `dup2` for the duration of generation, and that
is process-global and therefore unsafe once more than one request runs at a time.

Two Chatterbox files (`T3/T3Model.swift`, `T3/T3GPT2Model.swift`) gained `import MLXAudioCore`.

## Local patch: HTTP-only Hub downloads

The manifest requires swift-huggingface 0.9.0 with no traits, so its optional Xet
transport is not linked. Downloads use the Apache-2.0 licensed HTTP implementation;
the unlicensed swift-xet 0.2.3 source is excluded from the executable.
