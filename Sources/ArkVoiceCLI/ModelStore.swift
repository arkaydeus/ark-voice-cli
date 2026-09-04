import CryptoKit
import Foundation
import HuggingFace

struct ModelArtifact: Sendable {
  let path: String
  let byteCount: Int
  let sha256: String?
}

struct ModelSpec: Sendable {
  let title: String
  let repository: String
  let revision: String
  let purpose: String
  let artifacts: [ModelArtifact]
}

private struct DownloadMarker: Codable, Equatable {
  let repository: String
  let revision: String
}

enum ModelStoreError: LocalizedError {
  case invalidRepository(String)
  case incompleteModel(String, [String])
  case missingModels([String])

  var errorDescription: String? {
    switch self {
    case .invalidRepository(let repository):
      "Invalid Hugging Face repository ID: \(repository)"
    case .incompleteModel(let model, let problems):
      "Downloaded model '\(model)' failed validation: \(problems.joined(separator: ", "))"
    case .missingModels(let models):
      "Required model data is missing or incomplete: \(models.joined(separator: ", ")). Run 'ark-voice download' first."
    }
  }
}

enum ModelStore {
  private static let markerName = ".ark-voice-model.json"

  static let parakeet = ModelSpec(
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

  static let chatterbox = ModelSpec(
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

  static let s3Tokenizer = ModelSpec(
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

  static let all = [parakeet, chatterbox, s3Tokenizer]

  static var root: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ark-voice-cli", isDirectory: true)
  }

  static var cache: HubCache {
    HubCache(cacheDirectory: root)
  }

  static func configureEnvironment() {
    setenv("HF_HUB_CACHE", root.path, 1)
  }

  static func selected(_ selection: ModelSelection) -> [ModelSpec] {
    switch selection {
    case .all: all
    case .stt: [parakeet]
    case .tts: [chatterbox, s3Tokenizer]
    }
  }

  static func modelDirectory(for model: ModelSpec) -> URL {
    modelDirectory(for: model, root: root)
  }

  static func modelDirectory(for model: ModelSpec, root: URL) -> URL {
    let directory = model.repository.replacingOccurrences(of: "/", with: "_")
    return
      root
      .appendingPathComponent("mlx-audio", isDirectory: true)
      .appendingPathComponent(directory, isDirectory: true)
  }

  static func isDownloaded(_ model: ModelSpec) -> Bool {
    isDownloaded(model, root: root)
  }

  static func isDownloaded(_ model: ModelSpec, root: URL) -> Bool {
    validationProblems(
      for: model,
      in: modelDirectory(for: model, root: root),
      requireMarker: true,
      verifyHashes: false
    ).isEmpty
  }

  static func validationProblems(
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

  static func requireDownloaded(_ models: [ModelSpec]) throws {
    let missing = models.filter { !isDownloaded($0) }.map(\.title)
    guard missing.isEmpty else { throw ModelStoreError.missingModels(missing) }
  }

  static func download(_ models: [ModelSpec]) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    for (index, model) in models.enumerated() {
      print("[\(index + 1)/\(models.count)] \(model.title)")
      if isDownloaded(model) {
        print("Using validated model at: \(modelDirectory(for: model).path)")
        continue
      }
      try await download(model)
    }
  }

  private static func download(_ model: ModelSpec) async throws {
    guard let repository = Repo.ID(rawValue: model.repository) else {
      throw ModelStoreError.invalidRepository(model.repository)
    }

    let stagingRoot = root.appendingPathComponent(".staging", isDirectory: true)
    let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    let client = HubClient(cache: cache)
    print("Downloading \(model.repository) at revision \(model.revision)...")
    _ = try await client.downloadSnapshot(
      of: repository,
      kind: .model,
      to: staging,
      revision: model.revision,
      matching: ["*.safetensors", "*.json", "*.txt", "*.model"],
      progressHandler: { progress in
        print("\(progress.completedUnitCount)/\(progress.totalUnitCount) bytes")
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
        at: cache.repoDirectory(repo: repository, kind: .model)
      )
      throw ModelStoreError.incompleteModel(model.title, problems)
    }

    try writeCompletionMarker(for: model, in: staging)
    try activate(staging: staging, for: model)
    print("Model downloaded to: \(modelDirectory(for: model).path)")
  }

  static func writeCompletionMarker(for model: ModelSpec, in directory: URL) throws {
    let marker = DownloadMarker(repository: model.repository, revision: model.revision)
    let markerData = try JSONEncoder().encode(marker)
    try markerData.write(
      to: directory.appendingPathComponent(markerName),
      options: .atomic
    )
  }

  private static func activate(staging: URL, for model: ModelSpec) throws {
    let destination = modelDirectory(for: model)
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
