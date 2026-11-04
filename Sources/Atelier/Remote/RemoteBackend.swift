@preconcurrency import _MediaGenerationKit
import CoreGraphics
import Foundation
@preconcurrency import ModelZoo
import Network
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
    _ request: GenerationEngine.Request, frames: [CGImage],
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output {
    try await upscale(request, frames: frames, sourceClip: nil, job: UUID(), progress: progress)
  }

  /// Upscales `frames`, or `sourceClip`, a clip the server made and still has (`hasClip`).
  func upscale(
    _ request: GenerationEngine.Request, frames: [CGImage], sourceClip: UUID?, job: UUID,
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output {
    let client = try paired()
    let updates = await client.startUpdates(job: job)
    defer { Task { await client.endUpdates(job: job) } }
    return try await withTaskCancellationHandler {
      var hashes: [String] = []
      for (index, frame) in frames.enumerated() {
        try Task.checkCancellation()
        let blob = try await Self.frameBlob(frame)
        try await uploadFrame(blob)
        hashes.append(blob.hash)
        progress(.state(.uploading(bytesSent: index + 1, totalBytes: frames.count)))
      }
      var settings = request.configuration
      settings.seed = request.seed
      var remote = RemoteJobRequest(
        model: request.model, prompt: request.prompt, negativePrompt: request.negativePrompt, seed: request.seed,
        settings: JSONValue.fields(of: settings))
      remote.upscale = request.upscale
      remote.frames = hashes
      remote.sourceClip = sourceClip
      _ = try await Self.retrying { try await client.request(.submitJob(jobID: job, request: remote)) }
      let ready = try await waitForResult(job: job, updates: updates, progress: progress)
      return try await collect(job: job, ready: ready, progress: progress)
    } onCancel: {
      Task { try? await client.request(.cancel(jobID: job)) }
    }
  }

  @concurrent private static func frameBlob(_ frame: CGImage) async throws -> RemoteBlob {
    guard let png = ImageTensor.png(frame) else { throw ProjectError.badImage }
    return RemoteBlob(png)
  }

  /// Sends one frame of an upscale, if the server doesn't have it.
  func uploadFrame(_ blob: RemoteBlob) async throws {
    let client = try paired()
    try await Self.retrying { try await client.upload(blob) { _ in } }
  }

  /// Whether the server still has a clip it made for this device.
  func hasClip(_ job: UUID) async -> Bool {
    guard let client, case .clipStatus(let has) = try? await client.request(.clipCheck(jobID: job)) else { return false }
    return has
  }

  func writeUpscaledVideo(
    of composition: TimelineComposition, to url: URL, codec: VideoCodec, upscale: TimelineUpscale,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    try await composition.writeUpscaledRemotely(to: url, codec: codec, upscale: upscale, on: self, progress: progress)
  }

  /// Upscales uploaded frames and downloads the result, for a caller that reads it frame by frame
  /// and then acknowledges it. `progress` runs from 0 to 1, as far as the server's steps say.
  func upscaledResult(
    frames: [String], upscale: TimelineUpscale, width: Int, height: Int, job: UUID,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    let client = try paired()
    let updates = await client.startUpdates(job: job)
    defer { Task { await client.endUpdates(job: job) } }
    return try await withTaskCancellationHandler {
      var remote = RemoteJobRequest(
        model: "", prompt: "", negativePrompt: "", seed: 0,
        settings: ["width": .number(Double(width)), "height": .number(Double(height))])
      remote.upscale = ClipUpscale(
        method: upscale.method, scale: upscale.scale, sourceTensorId: 0,
        variant: upscale.method == .flashVSR ? upscale.variant : nil)
      remote.frames = frames
      _ = try await Self.retrying { try await client.request(.submitJob(jobID: job, request: remote)) }
      let ready = try await waitForResult(job: job, updates: updates) { update in
        if case .state(.generating(let step, let total)) = update, total > 0 { progress(Double(step) / Double(total)) }
      }
      guard let size = ready.resultSize, let hash = ready.resultHash, let url = try await Self.retrying({ try await client.download(job: job, size: size, hash: hash) { _ in } }) else {
        throw RemoteError.corruptResult
      }
      return url
    } onCancel: {
      Task { try? await client.request(.cancel(jobID: job)) }
    }
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

  func catalog() async throws -> (models: [RemoteModelInfo], loras: [RemoteLoRAInfo], files: [String], upscalers: RemoteUpscalers) {
    guard case .catalog(let models, let loras, let files, let upscalers) = try await paired().request(.catalogRequest) else {
      throw RemoteError.connectionLost
    }
    // What the rest of the app asks of a model by file name has to know these.
    RemoteModelTraits.remember(
      models: models.reduce(into: [:]) { $0[$1.file] = $1.traits },
      loras: Dictionary(loras.map { ($0.file, $0.modifier) }) { first, _ in first })
    return (models, loras, files, upscalers)
  }

  // MARK: - A job's steps

  private struct Prepared: Sendable {
    var request: RemoteJobRequest
    var blobs: [RemoteBlob]
  }

  /// The request as it travels. Encoding images takes a while, so off the main actor.
  @concurrent private static func prepare(_ request: GenerationEngine.Request) async throws -> Prepared {
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

/// A server advertising itself on the local network.
nonisolated struct RemoteNearby: Hashable, Identifiable, Sendable {
  static let idKey = "id"
  static let hostKey = "host"
  static let portKey = "port"

  var id: UUID
  var name: String
  var address: RemoteAddress
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
  /// Servers Bonjour finds on the local network, paired or not.
  private(set) var nearby: [RemoteNearby] = []
  private var browser: NWBrowser?
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

  /// Those found nearby that this device isn't paired with.
  var unpairedNearby: [RemoteNearby] {
    nearby.filter { server in !servers.contains { $0.id == server.id } }
  }

  /// Starts looking for servers on the local network. On iPad this is what asks for Local Network
  /// access, so it waits until there's a reason: a paired server, or Add Server… being open.
  func startBrowsing() {
    guard browser == nil else { return }
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteProtocol.serviceType, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let found = results.compactMap(Self.nearby)
      Task { @MainActor in self?.update(nearby: found) }
    }
    browser.start(queue: .global())
    self.browser = browser
  }

  func stopBrowsing() {
    browser?.cancel()
    browser = nil
    update(nearby: [])
  }

  private nonisolated static func nearby(from result: NWBrowser.Result) -> RemoteNearby? {
    guard case .service(let name, _, _, _) = result.endpoint, case .bonjour(let record) = result.metadata,
          let id = record[RemoteNearby.idKey].flatMap(UUID.init(uuidString:)), let host = record[RemoteNearby.hostKey],
          let port = record[RemoteNearby.portKey].flatMap(UInt16.init), port != 0
    else { return nil }
    return RemoteNearby(id: id, name: name, address: RemoteAddress(host: host, port: port))
  }

  /// A paired server found nearby is online, and reached over the local network from now on. If
  /// its network filter turns that route away, the next status check says so.
  private func update(nearby found: [RemoteNearby]) {
    nearby = found
    loadIfNeeded()
    for server in servers {
      let here = found.first { $0.id == server.id }
      let client = backend(for: server.id).client
      Task { await client?.setNearby(here?.address) }
      if here != nil, statuses[server.id] != .online {
        statuses[server.id] = .online
        onServerOnline?(server.id)
      }
    }
  }

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
    if let here = nearby.first(where: { $0.id == id }) { Task { await client.setNearby(here.address) } }
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
