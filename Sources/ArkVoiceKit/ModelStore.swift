import CryptoKit
import Foundation
import HuggingFace

public struct ModelArtifact: Sendable {
  public let path: String
  public let byteCount: Int
  public let sha256: String?

  public init(path: String, byteCount: Int, sha256: String?) {
    self.path = path
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

public struct ModelSpec: Sendable {
  public let title: String
  public let repository: String
  public let revision: String
  public let purpose: String
  public let artifacts: [ModelArtifact]
  /// Glob patterns selecting which repository files to download.
  public let downloadPatterns: [String]

  /// Covers MLX checkpoints: weights, configuration, and tokenizer files.
  public static let defaultDownloadPatterns = ["*.safetensors", "*.json", "*.txt", "*.model"]

  public init(
    title: String,
    repository: String,
    revision: String,
    purpose: String,
    artifacts: [ModelArtifact],
    downloadPatterns: [String] = ModelSpec.defaultDownloadPatterns
  ) {
    self.title = title
    self.repository = repository
    self.revision = revision
    self.purpose = purpose
    self.artifacts = artifacts
    self.downloadPatterns = downloadPatterns
  }
}

private struct DownloadMarker: Codable, Equatable {
  let repository: String
  let revision: String
}

public enum ModelStoreError: LocalizedError {
  case invalidRepository(String)
  case incompleteModel(String, [String])
  /// Titles of the missing models, and the `download` argument that fetches them.
  case missingModels([String], download: ModelSelection)

  public var errorDescription: String? {
    switch self {
    case .invalidRepository(let repository):
      "Invalid Hugging Face repository ID: \(repository)"
    case .incompleteModel(let model, let problems):
      "Downloaded model '\(model)' failed validation: \(problems.joined(separator: ", "))"
    case .missingModels(let models, let selection):
      "Required model data is missing or incomplete: \(models.joined(separator: ", ")). Run 'ark-voice download \(selection.rawValue)' first."
    }
  }
}

/// Which models a download or status query covers.
///
/// `all` and `stt` fetch only the default recognizer: the optional ones are
/// large, so each is downloaded only when asked for by name.
public enum ModelSelection: String, Equatable, Sendable, CaseIterable {
  case all
  case stt
  case tts
  case parakeet
  case parakeetUltra = "parakeet-ultra"
  case qwen

  public init(_ model: TranscriptionModel) {
    switch model {
    case .parakeet: self = .parakeet
    case .parakeetUltra: self = .parakeetUltra
    case .qwen: self = .qwen
    }
  }

  public static var optionsDescription: String {
    allCases.map(\.rawValue).joined(separator: "|")
  }
}

public enum ModelStore {
  private static let markerName = ".ark-voice-model.json"

  public static let parakeet = ModelSpec(
    title: "Parakeet TDT 0.6B v2 INT8",
    repository: "sonic-speech/parakeet-tdt-0.6b-v2-int8",
    revision: "01b91aab2fec0ea1d46a7eaf5ead1926568c1358",
    purpose: "English speech recognition",
    artifacts: [
      ModelArtifact(path: "config.json", byteCount: 36_374, sha256: nil),
      ModelArtifact(
        path: "model.safetensors",
        byteCount: 736_486_637,
        sha256: "996a833c31980677fcd6fd8e082435fb49152431d5be2062de636c17d8e31152"
      ),
    ]
  )

  /// Core ML build of Moondream's Parakeet Ultra, run by FluidAudio.
  ///
  /// Only the files FluidAudio loads for `.ultra` are fetched; the repository
  /// also carries a README and a duplicate vocabulary.
  public static let parakeetUltra = ModelSpec(
    title: "Parakeet Ultra (Core ML)",
    repository: "FluidInference/parakeet-ultra-coreml",
    revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
    purpose: "Multilingual speech recognition on the Neural Engine",
    artifacts: parakeetUltraArtifacts,
    downloadPatterns: parakeetUltraArtifacts.map(\.path)
  )

  private static let parakeetUltraArtifacts = [
    ModelArtifact(path: "Decoder.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: nil),
    ModelArtifact(path: "Decoder.mlmodelc/coremldata.bin", byteCount: 560, sha256: nil),
    ModelArtifact(path: "Decoder.mlmodelc/model.mil", byteCount: 13_110, sha256: nil),
    ModelArtifact(
      path: "Decoder.mlmodelc/weights/weight.bin",
      byteCount: 23_604_992,
      sha256: "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4"
    ),
    ModelArtifact(path: "Encoder.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: nil),
    ModelArtifact(path: "Encoder.mlmodelc/coremldata.bin", byteCount: 514, sha256: nil),
    ModelArtifact(path: "Encoder.mlmodelc/model.mil", byteCount: 1_002_653, sha256: nil),
    ModelArtifact(
      path: "Encoder.mlmodelc/weights/weight.bin",
      byteCount: 594_211_328,
      sha256: "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"
    ),
    ModelArtifact(
      path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: nil),
    ModelArtifact(path: "JointDecisionv3.mlmodelc/coremldata.bin", byteCount: 592, sha256: nil),
    ModelArtifact(path: "JointDecisionv3.mlmodelc/model.mil", byteCount: 11_777, sha256: nil),
    ModelArtifact(
      path: "JointDecisionv3.mlmodelc/weights/weight.bin",
      byteCount: 12_642_764,
      sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"
    ),
    ModelArtifact(
      path: "Preprocessor.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: nil),
    ModelArtifact(path: "Preprocessor.mlmodelc/coremldata.bin", byteCount: 486, sha256: nil),
    ModelArtifact(path: "Preprocessor.mlmodelc/metadata.json", byteCount: 2_841, sha256: nil),
    ModelArtifact(path: "Preprocessor.mlmodelc/model.mil", byteCount: 28_181, sha256: nil),
    ModelArtifact(
      path: "Preprocessor.mlmodelc/weights/weight.bin",
      byteCount: 491_072,
      sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"
    ),
    ModelArtifact(path: "config.json", byteCount: 414, sha256: nil),
    ModelArtifact(
      path: "parakeet_vocab.json",
      byteCount: 151_122,
      sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"
    ),
  ]

  public static let qwen3ASR = ModelSpec(
    title: "Qwen3-ASR 1.7B 8-bit",
    repository: "mlx-community/Qwen3-ASR-1.7B-8bit",
    revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    purpose: "Multilingual speech recognition",
    artifacts: [
      ModelArtifact(path: "chat_template.json", byteCount: 1_161, sha256: nil),
      ModelArtifact(path: "config.json", byteCount: 7_188, sha256: nil),
      ModelArtifact(path: "generation_config.json", byteCount: 142, sha256: nil),
      ModelArtifact(path: "merges.txt", byteCount: 1_671_853, sha256: nil),
      ModelArtifact(
        path: "model.safetensors",
        byteCount: 2_463_307_541,
        sha256: "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"
      ),
      ModelArtifact(path: "model.safetensors.index.json", byteCount: 78_968, sha256: nil),
      ModelArtifact(path: "preprocessor_config.json", byteCount: 330, sha256: nil),
      ModelArtifact(path: "tokenizer_config.json", byteCount: 12_487, sha256: nil),
      ModelArtifact(path: "vocab.json", byteCount: 2_776_833, sha256: nil),
    ]
  )

  public static let chatterbox = ModelSpec(
    title: "Chatterbox Turbo 6-bit",
    repository: "mlx-community/chatterbox-turbo-6bit",
    revision: "afbfd1f8a32f2bc1f32e0fb6b7663c04327e8ff1",
    purpose: "English speech synthesis",
    artifacts: [
      ModelArtifact(path: "added_tokens.json", byteCount: 418, sha256: nil),
      ModelArtifact(
        path: "conds.safetensors",
        byteCount: 164_884,
        sha256: "df9ad2c54848027d94cf01f9fc0ed22bc5d3165df6e6a85c903c1124b8a78a4a"
      ),
      ModelArtifact(path: "config.json", byteCount: 2_565, sha256: nil),
      ModelArtifact(path: "merges.txt", byteCount: 456_318, sha256: nil),
      ModelArtifact(
        path: "model.safetensors",
        byteCount: 560_612_646,
        sha256: "50737677896b0e35a7526662c127841040830b826ef8a2d017bddcea6f23e4ef"
      ),
      ModelArtifact(path: "model.safetensors.index.json", byteCount: 252_012, sha256: nil),
      ModelArtifact(path: "special_tokens_map.json", byteCount: 470, sha256: nil),
      ModelArtifact(path: "tokenizer_config.json", byteCount: 3_878, sha256: nil),
      ModelArtifact(path: "vocab.json", byteCount: 999_186, sha256: nil),
    ]
  )

  public static let s3Tokenizer = ModelSpec(
    title: "S3TokenizerV2",
    repository: "mlx-community/S3TokenizerV2",
    revision: "e0c9886f0e1c35ae85b1f27277416fb19fc72bec",
    purpose: "Chatterbox speech tokenizer",
    artifacts: [
      ModelArtifact(path: "config.json", byteCount: 126, sha256: nil),
      ModelArtifact(
        path: "model.safetensors",
        byteCount: 494_868_984,
        sha256: "928726bc1f206a613d36b8f49e297eae9c5593a21bf9b92ddfe2c23f85eb92cc"
      ),
    ]
  )

  /// Every model `ark-voice` knows about, downloaded or not.
  public static let all = [parakeet, parakeetUltra, qwen3ASR, chatterbox, s3Tokenizer]

  /// Where models and voices live unless a host chooses otherwise.
  public static let defaultRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".ark-voice-cli", isDirectory: true)

  public static var root: URL { defaultRoot }

  public static func cache(root: URL = defaultRoot) -> HubCache {
    HubCache(cacheDirectory: root)
  }

  /// Points the Hugging Face client at `root`.
  ///
  /// `setenv` is process-global, so this is called only where a download is
  /// actually about to happen rather than at session construction.
  public static func configureEnvironment(root: URL = defaultRoot) {
    setenv("HF_HUB_CACHE", root.path, 1)
  }

  public static func selected(_ selection: ModelSelection) -> [ModelSpec] {
    switch selection {
    case .all: [parakeet, chatterbox, s3Tokenizer]
    case .stt, .parakeet: [parakeet]
    case .tts: [chatterbox, s3Tokenizer]
    case .parakeetUltra: [parakeetUltra]
    case .qwen: [qwen3ASR]
    }
  }

  public static func spec(for model: TranscriptionModel) -> ModelSpec {
    switch model {
    case .parakeet: parakeet
    case .parakeetUltra: parakeetUltra
    case .qwen: qwen3ASR
    }
  }

  public static func modelDirectory(for model: ModelSpec) -> URL {
    modelDirectory(for: model, root: root)
  }

  public static func modelDirectory(for model: ModelSpec, root: URL) -> URL {
    let directory = model.repository.replacingOccurrences(of: "/", with: "_")
    return
      root
      .appendingPathComponent("mlx-audio", isDirectory: true)
      .appendingPathComponent(directory, isDirectory: true)
  }

  public static func isDownloaded(_ model: ModelSpec) -> Bool {
    isDownloaded(model, root: root)
  }

  public static func isDownloaded(_ model: ModelSpec, root: URL) -> Bool {
    validationProblems(
      for: model,
      in: modelDirectory(for: model, root: root),
      requireMarker: true,
      verifyHashes: false
    ).isEmpty
  }

  public static func validationProblems(
    for model: ModelSpec,
    in directory: URL,
    requireMarker: Bool,
    verifyHashes: Bool
  ) -> [String] {
    var problems: [String] = []

    if requireMarker {
      let markerURL = directory.appendingPathComponent(markerName)
      let expectedMarker = DownloadMarker(repository: model.repository, revision: model.revision)
      guard let data = try? Data(contentsOf: markerURL),
        let marker = try? JSONDecoder().decode(DownloadMarker.self, from: data),
        marker == expectedMarker
      else {
        problems.append("missing completion marker for revision \(model.revision)")
        return problems
      }
    }

    for artifact in model.artifacts {
      let url = directory.appendingPathComponent(artifact.path)
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
        values.fileSize == artifact.byteCount
      else {
        problems.append("missing or invalid \(artifact.path)")
        continue
      }

      if verifyHashes, let expectedHash = artifact.sha256 {
        do {
          let actualHash = try sha256(of: url)
          if actualHash != expectedHash {
            problems.append("checksum mismatch for \(artifact.path)")
          }
        } catch {
          problems.append("could not hash \(artifact.path): \(error.localizedDescription)")
        }
      }
    }

    let configURL = directory.appendingPathComponent("config.json")
    if let data = try? Data(contentsOf: configURL),
      (try? JSONSerialization.jsonObject(with: data)) == nil
    {
      problems.append("invalid config.json")
    }

    return problems
  }

  public static func requireDownloaded(_ models: [ModelSpec], root: URL = defaultRoot) throws {
    let missing = models.filter { !isDownloaded($0, root: root) }
    guard missing.isEmpty else {
      throw ModelStoreError.missingModels(
        missing.map(\.title), download: narrowestSelection(covering: missing))
    }
  }

  /// The smallest `download` argument that fetches every one of `models`.
  static func narrowestSelection(covering models: [ModelSpec]) -> ModelSelection {
    let wanted = Set(models.map(\.repository))
    let candidates: [ModelSelection] = [.parakeet, .parakeetUltra, .qwen, .tts, .all]
    return candidates.first { selection in
      wanted.isSubset(of: selected(selection).map(\.repository))
    } ?? .all
  }

  public static func download(
    _ models: [ModelSpec],
    root: URL = defaultRoot,
    progress: (@Sendable (ProgressEvent) -> Void)? = nil
  ) async throws {
    configureEnvironment(root: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    for model in models {
      if !isDownloaded(model, root: root) {
        try await download(model, root: root, progress: progress)
      }
      try prepareForFirstUse(model, root: root, progress: progress)
      progress?(.modelDownloadFinished(model: model.title, directory: modelDirectory(for: model, root: root)))
    }
  }

  /// Compiles Core ML models for this Mac now, so the first transcription
  /// does not spend several seconds doing it.
  ///
  /// Core ML caches the compiled form per executable, per macOS build, and per
  /// model path. So this runs at the model's final location, benefits later
  /// runs of the same executable, and costs almost nothing once cached. After
  /// a macOS update, downloading again re-warms the cache.
  private static func prepareForFirstUse(
    _ model: ModelSpec,
    root: URL,
    progress: (@Sendable (ProgressEvent) -> Void)?
  ) throws {
    guard model.repository == parakeetUltra.repository else { return }
    progress?(.message("Preparing \(model.title) for the Neural Engine..."))
    _ = try ParakeetUltraRecognizer(directory: modelDirectory(for: model, root: root))
  }

  private static func download(
    _ model: ModelSpec,
    root: URL,
    progress: (@Sendable (ProgressEvent) -> Void)?
  ) async throws {
    guard let repository = Repo.ID(rawValue: model.repository) else {
      throw ModelStoreError.invalidRepository(model.repository)
    }

    let stagingRoot = root.appendingPathComponent(".staging", isDirectory: true)
    let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    let client = HubClient(cache: cache(root: root))
    progress?(.modelDownloadStarted(model: model.title))
    let title = model.title
    _ = try await client.downloadSnapshot(
      of: repository,
      kind: .model,
      to: staging,
      revision: model.revision,
      matching: model.downloadPatterns,
      progressHandler: { completed in
        progress?(
          .modelDownloadProgress(
            model: title,
            completedBytes: completed.completedUnitCount,
            totalBytes: completed.totalUnitCount
          )
        )
      }
    )

    let problems = validationProblems(
      for: model,
      in: staging,
      requireMarker: false,
      verifyHashes: true
    )
    guard problems.isEmpty else {
      try? FileManager.default.removeItem(
        at: cache(root: root).repoDirectory(repo: repository, kind: .model)
      )
      throw ModelStoreError.incompleteModel(model.title, problems)
    }

    try writeCompletionMarker(for: model, in: staging)
    try activate(staging: staging, for: model, root: root)
  }

  public static func writeCompletionMarker(for model: ModelSpec, in directory: URL) throws {
    let marker = DownloadMarker(repository: model.repository, revision: model.revision)
    let markerData = try JSONEncoder().encode(marker)
    try markerData.write(
      to: directory.appendingPathComponent(markerName),
      options: .atomic
    )
  }

  private static func activate(staging: URL, for model: ModelSpec, root: URL) throws {
    let destination = modelDirectory(for: model, root: root)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let backup = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).backup-\(UUID().uuidString)")
    let hadExistingModel = FileManager.default.fileExists(atPath: destination.path)

    if hadExistingModel {
      try FileManager.default.moveItem(at: destination, to: backup)
    }

    do {
      try FileManager.default.moveItem(at: staging, to: destination)
      if hadExistingModel {
        try FileManager.default.removeItem(at: backup)
      }
    } catch {
      if FileManager.default.fileExists(atPath: destination.path) {
        try? FileManager.default.removeItem(at: destination)
      }
      if hadExistingModel, FileManager.default.fileExists(atPath: backup.path) {
        try? FileManager.default.moveItem(at: backup, to: destination)
      }
      throw error
    }
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
