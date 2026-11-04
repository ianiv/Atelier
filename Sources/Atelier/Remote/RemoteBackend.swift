@preconcurrency import _MediaGenerationKit
import CoreGraphics
import Foundation
@preconcurrency import ModelZoo
import Observation

/// A paired server as a `GenerationBackend`: sends a job, streams its progress into the same
/// callbacks a local run uses, and brings the result back. If the connection drops the job carries
/// on at the server, and this reconnects and picks up where it was.
nonisolated struct RemoteBackend: GenerationBackend {
  /// Nil for a server that isn't paired anymore: every call says so.
  let client: RemoteClient?

  /// How long to keep trying to reach a server whose job is under way.
  private static let reconnectWindow: TimeInterval = 30 * 60

  private func paired() throws -> RemoteClient {
    guard let client else { throw RemoteError.unknownServer }
    return client
  }

  /// Runs `body`, again after a dropped connection, with backoff, until `reconnectWindow` is up.
  /// Anything else that goes wrong (the server said no, the key's refused) ends it.
  private static func retrying<T>(_ body: () async throws -> T) async throws -> T {
    let deadline = Date().addingTimeInterval(reconnectWindow)
    var delay = 0.5
    while true {
      do {
        return try await body()
      } catch let error as RemoteError where error == .connectionLost || isUnreachable(error) {
        guard Date() < deadline else { throw error }
        try await Task.sleep(for: .seconds(delay))
        delay = min(delay * 2, 15)
      }
    }
  }

  private static func isUnreachable(_ error: RemoteError) -> Bool {
    if case .unreachable = error { return true }
    return false
  }

  // MARK: - GenerationBackend

  func generate(
    _ request: GenerationEngine.Request, progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output {
    try await generate(request, job: UUID(), acknowledges: true, progress: progress)
  }

  /// Runs `request` as `job`. With `acknowledges` false the server keeps its copy of the result
  /// until `acknowledge`, for a caller that first has to save it somewhere safe.
  func generate(
    _ request: GenerationEngine.Request, job: UUID, acknowledges: Bool,
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output {
    let client = try paired()
    let updates = await client.startUpdates(job: job)
    defer { Task { await client.endUpdates(job: job) } }
    return try await withTaskCancellationHandler {
      try await submit(request, job: job, progress: progress)
      let ready = try await waitForResult(job: job, updates: updates, progress: progress)
      return try await collect(job: job, ready: ready, acknowledges: acknowledges, progress: progress)
    } onCancel: {
      // Goes out on its own: this task is what's being cancelled.
      Task { try? await client.request(.cancel(jobID: job)) }
    }
  }

  /// Picks up a job submitted before this launch: follows it if it's still running, and collects
  /// its result. A job the server no longer has fails, saying so.
  func resume(
    job: UUID, progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output {
    let client = try paired()
    let updates = await client.startUpdates(job: job)
    defer { Task { await client.endUpdates(job: job) } }
    return try await withTaskCancellationHandler {
      var ready: RemoteJobEvent
      do {
        ready = try await Self.retrying { try await client.latest(job: job) }
      } catch RemoteError.server {
        throw RemoteError.server("The server no longer has this job.")
      }
      switch ready.state {
      case .ready: break
      case .failed: throw RemoteError.server(ready.message ?? "The job failed on the server.")
      case .cancelled: throw CancellationError()
      default: ready = try await waitForResult(job: job, updates: updates, progress: progress)
      }
      return try await collect(job: job, ready: ready, acknowledges: false, progress: progress)
    } onCancel: {
      Task { try? await client.request(.cancel(jobID: job)) }
    }
  }

  /// Tells the server it can delete a result, and drops the downloaded copy.
  func acknowledge(job: UUID) async {
    guard let client else { return }
    _ = try? await client.request(.ackResult(jobID: job))
    await client.removeDownload(job: job)
  }

  func upscale(
    _: GenerationEngine.Request, frames _: [CGImage], progress _: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output {
    throw RemoteError.unsupported("Upscaling")
  }

  /// The model's defaults at the server, on a blank configuration from `blankConfiguration`.
  func loadPipeline(for model: String) async throws -> PipelineConfiguration {
    guard case .modelDefaults(let settings) = try await Self.retrying({ try await paired().request(.modelDefaultsRequest(model: model)) })
    else { throw RemoteError.connectionLost }
    return await Self.applied(settings, to: try await Self.blankConfiguration(for: model))
  }

  @MainActor private static func applied(
    _ settings: [String: JSONValue], to configuration: PipelineConfiguration
  ) -> PipelineConfiguration {
    var configuration = configuration
    SettingsRegistry.apply(dump: settings, to: &configuration)
    return configuration
  }

  /// A configuration to put a server's values on. MGK's `Configuration` has no public initializer
  /// and comes only from a pipeline, and a pipeline for MGK's remote backend connects as it's made.
  /// A local one needs no files, only a model it can name, so for a model only the server knows
  /// this uses the first in the built-in list. Its `model` field then names that one, which nothing
  /// reads: a job's model is `Request.model`.
  static func blankConfiguration(for model: String) async throws -> PipelineConfiguration {
    if let pipeline = try? await MediaGenerationPipeline.fromPretrained(model, backend: .local) {
      return PipelineConfiguration(pipeline.configuration)
    }
    guard let known = ModelZoo.availableSpecifications.first?.file else { throw RemoteError.unknownServer }
    return PipelineConfiguration(try await MediaGenerationPipeline.fromPretrained(known, backend: .local).configuration)
  }

  func downloadedModels() async -> [MediaGenerationResolvedModel] {
    guard let catalog = try? await catalog() else { return [] }
    return catalog.models.map {
      MediaGenerationResolvedModel(file: $0.file, name: $0.name, description: "", version: $0.version, isDownloaded: true)
    }
  }

  func catalog() async throws -> (models: [RemoteModelInfo], loras: [RemoteLoRAInfo], files: [String]) {
    guard case .catalog(let models, let loras, let files) = try await paired().request(.catalogRequest) else {
      throw RemoteError.connectionLost
    }
    return (models, loras, files)
  }

  // MARK: - A job's steps

  private struct Prepared: Sendable {
    var request: RemoteJobRequest
    var blobs: [RemoteBlob]
  }

  /// The request as it travels. Encoding images takes a while, so off the main actor.
  @concurrent private static func prepare(_ request: GenerationEngine.Request) async throws -> Prepared {
    guard request.upscale == nil else { throw RemoteError.unsupported("Upscaling") }
    var settings = request.configuration
    settings.seed = request.seed
    var remote = RemoteJobRequest(
      model: request.model, prompt: request.prompt, negativePrompt: request.negativePrompt, seed: request.seed,
      settings: JSONValue.fields(of: settings))
    var blobs: [RemoteBlob] = []
    if let canvas = request.canvas {
      guard let png = ImageTensor.png(canvas) else { throw ProjectError.badImage }
      let blob = RemoteBlob(png)
      blobs.append(blob)
      remote.canvas = blob.hash
      remote.canvasIsImported = request.canvasIsImported
    }
    for reference in request.moodboard {
      guard let png = ImageTensor.png(reference.image) else { throw ProjectError.badImage }
      let blob = RemoteBlob(png)
      blobs.append(blob)
      remote.moodboard.append(RemoteJobRequest.Reference(hash: blob.hash, weight: reference.weight))
    }
    if let audio = request.audio {
      let access = audio.startAccessingSecurityScopedResource()
      defer { if access { audio.stopAccessingSecurityScopedResource() } }
      let blob = RemoteBlob(try Data(contentsOf: audio, options: .mappedIfSafe))
      blobs.append(blob)
      remote.audio = RemoteJobRequest.Audio(hash: blob.hash, fileExtension: audio.pathExtension)
    }
    return Prepared(request: remote, blobs: blobs)
  }

  /// Uploads a job's inputs and submits it under the id `job`. Safe to repeat after a drop: the
  /// server keeps what it has, and takes a job once.
  func submit(
    _ request: GenerationEngine.Request, job: UUID,
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws {
    let client = try paired()
    let prepared = try await Self.prepare(request)
    let total = prepared.blobs.reduce(0) { $0 + $1.data.count }
    var done = 0
    for blob in prepared.blobs {
      let before = done
      try await Self.retrying {
        try await client.upload(blob) { sent in
          progress(.state(.uploading(bytesSent: before + sent, totalBytes: total)))
        }
      }
      done += blob.data.count
    }
    _ = try await Self.retrying { try await client.request(.submitJob(jobID: job, request: prepared.request)) }
  }

  /// Follows the job to its end. Returns its `ready` event; failed and cancelled jobs throw.
  func waitForResult(
    job: UUID, updates: AsyncStream<RemoteClient.Update>,
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> RemoteJobEvent {
    let client = try paired()
    for await update in updates {
      let event: RemoteJobEvent
      switch update {
      case .event(let received): event = received
      case .lost: event = try await Self.retrying { try await client.latest(job: job) }
      }
      Self.report(event, to: progress)
      switch event.state {
      case .ready: return event
      case .failed: throw RemoteError.server(event.message ?? "The job failed on the server.")
      case .cancelled: throw CancellationError()
      default: break
      }
    }
    // The stream ends early only when this task is cancelled.
    try Task.checkCancellation()
    throw RemoteError.connectionLost
  }

  /// Downloads a finished job's result and tells the server to delete its copy.
  func collect(
    job: UUID, ready: RemoteJobEvent, acknowledges: Bool = true,
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output {
    let client = try paired()
    guard let size = ready.resultSize, let hash = ready.resultHash else { throw RemoteError.corruptResult }
    let received: @Sendable (Int) -> Void = { progress(.state(.downloading(bytesReceived: $0, totalBytes: size))) }
    let downloaded = try await Self.retrying {
      try await client.download(job: job, size: size, hash: hash, received: received)
    }
    guard let downloaded else { throw RemoteError.corruptResult }
    let output = try await RemoteResultFile.read(downloaded)
    if acknowledges { await acknowledge(job: job) }
    return output
  }

  private static func report(_ event: RemoteJobEvent, to progress: (GenerationEngine.Progress) -> Void) {
    switch event.state {
    case .queued, .preparing: progress(.state(.preparing))
    case .encodingText: progress(.state(.encodingText))
    case .encodingInputs: progress(.state(.encodingInputs))
    case .generating:
      let step = event.step ?? 0
      let total = event.totalSteps ?? 0
      let images = (event.previews ?? []).compactMap { ImageLoader.image(from: $0) }
      if images.count > 1 {
        progress(.previewFrames(images, step: step, totalSteps: total))
      } else if let image = images.first {
        progress(.preview(image, step: step, totalSteps: total))
      } else {
        progress(.state(.generating(step: step, totalSteps: total)))
      }
    case .decoding, .packing: progress(.state(.decoding))
    case .postprocessing: progress(.state(.postprocessing))
    case .cancelling: progress(.state(.cancelling))
    case .ready, .failed, .cancelled: break
    }
  }
}

/// The servers this device is paired with. The Keychain isn't touched until they're asked for,
/// since it may have to ask you.
@MainActor
@Observable
final class RemoteServerList {
  enum Status: Equatable {
    case unknown, online, offline
  }

  private(set) var servers: [RemoteServerRecord] = []
  private(set) var statuses: [UUID: Status] = [:]
  /// A link opened from outside (a scanned QR code), waiting for you to confirm pairing with it.
  var openedLink: RemotePairingLink?
  /// Told when a server is seen to come online.
  @ObservationIgnored var onServerOnline: ((UUID) -> Void)?

  private let store: any RemoteSecretStore
  private let downloads: URL
  private let fixedIdentity: RemoteDeviceIdentity?
  private var isLoaded = false
  private var clients: [UUID: RemoteClient] = [:]

  init(
    store: any RemoteSecretStore = RemotePaths.defaultStore,
    downloads: URL = RemotePaths.root.appending(path: "Downloads", directoryHint: .isDirectory),
    identity: RemoteDeviceIdentity? = nil
  ) {
    self.store = store
    self.downloads = downloads
    fixedIdentity = identity
  }

  private var identity: RemoteDeviceIdentity { fixedIdentity ?? .current }

  func loadIfNeeded() {
    guard !isLoaded else { return }
    isLoaded = true
    servers = store.loadList(RemoteAccounts.servers)
  }

  func name(of id: UUID) -> String? {
    loadIfNeeded()
    return servers.first { $0.id == id }?.name
  }

  func status(of id: UUID) -> Status { statuses[id] ?? .unknown }

  /// Asks every server whether it's there.
  func checkStatus() async {
    loadIfNeeded()
    for server in servers {
      let reachable = await backend(for: server.id).client?.isReachable() ?? false
      guard servers.contains(where: { $0.id == server.id }) else { continue }
      let wasOnline = statuses[server.id] == .online
      statuses[server.id] = reachable ? .online : .offline
      if reachable, !wasOnline { onServerOnline?(server.id) }
    }
  }

  /// The backend for a paired server; for one that isn't, one whose calls say so.
  func backend(for id: UUID) -> RemoteBackend {
    loadIfNeeded()
    if let client = clients[id] { return RemoteBackend(client: client) }
    guard let server = servers.first(where: { $0.id == id }) else { return RemoteBackend(client: nil) }
    let client = RemoteClient(server: server, device: identity, downloads: downloads)
    clients[id] = client
    return RemoteBackend(client: client)
  }

  func pair(link: RemotePairingLink) async throws {
    try await add(RemoteClient.pair(
      addresses: link.addresses, code: link.secret, expectedServerID: link.serverID, device: identity))
  }

  /// `Add Server…` without a link: a host and the code the server shows.
  func pair(host: String, code: String) async throws {
    guard let address = RemoteAddress(host), let code = RemotePairing.normalizedCode(code) else {
      throw RemoteError.invalidPairingLink
    }
    try await add(RemoteClient.pair(addresses: [address], code: code, expectedServerID: nil, device: identity))
  }

  private func add(_ server: RemoteServerRecord) {
    loadIfNeeded()
    servers.removeAll { $0.id == server.id }
    servers.append(server)
    store.saveList(servers, account: RemoteAccounts.servers)
    forgetClient(server.id)
    statuses[server.id] = .online
    onServerOnline?(server.id)
  }

  /// A server on the list without pairing, for the screenshots and checks of scripted runs.
  func addForCheck(_ server: RemoteServerRecord) { add(server) }

  /// Forgets a server here. Its list of devices is its own: Remove there revokes this one.
  func remove(_ id: UUID) {
    servers.removeAll { $0.id == id }
    store.saveList(servers, account: RemoteAccounts.servers)
    statuses[id] = nil
    forgetClient(id)
  }

  private func forgetClient(_ id: UUID) {
    if let client = clients.removeValue(forKey: id) { Task { await client.disconnect() } }
  }
}
