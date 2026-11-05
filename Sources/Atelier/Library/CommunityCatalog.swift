@preconcurrency import _MediaGenerationKit
import Foundation
@preconcurrency import ModelZoo

/// The community model list when MGK couldn't get it. `ModelZooLoader.specifications(from: .remote)`
/// stores an empty list when its one fetch fails and never tries again, and its cache is private,
/// so a failed fetch at launch hid every community model until a relaunch, whatever Refresh did.
/// Here a listing that came back without community models fetches the same file again, and what
/// it gets joins `ModelZoo.availableSpecifications`, which MGK lists as its built-in source.
@MainActor
enum CommunityCatalog {
  private static let url = URL(string: "https://models.drawthings.ai/models.json")!

  /// The list, once a fetch here has worked.
  private static var fetched: [ModelZoo.Specification]?
  /// What `ModelLibrary.loadCustomSpecifications(in:)` adds: empty unless MGK's fetch failed.
  private(set) static var fallback: [ModelZoo.Specification] = []
  /// Counts the times `fallback` was filled, so a caller can tell the listing just changed.
  private(set) static var generation = 0

  /// Every catalog model, as MGK lists them, with the community models even if MGK's fetch failed.
  static func models() async -> [MediaGenerationResolvedModel] {
    let environment = MediaGenerationEnvironment.default
    let models = await environment.downloadableModels(includeDownloaded: true, offline: false)
    let offline = await environment.downloadableModels(includeDownloaded: true, offline: true)
    // More online than offline: MGK's fetch worked, or a fallback is already in the list.
    guard models.count <= offline.count, fallback.isEmpty, let specifications = await specifications() else {
      return models
    }
    fallback = specifications
    generation += 1
    let known = Set(ModelZoo.availableSpecifications.map(\.file))
    let added = specifications.filter { !known.contains($0.file) }
    ModelZoo.availableSpecifications += added
    ModelZoo.fallbackMapping.merge(added.map { ($0.file, $0) }) { first, _ in first }
    return await environment.downloadableModels(includeDownloaded: true, offline: false)
  }

  /// The community list, fetching it if no fetch has worked yet; nil if this one failed too.
  static func specifications() async -> [ModelZoo.Specification]? {
    if let fetched { return fetched }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let status = (response as? HTTPURLResponse)?.statusCode, 200...299 ~= status
    else { return nil }
    let specifications = parse(data)
    guard !specifications.isEmpty else { return nil }
    fetched = specifications
    return specifications
  }

  /// Decodes models.json as `ModelZooLoader.parse` does. Failable entries: one that a newer catalog
  /// writes in a way this engine can't read shouldn't cost the rest.
  nonisolated static func parse(_ data: Data) -> [ModelZoo.Specification] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let entries = try? decoder.decode([FailableDecodable<ModelZoo.Specification>].self, from: data)
    else { return [] }
    return entries.compactMap(\.value).filter { $0.remoteApiModelConfig == nil }
  }
}
