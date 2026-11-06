@preconcurrency import _MediaGenerationKit
import Foundation
@preconcurrency import ModelZoo

/// The community model list when MGK couldn't get it. `ModelZooLoader.specifications(from: .remote)`
/// stores an empty list when its one fetch fails and never tries again, and its cache is private,
/// so a failed fetch at launch hid every community model until a relaunch, whatever Refresh did,
/// and on a network that can't reach the server, for good. Here a listing that came back without
/// community models fetches the same file again, falling back to the copy shipped with the app
/// (community-models.json), and the result joins `ModelZoo.availableSpecifications`, which MGK
/// lists as its built-in source. A later fetch that works replaces the shipped copy.
///
/// To refresh the copy before a release:
///   curl -fsS https://models.drawthings.ai/models.json -o Sources/Atelier/Library/community-models.json
@MainActor
enum CommunityCatalog {
  private static let url = URL(string: "https://models.drawthings.ai/models.json")!

  /// The list, once a fetch here has worked. Never the shipped copy.
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
    // More online than offline: MGK's fetch worked, or the list is already in. The shipped copy
    // doesn't stop retries: `fetched` is what ends them.
    guard models.count <= offline.count, fetched == nil else { return models }
    if let specifications = await specifications() {
      install(specifications)
    } else if fallback.isEmpty {
      install(shipped)
    } else {
      return models
    }
    return await environment.downloadableModels(includeDownloaded: true, offline: false)
  }

  private static func install(_ specifications: [ModelZoo.Specification]) {
    fallback = specifications
    generation += 1
    let known = Set(ModelZoo.availableSpecifications.map(\.file))
    let added = specifications.filter { !known.contains($0.file) }
    ModelZoo.availableSpecifications += added
    ModelZoo.fallbackMapping.merge(added.map { ($0.file, $0) }) { first, _ in first }
  }

  /// The copy shipped with the app, so that a network that can't reach the server still gets the
  /// list, if not the newest models on it.
  static let shipped: [ModelZoo.Specification] = {
    guard let url = Bundle.main.url(forResource: "community-models", withExtension: "json"),
          let data = try? Data(contentsOf: url)
    else { return [] }
    return parse(data)
  }()

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
