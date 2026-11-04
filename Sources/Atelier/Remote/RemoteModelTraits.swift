@preconcurrency import DataModels
@preconcurrency import Diffusion
import Foundation
@preconcurrency import ImageGenerator
@preconcurrency import ModelZoo
import Synchronization

/// What a client needs to know about a model it may not have: a community model from the server's
/// custom.json isn't in this device's `ModelZoo`, which would call it an image model with no
/// special inputs. `ModelZoo` can only learn a model by writing it into this device's custom.json,
/// which would list a model the folder doesn't have, so what servers say is kept beside it instead,
/// on disk, since clips saved from such a model need its sample rate later too. `ModelZoo` still
/// answers for every model it knows.
nonisolated struct RemoteModelTraits: Codable, Hashable, Sendable {
  var version: String
  var modifier: String
  var framesPerSecond: Double
  var audioSampleRate: Int

  /// This device's `ModelZoo`'s answers, as a server sends them.
  init(file: String) {
    version = ModelZoo.versionForModel(file).rawValue
    modifier = ModelZoo.modifierForModel(file).rawValue
    framesPerSecond = ModelZoo.framesPerSecondForModel(file)
    audioSampleRate = ModelZoo.audioSampleRateForModel(file)
  }

  init(version: String, modifier: String, framesPerSecond: Double, audioSampleRate: Int) {
    self.version = version
    self.modifier = modifier
    self.framesPerSecond = framesPerSecond
    self.audioSampleRate = audioSampleRate
  }

  private struct Table: Codable {
    var models: [String: RemoteModelTraits] = [:]
    var loras: [String: String] = [:]
  }

  private static var file: URL { RemotePaths.root.appending(path: "ModelTraits.json") }
  private static let table = Mutex<Table>(
    (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Table.self, from: $0) } ?? Table())

  /// Keeps what a server said about models this device's zoos don't know.
  static func remember(models: [String: RemoteModelTraits], loras: [String: String]) {
    let known = Set(ModelZoo.availableSpecifications.map(\.file))
    let knownLoRAs = Set(LoRAZoo.availableSpecifications.map(\.file))
    let data = table.withLock { table -> Data? in
      let before = (table.models, table.loras)
      table.models.merge(models.filter { !known.contains($0.key) }) { _, new in new }
      table.loras.merge(loras.filter { !knownLoRAs.contains($0.key) }) { _, new in new }
      return before == (table.models, table.loras) ? nil : try? JSONEncoder().encode(table)
    }
    if let data {
      Log.attempt(Log.remote, "Saving model traits") {
        try FileManager.default.createDirectory(at: RemotePaths.root, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
      }
    }
  }

  private static func traits(of file: String) -> RemoteModelTraits? {
    guard !ModelZoo.availableSpecifications.contains(where: { $0.file == file }) else { return nil }
    return table.withLock { $0.models[file] }
  }

  static func version(of file: String) -> ModelVersion {
    traits(of: file).flatMap { ModelVersion(rawValue: $0.version) } ?? ModelZoo.versionForModel(file)
  }

  static func modifier(of file: String) -> SamplerModifier {
    traits(of: file).flatMap { SamplerModifier(rawValue: $0.modifier) } ?? ModelZoo.modifierForModel(file)
  }

  static func modifier(ofLoRA file: String) -> SamplerModifier {
    if !LoRAZoo.availableSpecifications.contains(where: { $0.file == file }),
       let modifier = table.withLock({ $0.loras[file] }).flatMap(SamplerModifier.init(rawValue:))
    {
      return modifier
    }
    return LoRAZoo.modifierForModel(file)
  }

  /// The model's modifier, else its LoRAs': `ImageGeneratorUtils.modifierForModel`, with these.
  static func modifier(of file: String, loras: [String]) -> SamplerModifier {
    let modifier = modifier(of: file)
    guard modifier == .none else { return modifier }
    return loras.lazy.map(Self.modifier(ofLoRA:)).first { $0 != .none } ?? .none
  }

  static func framesPerSecond(of file: String) -> Double {
    traits(of: file)?.framesPerSecond ?? ModelZoo.framesPerSecondForModel(file)
  }

  static func audioSampleRate(of file: String) -> Int {
    traits(of: file)?.audioSampleRate ?? ModelZoo.audioSampleRateForModel(file)
  }
}
