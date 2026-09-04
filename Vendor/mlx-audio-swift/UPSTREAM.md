# Vendored MLX Audio Swift

This source is vendored from `https://github.com/Blaizzy/mlx-audio-swift.git` at commit
`bf14ae0c26e4e85553dd989571cae29d70fa6735`.

The Chatterbox model has a narrow local extension that exposes reusable voice-conditioning data and
a public `DefaultConditioning` initializer. This allows `ark-voice` to create and load named voice
profiles without reprocessing reference audio. The upstream license is retained in `LICENSE`.
