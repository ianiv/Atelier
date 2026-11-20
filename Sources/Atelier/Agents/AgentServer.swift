#if os(macOS)
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Atelier's MCP server: agents such as Claude Code connect over Streamable HTTP on the loopback
/// interface (`http://127.0.0.1:<port>/mcp`) and generate with the app's own engine, so there's
/// never a second engine competing for the GPU. Off until turned on in Settings → Agents.
///
/// With Access set to Local network it also answers other devices on the local network or
/// tailnet (`AgentAccess.networkFilter`), which send a bearer token unless Require Token is off
/// and can't pass or get file paths (`AgentPathGuard`). In plain HTTP, unless Encryption picks a
/// certificate: then the port answers this Mac only and other devices use HTTPS, with an imported
/// certificate on the HTTPS Port (by default two past the server's), or at the embedded Tailscale
/// node's name with Tailscale's (`AgentEncryption`). Its ports are checked against Compute's
/// (`PortClaims`), which the operating system wouldn't catch.
///
/// Requests are JSON-RPC over POST. A `tools/call` whose client accepts an event stream gets one,
/// with progress notifications while it generates; anything else gets a plain JSON response.
/// There are no sessions and no server-to-client requests, so GET (the optional standalone
/// stream) is refused with 405, as the transport allows.
@MainActor
@Observable
final class AgentServer {
  static let defaultPort = 7862
  private static let enabledKey = "agentServer.enabled"
  private static let portKey = "agentServer.port"
  private static let accessKey = "agentServer.access"
  private static let requireTokenKey = "agentServer.requireToken"
  private static let encryptionKey = "agentServer.encryption"
  private static let httpsPortKey = "agentServer.httpsPort"

  var isEnabled: Bool {
    didSet {
      defaults.set(isEnabled, forKey: Self.enabledKey)
      restart()
    }
  }

  var port: Int {
    didSet {
      guard port != oldValue else { return }
      defaults.set(port, forKey: Self.portKey)
      restart()
    }
  }

  /// Settings → Agents → Access. The listener is replaced, as for the port.
  var access: AgentAccess {
    didSet {
      guard access != oldValue else { return }
      defaults.set(access.rawValue, forKey: Self.accessKey)
      restart()
    }
  }

  /// Settings → Agents → Encryption. Changes which listeners there are, so they're replaced.
  var encryption: AgentEncryption {
    didSet {
      guard encryption != oldValue else { return }
      defaults.set(encryption.rawValue, forKey: Self.encryptionKey)
      restart()
    }
  }

  /// Settings → Agents → Encryption → HTTPS Port, for an imported certificate: nil is Automatic
  /// (`PortClaims.automaticHTTPSPort`). Set through `chooseHTTPSPort`, which refuses a clash.
  private(set) var explicitHTTPSPort: Int? {
    didSet {
      guard explicitHTTPSPort != oldValue else { return }
      if let explicitHTTPSPort { defaults.set(explicitHTTPSPort, forKey: Self.httpsPortKey) } else { defaults.removeObject(forKey: Self.httpsPortKey) }
      if encryption == .certificate { restartHTTPS() }
    }
  }

  /// Whether other devices must send the token. Checked per request, so changing it needs no
  /// restart.
  var requireToken: Bool {
    didSet {
      defaults.set(requireToken, forKey: Self.requireTokenKey)
      if requireToken, activeAccess == .localNetwork { ensureToken() }
      syncGate()
    }
  }

  /// The token other devices send; nil until it's first needed. Compared with each request, so a
  /// new one takes effect at once.
  private(set) var token: String? {
    didSet { syncGate() }
  }
  /// The addresses other devices use, refreshed when the listener starts and Settings opens.
  private(set) var networkEndpoints: [String] = []

  /// Why the server isn't listening although it's on.
  private(set) var listenError: String?
  /// `listenError` is about the port (in use, not allowed, another server's): Try Again is on.
  private(set) var listenPortError = false
  /// Why the Port field didn't take the port typed, which is kept as it was.
  private(set) var portRefusal: String?
  private(set) var isListening = false

  /// The imported certificate, read from the Keychain the first time it's needed.
  private(set) var certificate: AgentTLSIdentity?
  /// The certificate Tailscale issued, and the name it's for.
  private(set) var tailscaleCertificate: AgentTLSIdentity?
  private var tailscaleCertificateName: String?
  /// The embedded Tailscale node's name, while it's signed in.
  private(set) var tailnetName: String?
  /// Where other devices reach HTTPS, once it's listening.
  private(set) var httpsEndpoint: String?
  /// Why HTTPS isn't listening although Encryption asks for it.
  private(set) var httpsError: String?
  /// `httpsError` is about the port: Try Again is on.
  private(set) var httpsPortError = false
  /// Why the HTTPS Port field didn't take the port typed.
  private(set) var httpsPortRefusal: String?
  /// Fetching Tailscale's certificate, which the first time can take a minute.
  private(set) var isFetchingCertificate = false
  /// Why the last daily renewal of Tailscale's certificate failed; the current one keeps serving.
  private(set) var renewalError: String?

  /// Something to fix before HTTPS stops working: the certificate is due within 14 days (Tailscale
  /// renews at that point, so it means renewals are failing), or the last renewal failed.
  var certificateWarning: String? {
    guard usesHTTPS, let certificate = activeCertificate else { return nil }
    if let renewalError, encryption == .tailscale { return "Renewing the certificate failed: \(renewalError)" }
    guard let expires = certificate.expires, expires < Date().addingTimeInterval(14 * 24 * 3600) else { return nil }
    return expires < Date()
      ? "The certificate has expired."
      : "The certificate expires \(expires.formatted(.relative(presentation: .named)))."
  }
  let tools: AgentTools
  /// `--mcp` on the command line: on for this launch without changing the setting.
  private let forcedOn: Bool
  /// `--mcp PORT`: that port for this launch.
  private var forcedPort: Int?
  /// `--mcp-network`: on the local network for this launch.
  private let forcedNetwork: Bool
  private let defaults: UserDefaults
  private let tokens: AgentTokenStore
  private let certificates: AgentCertificateStore
  private var certificateLoaded = false
  /// A scripted check's own certificate, in place of the imported one.
  private let certificateOverride: AgentTLSIdentity?
  private weak var tailnet: RemoteTailnet?
  /// The node's state and name last seen, to notice it signing in or out or being renamed.
  private var tailnetWasRunning = false
  private var tailnetLastName: String?
  @ObservationIgnored private var tailnetObserver: UUID?
  /// The ports Atelier's servers hold, shared with Compute's.
  private let ports: PortRegistry
  @ObservationIgnored private var portsObserver: UUID?
  /// Compute's port last seen, for automatic HTTPS to move off it.
  @ObservationIgnored private var computePortSeen: Int?

  private var server: LoopbackHTTPServer?
  /// The HTTPS listener: on every interface (imported certificate), or the tailnet's bridge.
  private var secureServer: LoopbackHTTPServer?
  /// Whether the tailnet's 443 is being passed to `secureServer`.
  private var servesTailnet = false
  /// Bumped by every HTTPS restart, so a certificate fetch that finishes late changes nothing.
  private var httpsGeneration = 0
  /// Fetches Tailscale's certificate again once a day: Tailscale renews it when it's due.
  private var certificateRefresh: Task<Void, Never>?
  /// What the listener checks before reading a request's body.
  @ObservationIgnored private let gate = AgentGateBox()
  /// Running tool calls by JSON-RPC id, so `notifications/cancelled` can stop them.
  private var calls: [String: Task<Void, Never>] = [:]

  private var activePort: Int { forcedPort ?? port }
  var activeAccess: AgentAccess { forcedNetwork ? .localNetwork : access }
  var endpoint: String { AgentAuth.endpoint(host: "127.0.0.1", port: activePort) }
  /// Whether a client on another device has to send the token now.
  var networkNeedsToken: Bool { activeAccess == .localNetwork && requireToken }
  /// What HTTPS is set to: the tailnet's 443 with Tailscale's certificate, else the HTTPS Port.
  private var httpsSetting: PortClaims.HTTPSPort {
    encryption == .tailscale ? .tailnet : explicitHTTPSPort.map { .explicit($0) } ?? .automatic
  }
  /// The local network's HTTPS port with an imported certificate: the HTTPS Port, or by default
  /// two past the server's, kept off Compute's while that's on.
  var httpsPort: Int? { ports.claims.httpsPort(explicitHTTPSPort.map { .explicit($0) } ?? .automatic, plainPort: activePort) }
  /// Whether other devices get HTTPS (and the server's own port answers this Mac only).
  var usesHTTPS: Bool { activeAccess == .localNetwork && encryption != .none }
  /// The certificate Encryption picks.
  var activeCertificate: AgentTLSIdentity? {
    switch encryption {
    case .none: nil
    case .tailscale: tailscaleCertificate
    case .certificate: certificateOverride ?? certificate
    }
  }

  private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
  private static let instructions = """
    Atelier generates images on this Mac with local diffusion models (the Draw Things engine). \
    Call list_models first to pick a model, then generate. Images are saved to the user's \
    current Atelier project and written as PNG files; one image is generated at a time, so a \
    call may wait for a run already in progress. Larger models can take minutes per image. \
    To work on the same Create screen as the user, read it with get_create_screen, change its \
    prompt and settings with set_create_screen, and generate it with generate and \
    use_app_settings (no prompt). To see an image, including ones the user generated, use \
    get_image (the canvas by default) and list_history. For videos and other long runs, call \
    generate with background: true and check on the job_id with get_job, which waits up to \
    wait_seconds per call. \
    To redo part of an image (a small face, a hand), work zoomed in: on the canvas, \
    set_canvas_image, then find_faces or get_image to locate it, set_canvas_mask or auto_mask \
    and grow_canvas_mask to mask it, set_canvas_frame to zoom the frame onto it at a scale, \
    and generate with use_app_settings and use_canvas, which merges the result back into the \
    whole image. With a model that takes reference images (list_models), set_canvas_paint can \
    fill the mask with a flat color the prompt names and set_moodboard can add the picture to \
    take from (get_moodboard gives its Picture number). edit_image does the whole of that in \
    one call, as a job that leaves the Create screen exactly as the user has it: use it when \
    they are working there, or for a batch. After an edit, match_colors takes out a color \
    shift; after one made with paint, pass original_history_step (the source) and \
    unchanged_only true. To finish an image without a model (film grain, a grade, a LUT, \
    matching a reference photo's colors and grain), use edit_image_look, with \
    list_grain_profiles and measure_reference. Coordinates are always the image's own pixels from its top left.
    """

  /// `defaults` and `secrets` are where the settings, token and certificate are kept: the user's,
  /// or a scratch suite and memory for a scripted check's own server (`commandLine` false: no
  /// `--mcp` flags, and it starts whenever it's on), which can bring its own `certificate`.
  init(
    create: CreateModel, presets: PresetStore, grainProfiles: GrainProfileStore? = nil, defaults: UserDefaults = .standard, secrets: (any RemoteSecretStore)? = nil,
    certificate: AgentTLSIdentity? = nil, commandLine: Bool = true
  ) {
    tools = AgentTools(create: create, presets: presets, grainProfiles: grainProfiles)
    self.defaults = defaults
    // A scripted run never touches the user's Keychain.
    let secrets = secrets ?? (Automation.isRequested ? MemorySecretStore() : KeychainSecretStore(service: "Atelier Agents"))
    tokens = AgentTokenStore(secrets: secrets)
    certificates = AgentCertificateStore(secrets: secrets)
    certificateOverride = certificate
    tailnet = create.tailnet
    ports = create.ports
    explicitHTTPSPort = defaults.object(forKey: Self.httpsPortKey) as? Int
    encryption = defaults.string(forKey: Self.encryptionKey).flatMap(AgentEncryption.init(rawValue:)) ?? .none
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    port = defaults.object(forKey: Self.portKey) as? Int ?? Self.defaultPort
    access = defaults.string(forKey: Self.accessKey).flatMap(AgentAccess.init(rawValue:)) ?? .thisMac
    requireToken = defaults.object(forKey: Self.requireTokenKey) as? Bool ?? true
    let args = commandLine ? CommandLine.arguments : []
    forcedNetwork = args.contains("--mcp-network")
    forcedOn = args.contains("--mcp") || forcedNetwork
    if let index = args.firstIndex(of: "--mcp"), index + 1 < args.count, let port = Int(args[index + 1]) {
      forcedPort = port
    }
    // Read from the Keychain only when it's in use; `ensureToken` reads it otherwise.
    if activeAccess == .localNetwork { token = tokens.load() }
    // Scripted checks leave the user's server (and its port) alone unless asked with `--mcp`.
    if commandLine, Automation.isRequested, !forcedOn { return }
    tailnetWasRunning = tailnet?.isSignedIn ?? false
    tailnetLastName = tailnet?.status.dnsName
    tailnetObserver = tailnet?.observe { [weak self] in self?.tailnetChanged() }
    computePortSeen = ports.claims.compute
    portsObserver = ports.observe { [weak self] in self?.portsChanged() }
    restart()
  }

  private func syncGate() {
    let current = AgentAuth.Gate(networkOpen: activeAccess == .localNetwork, requireToken: requireToken, token: token)
    gate.state.withLock { $0 = current }
  }

  /// The token, made now if there isn't one yet.
  @discardableResult func ensureToken() -> String {
    if let token { return token }
    let made = tokens.ensure()
    token = made
    return made
  }

  /// A new token; clients with the old one get 401 from their next request.
  func regenerateToken() {
    token = tokens.regenerate()
  }

  /// This Mac's addresses as other devices reach it: the local network address, the .local name
  /// and the Tailscale address; in HTTPS, those on the HTTPS port, or the Tailscale node's name.
  func refreshEndpoints() {
    tailnetName = tailnet?.isSignedIn == true ? tailnet?.status.dnsName : nil
    if usesHTTPS, encryption == .tailscale {
      networkEndpoints = tailnetName.map { [AgentAuth.endpoint(scheme: "https", host: $0, port: AgentAuth.tailnetHTTPSPort)] } ?? []
      return
    }
    let interfaces = RemoteNetworkInfo.interfaces()
    var hosts = [RemoteNetworkInfo.localNetworkHost]
    let hostName = ProcessInfo.processInfo.hostName
    if hostName.hasSuffix(".local") { hosts.append(hostName) }
    if let tailscale = RemoteNetworkInfo.tailscaleAddress(in: interfaces) { hosts.append(tailscale) }
    var seen = Set<String>()
    hosts = hosts.filter { seen.insert($0).inserted }
    if usesHTTPS {
      guard let port = httpsPort else { return networkEndpoints = [] }
      networkEndpoints = hosts.map { AgentAuth.endpoint(scheme: "https", host: $0, port: port) }
    } else {
      networkEndpoints = hosts.map { AgentAuth.endpoint(host: $0, port: activePort) }
    }
  }

  // MARK: - Certificates

  /// The imported certificate, read from the Keychain the first time.
  func loadCertificateIfNeeded() {
    guard !certificateLoaded else { return }
    certificateLoaded = true
    certificate = certificates.load()
  }

  /// Keeps a .p12 (checked first with its password) and serves HTTPS with it if that's picked.
  func importCertificate(_ data: Data, password: String) throws {
    certificate = try certificates.save(pkcs12: data, password: password)
    certificateLoaded = true
    if encryption == .certificate { restartHTTPS() }
  }

  func removeCertificate() {
    certificates.remove()
    certificate = nil
    certificateLoaded = true
    if encryption == .certificate { restartHTTPS() }
  }

  /// Fetches Tailscale's certificate again now (Settings' Renew), as the daily refresh does.
  func refreshTailscaleCertificate() {
    restartHTTPS(refetch: true)
  }

  isolated deinit {
    if let tailnetObserver { tailnet?.removeObserver(tailnetObserver) }
    if let portsObserver { ports.removeObserver(portsObserver) }
    stopHTTPS()
    server?.stop()
    ports.update { $0.claimMCP(isOn: false, port: 0) }
  }

  /// Compute took another port or turned on or off: automatic HTTPS moves to stay off it, as it
  /// would have started there. An explicit port stays (Compute's field refuses it).
  private func portsChanged() {
    let compute = ports.claims.compute
    guard compute != computePortSeen else { return }
    computePortSeen = compute
    guard isEnabled || forcedOn, usesHTTPS, encryption == .certificate, explicitHTTPSPort == nil, ports.claims.mcpHTTPS != httpsPort else { return }
    restartHTTPS()
  }

  // MARK: - Ports

  /// The Port field: takes `newPort` unless another of Atelier's servers holds it (or it's this
  /// server's own HTTPS Port), in which case the port stays and `portRefusal` says why.
  @discardableResult func choosePort(_ newPort: Int) -> Bool {
    var refusal = ports.claims.conflict(port: newPort, for: .mcp)
    if refusal == nil, explicitHTTPSPort == newPort {
      refusal = PortClaims.message(port: newPort, of: .mcpHTTPS)
    }
    portRefusal = refusal
    guard refusal == nil else { return false }
    port = newPort
    return true
  }

  /// The HTTPS Port field: nil for Automatic. Refuses a port Compute or the server's own plain port
  /// holds, as `choosePort` does.
  @discardableResult func chooseHTTPSPort(_ newPort: Int?) -> Bool {
    if let newPort {
      var refusal = ports.claims.conflict(port: newPort, for: .mcpHTTPS)
      if refusal == nil, newPort == activePort { refusal = PortClaims.message(port: newPort, of: .mcp) }
      httpsPortRefusal = refusal
      guard refusal == nil else { return false }
    }
    httpsPortRefusal = nil
    explicitHTTPSPort = newPort
    return true
  }

  /// Try Again in the server's Status, once whatever held the port has let it go.
  func retryListening() {
    portRefusal = nil
    startPlain()
  }

  /// Try Again in Encryption's Status.
  func retryHTTPS() {
    httpsPortRefusal = nil
    restartHTTPS()
  }

  /// The node signed in or out, or its name came or changed: HTTPS on the tailnet follows it,
  /// with a certificate for the new name.
  private func tailnetChanged() {
    let running = tailnet?.isSignedIn ?? false
    let name = running ? tailnet?.status.dnsName : nil
    guard running != tailnetWasRunning || name != tailnetLastName else { return }
    tailnetWasRunning = running
    tailnetLastName = name
    guard usesHTTPS, encryption == .tailscale, isEnabled || forcedOn else { return }
    // Already serving a certificate for this name: nothing to redo.
    if running, name != nil, name == tailscaleCertificateName, httpsEndpoint != nil { return }
    restartHTTPS()
  }

  // MARK: - Listening

  private func restart() {
    stopHTTPS()
    syncGate()
    startPlain()
    if isEnabled || forcedOn, usesHTTPS { restartHTTPS() }
  }

  /// Replaces the plain listener, leaving HTTPS alone.
  private func startPlain() {
    server?.stop()
    server = nil
    isListening = false
    listenError = nil
    listenPortError = false
    ports.update { $0.claimMCP(isOn: false, port: activePort) }
    guard isEnabled || forcedOn else { return }
    guard let port = UInt16(exactly: activePort), port > 0 else {
      listenError = PortClaims.invalidMessage
      return
    }
    let network = activeAccess == .localNetwork
    if network {
      if requireToken { ensureToken() }
      refreshEndpoints()
    }
    // Compute already has it (turned on while this server was off): the system would let both
    // listen, so it's refused here.
    if let clash = ports.claims.conflict(port: activePort, for: .mcp) {
      listenError = clash
      listenPortError = true
      Log.agents.error("MCP server not started: \(clash, privacy: .public)")
      return
    }
    ports.update { $0.claimMCP(isOn: true, port: activePort) }
    // With HTTPS, other devices never get plain HTTP: the port answers this Mac only.
    let server = makeServer(
      port: port, binding: network && !usesHTTPS ? .all(AgentAccess.networkFilter) : .loopback, tls: nil,
      originPort: activePort)
    self.server = server
    server.start { [weak self] failure in
      Task { @MainActor in
        guard let self, self.server === server else { return }
        self.isListening = failure == nil
        self.listenError = failure?.message
        self.listenPortError = failure?.isPortError ?? false
        if let failure {
          Log.agents.error("MCP server on port \(port, privacy: .public) failed: \(failure.message, privacy: .public)")
        } else {
          Log.agents.info("MCP server listening on \(self.endpoint, privacy: .public)")
        }
      }
    }
  }

  /// A listener for this server's requests. `originPort` is the port clients name, which a page's
  /// Origin must match: the listener's own, or the tailnet's 443 for the bridge.
  private func makeServer(
    port: UInt16, binding: LoopbackHTTPServer.Binding, tls: AgentTLSIdentity?, originPort: Int
  ) -> LoopbackHTTPServer {
    let gate = gate
    return LoopbackHTTPServer(
      port: port, binding: binding, tls: tls,
      headCheck: { peer, headers in
        AgentAuth.earlyRefusal(peer: peer, authorization: headers["authorization"], gate: gate.state.withLock { $0 })
      }
    ) { [weak self] request, responder in
      Task { @MainActor in self?.handle(request, responder, originPort: originPort) }
    }
  }

  private func stopHTTPS() {
    httpsGeneration += 1
    secureServer?.stop()
    secureServer = nil
    if servesTailnet {
      tailnet?.stopListening(port: UInt16(AgentAuth.tailnetHTTPSPort), owner: .agents)
      servesTailnet = false
    }
    certificateRefresh?.cancel()
    certificateRefresh = nil
    httpsEndpoint = nil
    httpsError = nil
    httpsPortError = false
    isFetchingCertificate = false
    ports.update { $0.claimMCPHTTPS(isOn: false, nil, plainPort: 0) }
  }

  /// Replaces the HTTPS listener (its certificate is fixed when it starts), leaving this Mac's
  /// plain port alone. `refetch` asks Tailscale for its certificate even if there's one already.
  private func restartHTTPS(refetch: Bool = false) {
    stopHTTPS()
    guard isEnabled || forcedOn, usesHTTPS else { return }
    refreshEndpoints()
    // Claimed from here on, whether or not there's a certificate yet, so Compute can't take it.
    let setting = httpsSetting
    if let port = ports.claims.httpsPort(setting, plainPort: activePort), let clash = ports.claims.conflict(port: port, for: .mcpHTTPS) {
      httpsError = clash
      httpsPortError = true
      Log.agents.error("MCP HTTPS not started: \(clash, privacy: .public)")
      return
    }
    ports.update { $0.claimMCPHTTPS(isOn: true, setting, plainPort: activePort) }
    switch encryption {
    case .none:
      return
    case .certificate:
      if certificateOverride == nil { loadCertificateIfNeeded() }
      guard let identity = activeCertificate else {
        httpsError = "Import a certificate to use HTTPS."
        return
      }
      guard let port = httpsPort else {
        httpsError = "No port is free for HTTPS past the server's; pick a lower port."
        return
      }
      let secure = makeServer(port: UInt16(port), binding: .all(AgentAccess.networkFilter), tls: identity, originPort: port)
      startSecure(secure, endpoint: AgentAuth.endpoint(scheme: "https", host: RemoteNetworkInfo.localNetworkHost, port: port))
    case .tailscale:
      guard let tailnet else { return }
      if case .unavailable = tailnet.state {
        httpsError = RemoteTailnet.CertificateError.unavailable.localizedDescription
        return
      }
      guard tailnet.isSignedIn else {
        httpsError = RemoteTailnet.CertificateError.notRunning.localizedDescription
        return
      }
      // Signed in, but MagicDNS gives it no name to get a certificate for.
      guard let name = tailnet.status.dnsName else {
        httpsError = RemoteTailnet.CertificateError.noName.localizedDescription
        return
      }
      let generation = httpsGeneration
      if !refetch, let identity = tailscaleCertificate, tailscaleCertificateName == name {
        serveTailnet(identity, name: name)
      } else {
        isFetchingCertificate = true
        Task { [weak self] in await self?.fetchTailscaleCertificate(generation: generation) }
      }
      certificateRefresh = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(24 * 3600))
          guard !Task.isCancelled, let self else { return }
          await self.fetchTailscaleCertificate(generation: self.httpsGeneration, renewing: true)
        }
      }
    }
  }

  /// Asks Tailscale for the node's certificate, then serves it. On a daily renewal (`renewing`),
  /// the listener is only replaced if the certificate changed.
  private func fetchTailscaleCertificate(generation: Int, renewing: Bool = false) async {
    guard let tailnet else { return }
    do {
      let (name, pem) = try await tailnet.certificatePair()
      let identity = try AgentTLSIdentity(pem: pem)
      guard generation == httpsGeneration else { return }
      isFetchingCertificate = false
      let changed = tailscaleCertificate?.fingerprint != identity.fingerprint
      tailscaleCertificate = identity
      tailscaleCertificateName = name
      renewalError = nil
      if renewing {
        if changed { restartHTTPS() }
      } else {
        serveTailnet(identity, name: name)
      }
    } catch {
      guard generation == httpsGeneration else { return }
      isFetchingCertificate = false
      Log.agents.error("Tailscale certificate: \(error.localizedDescription, privacy: .public)")
      // A renewal that fails leaves the current certificate serving until it's due.
      if renewing { renewalError = error.localizedDescription } else { httpsError = error.localizedDescription }
    }
  }

  /// HTTPS on the tailnet: Tailscale's 443 handed to a loopback TLS listener.
  private func serveTailnet(_ identity: AgentTLSIdentity, name: String) {
    let secure = makeServer(port: 0, binding: .tailnetBridge, tls: identity, originPort: AgentAuth.tailnetHTTPSPort)
    startSecure(secure, endpoint: AgentAuth.endpoint(scheme: "https", host: name, port: AgentAuth.tailnetHTTPSPort)) { [weak self] in
      guard let self, let tailnet = self.tailnet else { return }
      do {
        try tailnet.startListening(port: UInt16(AgentAuth.tailnetHTTPSPort), owner: .agents) { [weak secure] in secure?.boundPort }
        self.servesTailnet = true
      } catch {
        self.httpsError = error.localizedDescription
        // Tailscale not running isn't the port's fault; Try Again can't help.
        switch error as? RemoteTailnet.ListenError {
        case .taken, .failed: self.httpsPortError = true
        case .notRunning, nil: self.httpsPortError = false
        }
        self.httpsEndpoint = nil
      }
    }
  }

  private func startSecure(_ secure: LoopbackHTTPServer, endpoint: String, onReady: (@MainActor @Sendable () -> Void)? = nil) {
    secureServer = secure
    secure.start { [weak self] failure in
      Task { @MainActor in
        guard let self, self.secureServer === secure else { return }
        self.httpsError = failure?.message
        self.httpsPortError = failure?.isPortError ?? false
        self.httpsEndpoint = failure == nil ? endpoint : nil
        if let failure {
          Log.agents.error("MCP HTTPS failed: \(failure.message, privacy: .public)")
        } else {
          onReady?()
          Log.agents.info("MCP server HTTPS at \(endpoint, privacy: .public)")
        }
      }
    }
  }

  // MARK: - HTTP

  private func handle(_ request: LoopbackHTTPServer.Request, _ responder: LoopbackHTTPServer.Responder, originPort: Int) {
    let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
    guard path == "/mcp" || path == "/mcp/" else {
      return responder.send(status: 404, body: Data())
    }
    // On the loopback binding every peer is, and the listener only lets in allowed networks.
    let isRemote = !AgentAuth.isLoopback(request.peer)
    // A connection the old wildcard listener took just before Access went back to This Mac only.
    if isRemote, activeAccess != .localNetwork {
      return responder.send(status: 403, body: Data())
    }
    if isRemote {
      // Other devices reach this Mac by whatever name or address, so the Host header says
      // nothing; a page from another site must still not drive the server from a browser.
      let own = AgentAuth.ownHosts(
        addresses: RemoteNetworkInfo.interfaces().map(\.address), hostName: ProcessInfo.processInfo.hostName,
        tailnetName: tailnetName)
      guard AgentAuth.allowsRemote(origin: request.headers["origin"], ownHosts: own, port: originPort) else {
        return responder.send(status: 403, body: Data())
      }
    } else {
      // Only pages and clients on this Mac: a web page elsewhere could otherwise reach the
      // loopback port through DNS rebinding.
      guard AgentAuth.isLoopback(host: request.headers["host"]),
        request.headers["origin"].map({ AgentAuth.isLoopback(origin: $0) }) ?? true
      else {
        return responder.send(status: 403, body: Data())
      }
    }
    guard
      AgentAuth.isAuthorized(
        peerIsLoopback: !isRemote, requireToken: networkNeedsToken, authorization: request.headers["authorization"], token: token)
    else {
      return responder.send(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: Data())
    }
    guard request.method == "POST" else {
      return responder.send(status: 405, headers: ["Allow": "POST"], body: Data())
    }
    guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
      return respond(error: -32700, "Expected one JSON-RPC message.", id: NSNull(), via: responder)
    }
    guard let id = message["id"], let method = message["method"] as? String else {
      // A notification, or a response (the server sends no requests, so it's ignored).
      if message["method"] as? String == "notifications/cancelled",
        let params = message["params"] as? [String: Any], let id = params["requestId"]
      {
        calls[Self.key(id)]?.cancel()
      }
      return responder.send(status: 202, body: Data())
    }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
      let requested = params["protocolVersion"] as? String ?? ""
      respond(
        result: [
          "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": [
            "name": "atelier", "title": "Atelier",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
          ],
          "instructions": Self.instructions,
        ], id: id, via: responder)
    case "ping":
      respond(result: [:], id: id, via: responder)
    case "tools/list":
      respond(result: ["tools": AgentTools.definitions], id: id, via: responder)
    case "tools/call":
      callTool(
        params, id: id, streaming: request.headers["accept"]?.contains("text/event-stream") == true,
        context: ToolContext(isRemote: isRemote), via: responder)
    default:
      respond(error: -32601, "Method not found: \(method)", id: id, via: responder)
    }
  }

  private func callTool(
    _ params: [String: Any], id: Any, streaming: Bool, context: ToolContext, via responder: LoopbackHTTPServer.Responder
  ) {
    guard let name = params["name"] as? String else {
      return respond(error: -32602, "tools/call needs a tool name.", id: id, via: responder)
    }
    guard AgentTools.definitions.contains(where: { $0["name"] as? String == name }) else {
      return respond(error: -32602, "Unknown tool: \(name)", id: id, via: responder)
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    let progressToken = (params["_meta"] as? [String: Any])?["progressToken"]
    let key = Self.key(id)
    if streaming { responder.startEvents() }
    let task = Task { @MainActor [tools] in
      let keepAlive = streaming ? Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(15))
          responder.sendKeepAlive()
        }
      } : nil
      defer { keepAlive?.cancel() }
      var result: [String: Any]
      do {
        // MCP progress must only increase, and the steps restart at 0 between phases.
        var reached = 0
        var total: Int?
        result = try await tools.call(name, arguments: arguments, context: context) { progress in
          guard streaming, let progressToken else { return }
          reached = max(reached, progress.step)
          total = progress.total ?? total
          var params: [String: Any] = [
            "progressToken": progressToken, "progress": reached, "message": progress.message,
          ]
          if let total { params["total"] = total }
          Self.send(["jsonrpc": "2.0", "method": "notifications/progress", "params": params], streamingTo: responder)
        }
      } catch is CancellationError {
        result = ["content": [["type": "text", "text": "Cancelled."]], "isError": true]
      } catch {
        // A job's error can quote a file a client on this Mac named.
        let message = context.isRemote ? AgentPathGuard.redactingPaths(error.localizedDescription) : error.localizedDescription
        result = ["content": [["type": "text", "text": message]], "isError": true]
      }
      calls[key] = nil
      let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
      if streaming {
        Self.send(response, streamingTo: responder)
        responder.finish()
      } else {
        Self.send(response, via: responder)
      }
    }
    calls[key] = task
    // A client that hangs up (some give up on calls after a few minutes) doesn't stop the run:
    // generate keeps it going as a job for get_job.
  }

  private func respond(result: [String: Any], id: Any, via responder: LoopbackHTTPServer.Responder) {
    Self.send(["jsonrpc": "2.0", "id": id, "result": result], via: responder)
  }

  private func respond(error code: Int, _ message: String, id: Any, via responder: LoopbackHTTPServer.Responder) {
    Self.send(
      ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]], via: responder)
  }

  private static func send(_ message: [String: Any], via responder: LoopbackHTTPServer.Responder) {
    let data = (try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)) ?? Data()
    responder.send(status: 200, contentType: "application/json", body: data)
  }

  private static func send(_ message: [String: Any], streamingTo responder: LoopbackHTTPServer.Responder) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
    else { return }
    responder.sendEvent(data)
  }

  private static func key(_ id: Any) -> String { "\(id)" }
}

/// Settings → Agents: turn the MCP server on, who can reach it, and how to connect an agent to it.
struct AgentSettingsView: View {
  @Environment(AgentServer.self) private var server
  @State private var portText = ""
  @State private var httpsPortText = ""
  @State private var showsToken = false
  @AppStorage("agentClient") private var client = AgentClient.claudeCode
  /// The address the setup below uses: this Mac's, or one of its network addresses.
  @State private var address = ""
  @State private var importingCertificate = false
  /// The .p12 picked, waiting for its password.
  @State private var certificateFile: Data?
  @State private var certificatePassword = ""
  @State private var certificateError: String?

  var body: some View {
    @Bindable var server = server
    let network = server.activeAccess == .localNetwork
    Form {
      Section {
        Toggle(isOn: $server.isEnabled) {
          Text("Let agents generate images")
          Text("Runs an MCP server that agents such as Claude Code can use to list models and presets, read and change the Create screen, and generate images. Images are saved to the current project.")
        }
        Picker(selection: $server.access) {
          ForEach(AgentAccess.allCases) { Text($0.title).tag($0) }
        } label: {
          Text("Access")
          Text(accessNote)
        }
        Link("Before You Open the Server to Your Network", destination: Self.networkSafetyGuide)
        Toggle(isOn: $server.requireToken) {
          Text("Require Token")
          Text("Agents on other devices send this token. Agents on this Mac never need it.")
        }
        .disabled(!network)
        LabeledContent("Token") {
          HStack {
            Text(tokenText)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(1)
              .truncationMode(.middle)
            Button(showsToken ? "Hide" : "Show") { showsToken.toggle() }
            Button("Copy") { Clipboard.copy(server.ensureToken()) }
            Button("Regenerate") { server.regenerateToken() }
          }
        }
        .disabled(!network || !server.requireToken)
        LabeledContent("Port") {
          TextField("Port", text: $portText)
            .labelsHidden()
            .frame(width: 80)
            .onSubmit { applyPort() }
        }
        LabeledContent("Status") {
          HStack {
            VStack(alignment: .trailing) {
              if !server.isEnabled, !server.isListening {
                Text("Off").foregroundStyle(.secondary)
              } else if let error = server.listenError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
              } else if server.isListening {
                Text(server.tools.activity ?? "Listening at \(server.endpoint)")
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              } else {
                Text("Starting…").foregroundStyle(.secondary)
              }
              if let refusal = server.portRefusal {
                Label(refusal, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
              }
            }
            Button("Try Again") { server.retryListening() }
              .rowButton()
              .disabled(!server.listenPortError)
          }
        }
        if let last = server.tools.lastResult {
          LabeledContent("Last image", value: last)
        }
      } header: {
        Text("MCP Server")
      }
      encryptionSection(network: network)
      Section {
        Picker("Agent", selection: $client) {
          ForEach(AgentClient.allCases) { Text($0.title).tag($0) }
        }
        Picker("Address", selection: $address) {
          ForEach(addresses, id: \.self) { Text($0).tag($0) }
        }
        Text(client.instructions(withToken: setupToken != nil))
          .foregroundStyle(.secondary)
        Text(client.setup(chosenAddress, token: setupToken.map { showsToken ? $0 : Self.masked }))
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
          Spacer()
          Button("Copy") {
            Clipboard.copy(client.setup(chosenAddress, token: setupToken))
          }
        }
      } header: {
        Text("Connect an Agent")
      } footer: {
        Text("Atelier must be open with the server on while the agent works. Other MCP clients that speak Streamable HTTP can use the same address. For an agent on another device, pick one of this Mac's network addresses.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 600)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      portText = String(server.port)
      httpsPortText = server.explicitHTTPSPort.map(String.init) ?? ""
      server.refreshEndpoints()
      if server.activeAccess == .localNetwork, server.requireToken { server.ensureToken() }
      if address.isEmpty { address = server.endpoint }
      if server.encryption == .certificate { server.loadCertificateIfNeeded() }
    }
    .onChange(of: server.access) {
      if server.activeAccess == .localNetwork, server.requireToken { server.ensureToken() }
      server.refreshEndpoints()
    }
    .onChange(of: server.encryption) {
      if server.encryption == .certificate { server.loadCertificateIfNeeded() }
    }
    .fileImporter(isPresented: $importingCertificate, allowedContentTypes: [.pkcs12]) { result in
      guard case .success(let url) = result else { return }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        certificateFile = try Data(contentsOf: url)
        certificatePassword = ""
      } catch {
        certificateError = error.localizedDescription
      }
    }
    .alert(
      "Certificate Password", isPresented: Binding(get: { certificateFile != nil }, set: { if !$0 { certificateFile = nil } })
    ) {
      SecureField("Password", text: $certificatePassword)
      Button("Import") {
        guard let data = certificateFile else { return }
        do {
          try server.importCertificate(data, password: certificatePassword)
        } catch {
          certificateError = error.localizedDescription
        }
        certificateFile = nil
        certificatePassword = ""
      }
      Button("Cancel", role: .cancel) {
        certificateFile = nil
        certificatePassword = ""
      }
    } message: {
      Text("The password the .p12 file was exported with.")
    }
    .alert(
      "Couldn't Import the Certificate", isPresented: Binding(get: { certificateError != nil }, set: { if !$0 { certificateError = nil } })
    ) {
      Button("OK") { certificateError = nil }
    } message: {
      Text(certificateError ?? "")
    }
    .onChange(of: server.requireToken) {
      if server.requireToken, server.activeAccess == .localNetwork { server.ensureToken() }
    }
  }

  private static let masked = String(repeating: "•", count: 12)

  /// Where the tailnet's DNS settings are, with MagicDNS and HTTPS Certificates.
  private static let tailnetDNSSettings = URL(string: "https://login.tailscale.com/admin/dns")!

  /// The user guide's pages on GitHub: who should open the server to the network, and making and
  /// trusting a certificate for HTTPS.
  private static let networkSafetyGuide = URL(string: "https://github.com/ianiv/Atelier/blob/main/MCP.md#before-you-turn-on-local-network")!
  private static let certificateGuide = URL(string: "https://github.com/ianiv/Atelier/blob/main/docs/certificates.md")!

  /// Settings → Agents → Encryption: HTTPS for other devices, and its certificate.
  @ViewBuilder private func encryptionSection(network: Bool) -> some View {
    @Bindable var server = server
    let certificate = server.activeCertificate
    Section {
      Picker(selection: $server.encryption) {
        ForEach(AgentEncryption.allCases) { Text($0.title).tag($0) }
      } label: {
        Text("HTTPS")
        Text(encryptionNote)
      }
      LabeledContent("Certificate") {
        HStack {
          Text(certificate.map(Self.summary) ?? "None")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
          Button("Import…") { importingCertificate = true }
            .disabled(server.encryption != .certificate)
          Button("Remove") { server.removeCertificate() }
            .disabled(server.encryption != .certificate || server.certificate == nil)
          Button("Renew") { server.refreshTailscaleCertificate() }
            .disabled(server.encryption != .tailscale || !server.isListening || server.isFetchingCertificate)
        }
      }
      LabeledContent("SHA-256") {
        Text(certificate?.fingerprint ?? "—")
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      LabeledContent {
        if server.encryption == .tailscale {
          // Fixed: clients on the tailnet name no port.
          TextField("HTTPS Port", text: .constant(String(AgentAuth.tailnetHTTPSPort)))
            .labelsHidden()
            .frame(width: 80)
            .disabled(true)
        } else {
          TextField("HTTPS Port", text: $httpsPortText, prompt: Text("Automatic"))
            .labelsHidden()
            .frame(width: 80)
            .onSubmit { applyHTTPSPort() }
            .disabled(server.encryption != .certificate)
        }
      } label: {
        Text("HTTPS Port")
        Text("For an imported certificate. Leave empty for automatic: two past the server's port, kept off Compute's.")
      }
      LabeledContent("Status") {
        HStack {
          VStack(alignment: .trailing) {
            if !server.usesHTTPS || (!server.isEnabled && !server.isListening) {
              Text("Off").foregroundStyle(.secondary)
            } else if let error = server.httpsError {
              Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if server.isFetchingCertificate {
              Text("Getting the certificate from Tailscale…").foregroundStyle(.secondary)
            } else if let endpoint = server.httpsEndpoint {
              Text("Listening at \(endpoint)").foregroundStyle(.secondary).textSelection(.enabled)
              if let warning = server.certificateWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
              }
            } else {
              Text("Starting…").foregroundStyle(.secondary)
            }
            if let refusal = server.httpsPortRefusal {
              Label(refusal, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
          }
          Button("Try Again") { server.retryHTTPS() }
            .rowButton()
            .disabled(!server.httpsPortError)
        }
      }
      Link("Turn On HTTPS Certificates for Your Tailnet", destination: Self.tailnetDNSSettings)
        .disabled(server.encryption != .tailscale)
      Link("How to Make a Certificate", destination: Self.certificateGuide)
    } header: {
      Text("Encryption")
    } footer: {
      Text("With HTTPS, other devices can't use plain HTTP: port \(String(server.port)) answers this Mac only. An imported certificate serves the local network on port \(server.httpsPort.map(String.init) ?? "—") (the HTTPS Port). Tailscale's certificate is for Atelier's own tailnet name and needs MagicDNS and HTTPS Certificates turned on for your tailnet; it comes from Let's Encrypt, which lists every certificate's name in public Certificate Transparency logs, so the name becomes public.")
        .foregroundStyle(.secondary)
    }
    .disabled(!network)
  }

  private static func summary(_ certificate: AgentTLSIdentity) -> String {
    guard let expires = certificate.expires else { return certificate.name }
    return "\(certificate.name), expires \(expires.formatted(date: .abbreviated, time: .omitted))"
  }

  private var encryptionNote: String {
    switch server.encryption {
    case .none: "Other devices connect in plain HTTP."
    case .tailscale: "Other devices on your tailnet connect to Atelier's Tailscale name over HTTPS."
    case .certificate: "Other devices connect over HTTPS with a certificate you import (.p12)."
    }
  }

  /// Says which protection is missing: the token keeps others out, HTTPS keeps the token secret.
  private var accessNote: String {
    guard server.activeAccess == .localNetwork else {
      return "Only apps on this Mac can connect. Use Local network only on a network you trust; on any other, turn on HTTPS and Require Token too."
    }
    switch (server.requireToken, server.usesHTTPS) {
    case (true, true):
      return "Anyone on your network with the token can generate and read or change the Create screen. Traffic from other devices is encrypted (HTTPS)."
    case (true, false):
      return "Not encrypted: anyone on your network can read the token and images, then use the token. Use this only on a network you trust, or turn on HTTPS below."
    case (false, true):
      return "No token: anyone on your network can generate and read or change the Create screen. Use this only on a network you trust, or turn on Require Token."
    case (false, false):
      return "No token and not encrypted: anyone on your network can use the server and see its images. Use this only on a network you trust, or turn on Require Token and HTTPS."
    }
  }

  private var tokenText: String {
    guard let token = server.token else { return Self.masked }
    return showsToken ? token : Self.masked
  }

  /// This Mac's endpoint, then the network ones when other devices can connect.
  private var addresses: [String] {
    [server.endpoint] + (server.activeAccess == .localNetwork ? server.networkEndpoints : [])
  }

  private var chosenAddress: String {
    addresses.contains(address) ? address : server.endpoint
  }

  /// The token the setup carries: for a network address when one is required.
  private var setupToken: String? {
    guard chosenAddress != server.endpoint, server.networkNeedsToken else { return nil }
    return server.token
  }

  /// A port another of Atelier's servers holds is refused, the field going back to the current one
  /// and Status saying whose it is.
  private func applyPort() {
    if let port = Int(portText), PortClaims.validPorts.contains(port) {
      server.choosePort(port)
    }
    portText = String(server.port)
  }

  /// Empty is Automatic.
  private func applyHTTPSPort() {
    let text = httpsPortText.trimmingCharacters(in: .whitespaces)
    if text.isEmpty {
      server.chooseHTTPSPort(nil)
    } else if let port = Int(text), PortClaims.validPorts.contains(port) {
      server.chooseHTTPSPort(port)
    }
    httpsPortText = server.explicitHTTPSPort.map(String.init) ?? ""
  }
}
#endif
