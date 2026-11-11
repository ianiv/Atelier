@preconcurrency import _MediaGenerationKit
import CoreGraphics
import Foundation
import Network
import Observation
import Synchronization

/// Which TLS identities may connect right now, asked during each handshake.
private final nonisolated class RemoteIdentityGate: Sendable {
  private struct State {
    var devices: Set<String> = []
    var isPairing = false
    var attempts = 0
    var lastAttempt: Date?
  }

  private let state = Mutex(State())
  /// Called when a code has been tried too many times.
  let onExhausted: @Sendable () -> Void

  init(onExhausted: @escaping @Sendable () -> Void) { self.onExhausted = onExhausted }

  func setDevices(_ devices: Set<String>) { state.withLock { $0.devices = devices } }

  func setPairing(_ isPairing: Bool) {
    state.withLock {
      $0.isPairing = isPairing
      $0.attempts = 0
      $0.lastAttempt = nil
    }
  }

  /// A paired device is always welcome. The pairing identity gets one attempt at a time, spaced
  /// out and only a few per code: a typed code is the weakest step, so it can't be hammered.
  func accepts(_ identity: String, now: Date = Date()) -> Bool {
    var exhausted = false
    let accepted = state.withLock { state -> Bool in
      guard identity == RemoteProtocol.pairIdentity else { return state.devices.contains(identity) }
      guard state.isPairing else { return false }
      if state.attempts >= RemotePairing.maxAttempts {
        exhausted = true
        return false
      }
      if let last = state.lastAttempt, now.timeIntervalSince(last) < RemotePairing.attemptSpacing { return false }
      state.attempts += 1
      state.lastAttempt = now
      return true
    }
    if exhausted { onExhausted() }
    return accepted
  }
}

/// The socket a server listens on.
///
/// A listener's keys are fixed when it starts. Network.framework's PSK selection block looks like
/// the place to pick a key per connection, but testing it on loopback (macOS 27, TLS 1.2) showed
/// otherwise:
/// - With no key added, the block never fires and the handshake fails (-9858).
/// - With keys added, it fires with the client's identity, but its completion takes an identity
///   rather than a key: handing back a key fails with -9864, unknown PSK identity.
/// - A key added to the options after the listener started isn't seen (-9864).
///
/// So the listener carries one key per paired device, plus the one-time pairing key while pairing
/// is open; the block only checks the identity; and `update` replaces the listener whenever the
/// keys change, after waiting for the old one to reach `.cancelled` (the port is "in use" until
/// then). Connections already open outlive their listener, so removing a device has to close its
/// connections itself, which `RemoteJobStore.removeDevice` does. A client that catches the moment
/// between two listeners gets a refused connection, and retries.
///
/// Beside it runs a second listener on a free loopback port with the same keys, the bridge: what
/// arrives from Atelier's own tailnet node comes in there, so it gets the same TLS-PSK as anything
/// else, and being on that port is what says it came over the tailnet. Only this device can reach
/// the port, and it still takes a paired device's key to get anywhere.
final nonisolated class RemoteListener: Sendable {
  struct Configuration: Sendable {
    /// 0 picks a free one, kept from then on.
    var port: UInt16
    var loopbackOnly: Bool
    var advertises: Bool
    var keys: [String: Data]
    /// What browsing clients read: this server's id and where to reach it.
    var serverID = UUID()
  }

  private struct State {
    var listener: NWListener?
    var filter = RemoteAddressFilter.tailscale
    var boundPort: UInt16 = 0
    var bridge: NWListener?
    var bridgePort: UInt16?
    /// The port asked for, to notice it changing rather than the keys.
    var requestedPort: UInt16?
  }

  private let queue = DispatchQueue(label: "Atelier.RemoteListener")
  private let state = Mutex(State())
  private let accepts: @Sendable (String) -> Bool
  private let onConnection: @Sendable (NWConnection) -> Void
  /// Told when a running listener fails, after it was ready.
  private let onFailure: @Sendable (String) -> Void

  init(
    accepts: @escaping @Sendable (String) -> Bool, onConnection: @escaping @Sendable (NWConnection) -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) {
    self.accepts = accepts
    self.onConnection = onConnection
    self.onFailure = onFailure
  }

  func setFilter(_ filter: RemoteAddressFilter) { state.withLock { $0.filter = filter } }

  /// Where the tailnet's connections go; nil while there's no listener.
  var bridgePort: UInt16? { state.withLock(\.bridgePort) }

  /// Listens with `configuration`, replacing a listener already running. Returns the port.
  func update(_ configuration: Configuration) async throws -> UInt16 {
    await stop()
    let port = state.withLock { state -> UInt16 in
      if state.requestedPort != configuration.port {
        state.requestedPort = configuration.port
        state.boundPort = 0
      }
      return state.boundPort != 0 ? state.boundPort : configuration.port
    }
    var lastError: Error = NWError.posix(.EADDRINUSE)
    // The old listener's port can take a moment longer to come free.
    for attempt in 0..<5 {
      if attempt > 0 { try await Task.sleep(for: .milliseconds(100 * attempt)) }
      do {
        let bound = try await start(configuration, port: port)
        state.withLock { $0.boundPort = bound }
        try await startBridge(configuration)
        return bound
      } catch let error as NWError {
        lastError = error
        guard case .posix(.EADDRINUSE) = error else { throw error }
      }
    }
    throw lastError
  }

  private func start(_ configuration: Configuration, port: UInt16) async throws -> UInt16 {
    let parameters = RemoteTLS.server(keys: configuration.keys, queue: queue, accepts: accepts)
    parameters.allowLocalEndpointReuse = true
    let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
    let listener: NWListener
    if configuration.loopbackOnly {
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
      listener = try NWListener(using: parameters)
    } else {
      listener = try NWListener(using: parameters, on: nwPort)
    }
    if configuration.advertises, Self.canAdvertise {
      let record = NWTXTRecord([
        RemoteNearby.idKey: configuration.serverID.uuidString, RemoteNearby.hostKey: RemoteNetworkInfo.localNetworkHost,
        RemoteNearby.portKey: String(port),
      ])
      listener.service = NWListener.Service(type: RemoteProtocol.serviceType, txtRecord: record.data)
    }
    // The peer's address is checked before the connection is started, so nothing, not even the
    // TLS handshake, happens for an address the filter turns away.
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return connection.cancel() }
      let filter = state.withLock(\.filter)
      guard filter.allows(connection.endpoint) else {
        Log.remote.info("Refused a connection from outside the allowed networks")
        return connection.cancel()
      }
      onConnection(connection)
    }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
      let answered = Mutex(false)
      let answer: @Sendable () -> Bool = {
        answered.withLock { value in
          defer { value = true }
          return !value
        }
      }
      listener.stateUpdateHandler = { [weak self] update in
        switch update {
        case .ready:
          if answer() { continuation.resume(returning: listener.port?.rawValue ?? port) }
        case .failed(let error), .waiting(let error):
          listener.cancel()
          if answer() {
            continuation.resume(throwing: error)
          } else {
            self?.onFailure(Self.describe(error))
          }
        default:
          break
        }
      }
      state.withLock { $0.listener = listener }
      listener.start(queue: queue)
    }
  }

  /// The bridge listener: loopback only, on a free port, and past the network filter.
  private func startBridge(_ configuration: Configuration) async throws {
    let parameters = RemoteTLS.server(keys: configuration.keys, queue: queue, accepts: accepts)
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return connection.cancel() }
      onConnection(connection)
    }
    let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
      let answered = Mutex(false)
      let answer: @Sendable () -> Bool = {
        answered.withLock { value in
          defer { value = true }
          return !value
        }
      }
      listener.stateUpdateHandler = { update in
        switch update {
        case .ready:
          if answer() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
        case .failed(let error), .waiting(let error):
          listener.cancel()
          if answer() { continuation.resume(throwing: error) }
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
    state.withLock {
      $0.bridge = listener
      $0.bridgePort = port
    }
  }

  /// Stops listening; returns once the port is free. Connections stay open.
  func stop() async {
    state.withLock {
      $0.bridge?.cancel()
      $0.bridge = nil
      $0.bridgePort = nil
    }
    guard let listener = state.withLock({ state -> NWListener? in
      defer { state.listener = nil }
      return state.listener
    }) else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let finished = Mutex(false)
      let finish: @Sendable () -> Void = {
        let isFirst = finished.withLock { value -> Bool in
          defer { value = true }
          return !value
        }
        if isFirst { continuation.resume() }
      }
      listener.stateUpdateHandler = { update in
        if case .cancelled = update { finish() }
      }
      listener.cancel()
      // A listener that already failed never reports `.cancelled`.
      queue.asyncAfter(deadline: .now() + 2) { finish() }
    }
  }

  /// Advertising needs NSBonjourServices on iPad, or the listener fails; that key comes with the
  /// client's browsing. The Mac needs nothing.
  private static var canAdvertise: Bool {
    #if os(macOS)
      true
    #else
      (Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])?.contains(RemoteProtocol.serviceType) ?? false
    #endif
  }

  static func describe(_ error: NWError) -> String {
    if case .posix(.EADDRINUSE) = error { return "Another app is using this port." }
    return error.localizedDescription
  }
}

/// The Compute role: lets paired devices run jobs here. A job goes into this machine's own Queue,
/// labelled with the device's name, and runs on the local backend like any other, one at a time;
/// its result waits under Application Support until the device has downloaded it. Off until turned
/// on in Settings ▸ Compute.
@MainActor
@Observable
final class RemoteServer {
  /// What differs in a scripted check, which leaves the user's pairings and files alone.
  struct Options {
    var store: any RemoteSecretStore = RemotePaths.defaultStore
    var root = RemotePaths.root
    /// Reads and saves settings, and starts by itself at launch if on.
    var isApp = SessionState.isEnabled
    var loopbackOnly = !SessionState.isEnabled
    var filter: RemoteAddressFilter? = SessionState.isEnabled ? nil : .any
    var port: UInt16? = SessionState.isEnabled ? nil : 0
    /// In place of the app's own node, for a check.
    var tailnet: RemoteTailnet?
  }

  struct Pairing: Equatable {
    var code: String
    var link: RemotePairingLink
    var expiresAt: Date
    /// The formatted code, as the server shows it.
    var displayCode: String { "\(code.prefix(5))-\(code.suffix(5))" }
  }

  private static let enabledKey = "remoteServer.enabled"
  private static let portKey = "remoteServer.port"
  private static let filterKey = "remoteServer.filter"

  var isEnabled: Bool {
    didSet {
      guard isEnabled != oldValue else { return }
      if options.isApp { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
      apply()
    }
  }

  var filter: RemoteAddressFilter {
    didSet {
      if options.isApp { UserDefaults.standard.set(filter.rawValue, forKey: Self.filterKey) }
      listener?.setFilter(filter)
    }
  }

  var port: UInt16 {
    didSet {
      guard port != oldValue else { return }
      if options.isApp { UserDefaults.standard.set(Int(port), forKey: Self.portKey) }
      apply()
    }
  }

  private(set) var devices: [RemotePairedDevice] = []
  private(set) var pairing: Pairing?
  private(set) var isListening = false
  private(set) var listenError: String?
  /// The port actually bound.
  private(set) var boundPort: UInt16 = 0
  private(set) var tailscaleAddress: String?
  private(set) var tailscaleName: String?

  private let options: Options
  private weak var create: CreateModel?
  private weak var library: ModelLibrary?
  let store: RemoteJobStore
  private var gate: RemoteIdentityGate?
  private var listener: RemoteListener?
  /// Listener changes run one after another, the latest wins.
  private var applying: Task<Void, Never>?
  private var pairingExpiry: Task<Void, Never>?
  private var purging: Task<Void, Never>?
  private var isLoaded = false
  private(set) var serverID = UUID()
  /// Devices' jobs in the queue, during which the machine doesn't go to sleep by itself: nothing
  /// could wake it again over the network.
  private var activeJobs = 0
  private var awake: (any NSObjectProtocol)?

  init(create: CreateModel, library: ModelLibrary?, options: Options = Options()) {
    self.create = create
    self.library = library
    self.options = options
    store = RemoteJobStore(root: options.root)
    let defaults = UserDefaults.standard
    isEnabled = options.isApp && defaults.bool(forKey: Self.enabledKey)
    filter = options.filter ?? defaults.string(forKey: Self.filterKey).flatMap(RemoteAddressFilter.init(rawValue:)) ?? .tailscale
    port = options.port ?? (defaults.object(forKey: Self.portKey) as? Int).flatMap { UInt16(exactly: $0) } ?? RemoteProtocol.defaultPort
    if isEnabled, !options.isApp || SessionState.isEnabled { apply() }
    tailnet?.onChange = { [weak self] in self?.syncTailnet() }
  }

  private var tailnet: RemoteTailnet? { options.tailnet ?? create?.tailnet }

  /// Whether the tailnet is what's being served on, and on which port. Starting a listener over
  /// this one drops nothing: connections outlive it.
  private var tailnetListening: UInt16?

  /// Serves over Tailscale while it's on, signed in and this server is listening.
  private func syncTailnet() {
    guard let tailnet else { return }
    let tailnetPort = port != 0 ? port : boundPort
    let shouldListen = isEnabled && isListening && tailnet.serves && tailnet.isSignedIn && tailnetPort != 0
    guard shouldListen != (tailnetListening != nil) || (shouldListen && tailnetListening != tailnetPort) else { return }
    tailnetListening = shouldListen ? tailnetPort : nil
    if shouldListen {
      let listener = listener
      tailnet.startListening(port: tailnetPort) { listener?.bridgePort }
    } else {
      tailnet.stopListening()
    }
  }

  /// Reads the saved keys, the first time they're needed: the Keychain may have to ask.
  func loadIfNeeded() {
    guard !isLoaded else { return }
    isLoaded = true
    devices = options.store.loadList(RemoteAccounts.pairedDevices)
    if let saved = options.store.load(RemoteAccounts.serverID).flatMap({ String(data: $0, encoding: .utf8) }).flatMap(UUID.init(uuidString:)) {
      serverID = saved
    } else {
      options.store.save(Data(serverID.uuidString.utf8), account: RemoteAccounts.serverID)
    }
  }

  private func saveDevices() { options.store.saveList(devices, account: RemoteAccounts.pairedDevices) }

  private var currentKeys: [String: Data] {
    var keys = Dictionary(uniqueKeysWithValues: devices.map { ($0.id.uuidString, $0.key) })
    if let pairing { keys[RemoteProtocol.pairIdentity] = RemotePairing.pairingKey(code: pairing.code) }
    return keys
  }

  /// Brings the listener in line with the settings, keys and pairing. Runs after any change still
  /// under way; wait on `applying` for it to have taken effect.
  private func apply() {
    loadIfNeeded()
    let previous = applying
    gate?.setDevices(Set(devices.map(\.id.uuidString)))
    let shouldListen = isEnabled
    if !shouldListen {
      closePairing()
      purging?.cancel()
      purging = nil
    } else if purging == nil {
      let store = store
      purging = Task {
        while !Task.isCancelled {
          await store.purge()
          try? await Task.sleep(for: .seconds(3600))
        }
      }
    }
    let listener = listener(creatingIfNeeded: shouldListen)
    let configuration = RemoteListener.Configuration(
      port: port, loopbackOnly: options.loopbackOnly, advertises: !options.loopbackOnly, keys: currentKeys,
      serverID: serverID)
    applying = Task { [weak self] in
      await previous?.value
      guard let listener else { return }
      if shouldListen {
        do {
          let bound = try await listener.update(configuration)
          self?.boundPort = bound
          self?.isListening = true
          self?.listenError = nil
          self?.syncTailnet()
        } catch {
          self?.isListening = false
          self?.listenError = (error as? NWError).map(RemoteListener.describe) ?? error.localizedDescription
        }
      } else {
        await listener.stop()
        self?.isListening = false
        self?.listenError = nil
        self?.syncTailnet()
      }
    }
  }

  private func listener(creatingIfNeeded create: Bool) -> RemoteListener? {
    if let listener { return listener }
    guard create else { return nil }
    let gate = RemoteIdentityGate { [weak self] in
      Task { @MainActor in self?.closePairing() }
    }
    gate.setDevices(Set(devices.map(\.id.uuidString)))
    let store = store
    let listener = RemoteListener(
      accepts: { gate.accepts($0) },
      onConnection: { [weak self] connection in
        guard let self else { return connection.cancel() }
        let session = RemoteSession(server: self, store: store, connection: RemoteConnection(connection))
        Task { await session.run() }
      },
      onFailure: { [weak self] message in
        Task { @MainActor in
          self?.isListening = false
          self?.listenError = message
        }
      })
    listener.setFilter(filter)
    self.gate = gate
    self.listener = listener
    return listener
  }

  // MARK: - Pairing

  /// Opens pairing for one device, for two minutes, replacing any code already showing.
  func startPairing() {
    guard isEnabled else { return }
    loadIfNeeded()
    var addresses = RemoteNetworkInfo.pairingAddresses(port: boundPort, tailscaleName: tailscaleName)
    if options.loopbackOnly { addresses = [RemoteAddress(host: "127.0.0.1", port: boundPort)] }
    // Atelier's own place on the tailnet comes first: it's the route that works from anywhere.
    if let tailnet, tailnet.serves {
      let tailnetPort = port != 0 ? port : boundPort
      addresses = tailnet.addresses.map { RemoteAddress(host: $0, port: tailnetPort) } + addresses
    }
    if addresses.isEmpty { addresses = [RemoteAddress(host: ProcessInfo.processInfo.hostName, port: boundPort)] }
    let code = RemotePairing.newCode()
    let lifetime = RemotePairing.codeLifetime
    pairing = Pairing(
      code: code, link: RemotePairingLink(addresses: addresses, serverID: serverID, secret: code),
      expiresAt: Date().addingTimeInterval(lifetime))
    _ = listener(creatingIfNeeded: true)
    gate?.setPairing(true)
    apply()
    pairingExpiry?.cancel()
    pairingExpiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(lifetime))
      guard !Task.isCancelled else { return }
      self?.closePairing()
    }
  }

  /// Ends pairing: the code stops working, and its key leaves the listener.
  func closePairing() {
    guard pairing != nil else { return }
    pairing = nil
    pairingExpiry?.cancel()
    pairingExpiry = nil
    gate?.setPairing(false)
    if isEnabled { apply() }
  }

  /// Waits for the listener to have caught up with the latest change.
  func settled() async { await applying?.value }

  /// Grants a pairing request, once the new device's key is on the listener: its next connection
  /// must find it there. Nil if the proof doesn't match the open code.
  func completePairing(deviceID: UUID, deviceName: String, proof: Data, publicKey: Data) async -> RemoteMessage? {
    guard let pairing, pairing.expiresAt > Date() else { return nil }
    let key = RemotePairing.pairingKey(code: pairing.code)
    guard RemotePairing.isValidProof(proof, key: key, deviceID: deviceID, purpose: "pair") else { return nil }
    let deviceKey = RemotePairing.newDeviceKey()
    guard let sealed = try? RemotePairing.seal(deviceKey: deviceKey, clientKey: publicKey, code: pairing.code) else { return nil }
    var device = RemotePairedDevice(
      id: deviceID, name: String(deviceName.prefix(RemoteProtocol.maxDeviceNameLength)), key: deviceKey,
      pairedAt: Date(), lastSeen: Date())
    if let existing = devices.firstIndex(where: { $0.id == deviceID }) {
      device.pairedAt = devices[existing].pairedAt
      devices[existing] = device
    } else {
      devices.append(device)
    }
    saveDevices()
    self.pairing = nil
    pairingExpiry?.cancel()
    pairingExpiry = nil
    gate?.setPairing(false)
    apply()
    await settled()
    return .pairGranted(
      serverID: serverID, serverName: RemoteNetworkInfo.deviceName, publicKey: sealed.publicKey, sealedKey: sealed.sealed)
  }

  /// Revokes a device at once: its key leaves the listener, its open connections close, and its
  /// jobs and files go.
  func remove(_ id: UUID) {
    devices.removeAll { $0.id == id }
    saveDevices()
    apply()
    let store = store
    Task {
      for queueID in await store.removeDevice(id) { self.create?.cancel(queueID) }
    }
  }

  /// A device's hello: the device if it's paired and holds its key.
  func authenticate(deviceID: UUID, deviceName: String, proof: Data) -> RemoteMessage {
    guard let index = devices.firstIndex(where: { $0.id == deviceID }),
          RemotePairing.isValidProof(proof, key: devices[index].key, deviceID: deviceID, purpose: "hello")
    else { return .refused("This device isn't paired with this server.") }
    let name = String(deviceName.prefix(RemoteProtocol.maxDeviceNameLength))
    if !name.isEmpty { devices[index].name = name }
    devices[index].lastSeen = Date()
    saveDevices()
    return .welcome(version: RemoteProtocol.version, serverID: serverID, serverName: RemoteNetworkInfo.deviceName)
  }

  /// Rereads this machine's Tailscale address and name for Settings and new pairing links.
  func refreshNetworkInfo() async {
    let address = RemoteNetworkInfo.tailscaleAddress()
    tailscaleAddress = address
    tailscaleName = if let address { await RemoteNetworkInfo.reverseName(of: address) } else { nil }
  }

  // MARK: - Serving

  func catalog() -> RemoteMessage {
    let models = (create?.models ?? []).map {
      RemoteModelInfo(file: $0.file, name: $0.name, version: $0.version, traits: RemoteModelTraits(file: $0.file))
    }
    let loras = (library?.loras ?? []).filter(\.isDownloaded).map {
      RemoteLoRAInfo(file: $0.file, name: $0.name, version: $0.version, prefix: $0.prefix, modifier: RemoteModelTraits.modifier(ofLoRA: $0.file).rawValue, weight: $0.weight)
    }
    let upscalers = RemoteUpscalers(
      flashVSR: FlashVSRFiles.Variant.allCases.filter { FlashVSRFiles.installed($0) != nil },
      superResolution: SystemSuperResolution.isSupported,
      recaVSR: ReCaVSRFiles.Weights.allCases.filter {
        ReCaVSRFiles.installed($0) != nil && ($0 == .eightBit || ClipUpscale.recaVSRFullAllowed)
      })
    return .catalog(
      models: models, loras: loras, files: create?.modelFiles ?? [], upscalers: upscalers,
      features: RemoteProtocol.features)
  }

  /// This device's styles library by library, with their thumbnails' hashes.
  func styleCatalog() -> RemoteMessage {
    guard let store = create?.styles else { return .styles([]) }
    return .styles(store.libraries.flatMap { library in
      library.styles.map { style in
        RemoteStyle(
          style: style, thumbnailHash: store.thumbnailJPEG(style.id).map { RemoteBlob($0).hash },
          thumbnailModel: store.thumbnailModel(style.id), libraryID: library.id, libraryName: library.name)
      }
    })
  }

  func styleThumbnail(_ id: UUID) -> RemoteMessage {
    .styleThumbnail(create?.styles?.thumbnailJPEG(id))
  }

  func styleSource(_ id: UUID) -> RemoteMessage {
    guard let found = create?.styles?.thumbnailSource(id), let png = ImageTensor.png(found.image) else {
      return .styleSource(nil, image: nil)
    }
    return .styleSource(found.source, image: png)
  }

  private func defaults(for model: String) async throws -> PipelineConfiguration {
    guard let create, create.models.contains(where: { $0.file == model }) else {
      throw RemoteError.server("This server doesn't have \(model).")
    }
    let configuration = try await create.backend(for: .local).loadPipeline(for: model)
    return ModelDefaults.recommended(for: model, configuration: configuration)
  }

  func modelDefaults(_ model: String) async throws -> RemoteMessage {
    .modelDefaults(settings: JSONValue.fields(of: try await defaults(for: model)))
  }

  /// Takes a device's registered job into this machine's queue (`RemoteJobStore.registerJob`).
  func submit(job: UUID, request: RemoteJobRequest, device: UUID) async throws {
    let store = store
    do {
      guard let name = devices.first(where: { $0.id == device })?.name, let create else {
        throw RemoteError.server("This device isn't paired with this server.")
      }
      // Upscaling reads only the size and seed, and its model may be one this server never had.
      var configuration = request.upscale != nil
        ? try await RemoteBackend.blankConfiguration(for: request.model)
        : try await defaults(for: request.model)
      SettingsRegistry.apply(dump: request.settings, to: &configuration)
      let inputs = try await Self.inputs(of: request, device: device, store: store)
      // Cancelled while the model's settings loaded.
      if await store.latestEvent(of: job, device: device)?.state.isFinal ?? true { return }
      var engineRequest = GenerationEngine.Request(
        model: request.model, prompt: request.prompt, negativePrompt: request.negativePrompt,
        seed: request.seed, configuration: configuration)
      engineRequest.canvas = inputs.canvas
      engineRequest.canvasIsImported = request.canvasIsImported
      engineRequest.mask = inputs.mask
      engineRequest.moodboard = inputs.moodboard
      engineRequest.audio = inputs.audio
      engineRequest.upscale = request.upscale
      let queueID = create.runForDevice(
        engineRequest, frames: inputs.frames, device: name,
        progress: { [weak self] progress in self?.note(progress, job: job) },
        completion: { [weak self] result in self?.finish(job, result) })
      await store.setQueueID(queueID, job: job)
      activeJobs += 1
      if awake == nil {
        awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Running a paired device's job")
      }
    } catch {
      await store.post(RemoteJobEvent(jobID: job, state: .failed, message: error.localizedDescription))
      throw error
    }
  }

  private struct Inputs: Sendable {
    var canvas: CGImage?
    var mask: Data?
    var moodboard: [GenerationEngine.Reference] = []
    var audio: URL?
    var frames: [CGImage] = []
  }

  /// A job's images and audio, from its uploads. The audio gets a copy the queue owns, as a job
  /// queued on this machine does (`AudioClip.snapshot`).
  @concurrent private static func inputs(
    of request: RemoteJobRequest, device: UUID, store: RemoteJobStore
  ) async throws -> Inputs {
    func image(_ hash: String) async throws -> CGImage {
      guard let url = await store.blobURL(device: device, hash: hash), let image = ImageLoader.image(at: url) else {
        throw RemoteError.server("An image for this job wasn't uploaded.")
      }
      return image
    }
    var inputs = Inputs()
    if let canvas = request.canvas { inputs.canvas = try await image(canvas) }
    // The mask goes to the engine as the PNG it is: decoding it here could change its codes.
    if let mask = request.mask {
      guard let url = await store.blobURL(device: device, hash: mask), let data = try? Data(contentsOf: url) else {
        throw RemoteError.server("The mask for this job wasn't uploaded.")
      }
      inputs.mask = data
    }
    for reference in request.moodboard {
      inputs.moodboard.append(GenerationEngine.Reference(image: try await image(reference.hash), weight: reference.weight))
    }
    if let audio = request.audio {
      guard let url = await store.blobURL(device: device, hash: audio.hash),
            audio.fileExtension.count <= 8, audio.fileExtension.allSatisfy({ $0.isLetter || $0.isNumber })
      else { throw RemoteError.server("The audio for this job wasn't uploaded.") }
      let copy = await AudioClip.newSnapshotFile(extension: audio.fileExtension)
      try FileManager.default.copyItem(at: url, to: copy)
      inputs.audio = copy
    }
    if let clip = request.sourceClip {
      guard let url = await store.clip(device: device, job: clip) else {
        throw RemoteError.server("This server no longer has that clip.")
      }
      let reader = try RemoteResultFile.Reader(url: url)
      let count = min(request.upscale?.frameLimit ?? reader.frameCount, reader.frameCount)
      for index in 0..<count {
        guard let image = ImageTensor.cgImage(from: try reader.frame(index)) else { throw RemoteError.corruptResult }
        inputs.frames.append(image)
      }
    } else {
      for hash in request.frames { inputs.frames.append(try await image(hash)) }
    }
    return inputs
  }

  /// Passes a run's progress to its device. Images are encoded off the main actor.
  private func note(_ progress: GenerationEngine.Progress, job: UUID) {
    let store = store
    switch progress {
    case .state(let state):
      guard let event = Self.event(for: state, job: job) else { return }
      Task { await store.post(event) }
    case .preview(let image, let step, let total):
      Task { await store.post(await Self.previewEvent([image], step: step, total: total, job: job)) }
    case .previewFrames(let images, let step, let total):
      Task { await store.post(await Self.previewEvent(images, step: step, total: total, job: job)) }
    }
  }

  @concurrent private static func previewEvent(
    _ images: [CGImage], step: Int, total: Int, job: UUID
  ) async -> RemoteJobEvent {
    RemoteJobEvent(
      jobID: job, state: .generating, step: step, totalSteps: total,
      previews: images.compactMap { ImageTensor.jpeg($0, quality: 0.7).map { Data($0) } })
  }

  nonisolated static func event(for state: MediaGenerationPipeline.State, job: UUID) -> RemoteJobEvent? {
    let remote: RemoteJobState
    switch state {
    case .resolvingBackend, .resolvingModel, .preparing, .ensuringResources, .uploading, .downloading: remote = .preparing
    case .encodingText: remote = .encodingText
    case .encodingInputs: remote = .encodingInputs
    case .generating(let step, let total):
      return RemoteJobEvent(jobID: job, state: .generating, step: step, totalSteps: total)
    case .decoding: remote = .decoding
    case .postprocessing: remote = .postprocessing
    case .cancelling: remote = .cancelling
    case .completed, .cancelled: return nil
    }
    return RemoteJobEvent(jobID: job, state: remote)
  }

  private func finish(_ job: UUID, _ result: Result<GenerationEngine.Output, Error>) {
    activeJobs -= 1
    if activeJobs == 0, let awake {
      ProcessInfo.processInfo.endActivity(awake)
      self.awake = nil
    }
    let store = store
    Task {
      switch result {
      case .success(let output):
        await store.post(RemoteJobEvent(jobID: job, state: .packing))
        guard let url = await store.resultDestination(job) else { return }
        do {
          let (size, hash) = try await RemoteResultFile.write(output, to: url)
          await store.post(RemoteJobEvent(jobID: job, state: .ready, resultSize: size, resultHash: hash, resultIsClip: output.isVideo))
        } catch {
          await store.post(RemoteJobEvent(jobID: job, state: .failed, message: error.localizedDescription))
        }
      case .failure(let error):
        if error is CancellationError {
          await store.post(RemoteJobEvent(jobID: job, state: .cancelled))
        } else {
          await store.post(RemoteJobEvent(jobID: job, state: .failed, message: error.localizedDescription))
        }
      }
    }
  }

  /// Stops a device's own job, whether it's waiting or running.
  func cancel(job: UUID, device: UUID) async {
    let store = store
    guard let event = await store.latestEvent(of: job, device: device), !event.state.isFinal else { return }
    if let queueID = await store.queueID(of: job, device: device) {
      await store.post(RemoteJobEvent(jobID: job, state: .cancelling))
      create?.cancel(queueID)
    } else {
      // Not in the queue yet: `submit` sees this and doesn't add it.
      await store.post(RemoteJobEvent(jobID: job, state: .cancelled))
    }
  }
}

/// One accepted connection: identifies the device, then answers its requests.
nonisolated struct RemoteSession: Sendable {
  let server: RemoteServer
  let store: RemoteJobStore
  let connection: RemoteConnection
  private let id = UUID()

  private func reply(_ requestID: UUID?, _ message: RemoteMessage) {
    connection.sendNow(.message(RemoteEnvelope(requestID: requestID, message: message)))
  }

  @concurrent func run() async {
    connection.startAccepted()
    // A connection that says nothing doesn't stay.
    let connection = connection
    let timeout = Task {
      try await Task.sleep(for: .seconds(15))
      connection.cancel()
    }
    defer { connection.cancel() }
    do {
      guard case .message(let first) = try await connection.receive() else { return }
      timeout.cancel()
      switch first.message {
      case .pairRequest(let version, let deviceID, let deviceName, let proof, let publicKey):
        guard version == RemoteProtocol.version else {
          return reply(first.requestID, .refused(RemoteError.versionMismatch.errorDescription ?? ""))
        }
        let answer = await server.completePairing(deviceID: deviceID, deviceName: deviceName, proof: proof, publicKey: publicKey)
        reply(first.requestID, answer ?? .refused(RemoteError.wrongCode.errorDescription ?? ""))
        // Let the answer leave before the connection closes.
        _ = try? await connection.receive()
      case .hello(let version, let deviceID, let deviceName, let proof):
        guard version == RemoteProtocol.version else {
          return reply(first.requestID, .refused(RemoteError.versionMismatch.errorDescription ?? ""))
        }
        let answer = await server.authenticate(deviceID: deviceID, deviceName: deviceName, proof: proof)
        reply(first.requestID, answer)
        guard case .welcome = answer else { return }
        await store.addListener(id, device: deviceID, connection: connection)
        await serve(device: deviceID)
        await store.removeListener(id)
      default:
        return
      }
    } catch {
      timeout.cancel()
    }
  }

  private func serve(device: UUID) async {
    while let frame = try? await connection.receive() {
      switch frame {
      case .chunk(let header, let bytes):
        guard header.kind == .upload else { continue }
        do {
          let offset = try await store.appendBlob(device: device, hash: header.id, offset: header.offset, total: header.total, bytes: bytes)
          reply(header.requestID, .blobAck(hash: header.id, offset: offset))
        } catch {
          reply(header.requestID, .failure(error.localizedDescription))
        }
      case .message(let envelope):
        await handle(envelope, device: device)
      }
    }
  }

  private func handle(_ envelope: RemoteEnvelope, device: UUID) async {
    let requestID = envelope.requestID
    switch envelope.message {
    case .catalogRequest:
      reply(requestID, await server.catalog())
    case .stylesRequest:
      reply(requestID, await server.styleCatalog())
    case .styleThumbnailRequest(let id):
      reply(requestID, await server.styleThumbnail(id))
    case .styleSourceRequest(let id):
      reply(requestID, await server.styleSource(id))
    case .modelDefaultsRequest(let model):
      // Loading a model's settings can take a while: other requests go on meanwhile.
      Task {
        do {
          reply(requestID, try await server.modelDefaults(model))
        } catch {
          reply(requestID, .failure(error.localizedDescription))
        }
      }
    case .clipCheck(let job):
      reply(requestID, .clipStatus(await store.clip(device: device, job: job) != nil))
    case .blobCheck(let hashes):
      let status = await store.blobStatus(device: device, hashes: hashes)
      reply(requestID, .blobStatus(complete: status.complete, partial: status.partial))
    case .submitJob(let job, let request):
      // Registered before the next message is read, so a cancel right behind it finds the job.
      do {
        guard try await store.registerJob(job, device: device) else {
          return reply(requestID, .jobAccepted(jobID: job))
        }
      } catch {
        return reply(requestID, .failure(error.localizedDescription))
      }
      Task {
        do {
          try await server.submit(job: job, request: request, device: device)
          reply(requestID, .jobAccepted(jobID: job))
        } catch {
          reply(requestID, .failure(error.localizedDescription))
        }
      }
    case .subscribe(let job):
      if let event = await store.latestEvent(of: job, device: device) {
        reply(requestID, .jobEvent(event))
      } else {
        reply(requestID, .failure("There's no such job."))
      }
    case .listJobs:
      reply(requestID, .jobs(await store.events(device: device)))
    case .cancel(let job):
      await server.cancel(job: job, device: device)
      reply(requestID, .ok)
    case .resultRequest(let job, let offset, let length):
      guard let requestID else { return }
      do {
        let (bytes, total) = try await store.readResult(device: device, job: job, offset: offset, length: length)
        connection.sendNow(.chunk(RemoteChunkHeader(requestID: requestID, kind: .result, id: job.uuidString, offset: offset, total: total), bytes))
      } catch {
        reply(requestID, .failure(error.localizedDescription))
      }
    case .ackResult(let job):
      await store.acknowledge(job: job, device: device)
      reply(requestID, .ok)
    default:
      reply(requestID, .failure("Unexpected message."))
    }
  }
}
