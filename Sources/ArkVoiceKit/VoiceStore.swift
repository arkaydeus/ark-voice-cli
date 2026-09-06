import Foundation
import MLX
import MLXAudioTTS

public enum VoiceStoreError: LocalizedError {
  case invalidName(String)
  case alreadyExists(String)
  case notFound(String)
  case incompatible(String)
  case invalidProfile(String)

  public var errorDescription: String? {
    switch self {
    case .invalidName(let name):
      "Invalid voice name '\(name)'. Use 1-64 letters, numbers, hyphens, or underscores."
    case .alreadyExists(let name):
      "Voice '\(name)' already exists. Choose a different name."
    case .notFound(let name):
      "Voice '\(name)' was not found. Run 'ark-voice voices' to list saved voices."
    case .incompatible(let name):
      "Voice '\(name)' was created for a different Chatterbox model revision."
    case .invalidProfile(let name):
      "Voice '\(name)' contains invalid or incomplete conditioning data."
    }
  }
}

public enum VoiceStore {
  private static let schemaVersion = "1"
  private static let requiredArrayNames: Set<String> = [
    "gen.embedding",
    "gen.prompt_feat",
    "gen.prompt_feat_len",
    "gen.prompt_token",
    "gen.prompt_token_len",
    "t3.cond_prompt_speech_tokens",
    "t3.emotion_adv",
    "t3.speaker_emb",
  ]

  public static var root: URL { root(modelRoot: ModelStore.defaultRoot) }

  /// Voices live beside the models they were created for.
  public static func root(modelRoot: URL) -> URL {
    modelRoot.appendingPathComponent("voices", isDirectory: true)
  }

  public static func validateName(_ name: String) throws {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    )
    guard !name.isEmpty, name.count <= 64,
      name.unicodeScalars.allSatisfy(allowed.contains),
      name.first?.isLetter == true || name.first?.isNumber == true
    else {
      throw VoiceStoreError.invalidName(name)
    }
  }

  public static func save(
    _ conditioning: DefaultConditioning,
    name: String,
    root: URL = root,
    stream: StreamOrDevice = .default
  ) throws -> URL {
    try requireAvailable(name: name, root: root)
    let destination = root.appendingPathComponent("\(name).safetensors")

    let arrays = arrays(from: conditioning)
    let metadata = [
      "ark_voice_schema": schemaVersion,
      "model_repository": ModelStore.chatterbox.repository,
      "model_revision": ModelStore.chatterbox.revision,
    ]
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let temporary = root.appendingPathComponent(".\(name)-\(UUID().uuidString).safetensors")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try MLX.save(arrays: arrays, metadata: metadata, url: temporary, stream: stream)
    try FileManager.default.moveItem(at: temporary, to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
    return destination
  }

  public static func requireAvailable(name: String, root: URL = root) throws {
    try validateName(name)
    let destination = root.appendingPathComponent("\(name).safetensors")
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw VoiceStoreError.alreadyExists(name)
    }
  }

  /// Reads a saved profile.
  ///
  /// Loading happens on the CPU stream and the arrays are materialized before
  /// they are returned: MLX cannot evaluate a deferred `Load` on the GPU, so a
  /// lazily loaded profile crashes the first time synthesis touches it.
  public static func load(
    name: String,
    root: URL = root,
    stream: StreamOrDevice = .cpu
  ) throws -> DefaultConditioning {
    try validateName(name)
    let url = root.appendingPathComponent("\(name).safetensors")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw VoiceStoreError.notFound(name)
    }

    let (arrays, metadata) = try MLX.loadArraysAndMetadata(url: url, stream: stream)
    MLX.eval(Array(arrays.values))
    guard metadata["ark_voice_schema"] == schemaVersion,
      metadata["model_repository"] == ModelStore.chatterbox.repository,
      metadata["model_revision"] == ModelStore.chatterbox.revision
    else {
      throw VoiceStoreError.incompatible(name)
    }
    guard requiredArrayNames.isSubset(of: Set(arrays.keys)),
      arrays["t3.speaker_emb"]?.shape == [1, 256],
      arrays["gen.embedding"]?.shape == [1, 192],
      arrays["t3.cond_prompt_speech_tokens"]?.ndim == 2,
      arrays["gen.prompt_token"]?.ndim == 2,
      arrays["gen.prompt_feat"]?.ndim == 3
    else {
      throw VoiceStoreError.invalidProfile(name)
    }

    return DefaultConditioning(
      speakerEmb: arrays["t3.speaker_emb"]!,
      condPromptSpeechTokens: arrays["t3.cond_prompt_speech_tokens"]!,
      emotionAdv: arrays["t3.emotion_adv"]!,
      xVector: arrays["gen.embedding"]!,
      promptToken: arrays["gen.prompt_token"]!,
      promptTokenLen: arrays["gen.prompt_token_len"]!,
      promptFeat: arrays["gen.prompt_feat"]!,
      promptFeatLen: arrays["gen.prompt_feat_len"]!
    )
  }

  public static func names(root: URL = root) throws -> [String] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "safetensors" }
    .map { $0.deletingPathExtension().lastPathComponent }
    .sorted()
  }

  private static func arrays(from conditioning: DefaultConditioning) -> [String: MLXArray] {
    [
      "t3.speaker_emb": conditioning.speakerEmb,
      "t3.cond_prompt_speech_tokens": conditioning.condPromptSpeechTokens,
      "t3.emotion_adv": conditioning.emotionAdv,
      "gen.embedding": conditioning.xVector,
      "gen.prompt_token": conditioning.promptToken,
      "gen.prompt_token_len": conditioning.promptTokenLen,
      "gen.prompt_feat": conditioning.promptFeat,
      "gen.prompt_feat_len": conditioning.promptFeatLen,
    ]
  }
}
