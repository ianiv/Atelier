import Darwin
import Foundation
import Observation
import Synchronization
#if canImport(TailscaleKit)
  @preconcurrency import TailscaleKit
#endif

/// Moves bytes between two sockets, for connections that come through Tailscale's library: it hands
/// out plain sockets, and everything else about a connection, TLS-PSK included, stays in
/// Network.framework at both ends. So the library only ever carries encrypted bytes it can't read.
nonisolated enum RemoteSocketBridge {
  /// Copies both ways until both directions end, then closes both sockets. A thread each way: there
  /// are only ever a few of these, and each just waits.
  static func pump(_ first: Int32, _ second: Int32) {
    let remaining = Mutex(2)
    let finished: @Sendable () -> Void = {
      let done = remaining.withLock { value -> Bool in
        value -= 1
        return value == 0
      }
      if done {
        close(first)
        close(second)
      }
    }
    for (from, to) in [(first, second), (second, first)] {
      Thread.detachNewThread {
        copy(from: from, to: to)
        finished()
      }
    }
  }

  private static func copy(from: Int32, to: Int32) {
    var noSignal: Int32 = 1
    setsockopt(to, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    copying: while true {
      let count = read(from, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      var written = 0
      while written < count {
        let sent = buffer.withUnsafeBytes { write(to, $0.baseAddress! + written, count - written) }
        if sent < 0, errno == EINTR { continue }
        guard sent > 0 else { break copying }
        written += sent
      }
    }
    // Lets the other side finish what it's sending, and wakes the copy going the other way if not.
    shutdown(to, SHUT_WR)
    shutdown(from, SHUT_RD)
  }

  private static func loopback(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
  }

  /// A connected socket to this device's `port`.
  static func connectLoopback(port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = loopback(port: port)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else {
      close(fd)
      return nil
    }
    return fd
  }

  /// A socket listening on a free loopback port, and the port.
  static func listenLoopback() -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = loopback(port: 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        Darwin.bind(fd, pointer, length) == 0 && Darwin.listen(fd, 1) == 0 && getsockname(fd, pointer, &length) == 0
      }
    }
    guard bound else {
      close(fd)
      return nil
    }
    return (fd, UInt16(bigEndian: address.sin_port))
  }

  /// Takes one connection from `fd` and closes it; nil if none comes in time.
  static func acceptOne(_ fd: Int32, timeout: Int32) -> Int32? {
    defer { close(fd) }
    var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&waiting, 1, timeout) > 0 else { return nil }
    let connection = accept(fd, nil, nil)
    return connection >= 0 ? connection : nil
  }
}

/// What the embedded node says about itself and its peers, from its status JSON (ipnstate.Status).
nonisolated struct RemoteTailnetStatus: Equatable, Sendable {
  var backendState = ""
  var authURL: String?
  var dnsName: String?
  var addresses: [String] = []
  var magicDNSSuffix: String?
  /// The login of this node's user.
  var login: String?
  /// Each peer's address, and the login of who owns it.
  var peerLogins: [String: String] = [:]

  init() {}

  init?(json data: Data) {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    backendState = root["BackendState"] as? String ?? ""
    authURL = (root["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    magicDNSSuffix = ((root["CurrentTailnet"] as? [String: Any])?["MagicDNSSuffix"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let users = root["User"] as? [String: [String: Any]] ?? [:]
    func loginName(ofUser id: Any?) -> String? {
      guard let id = id as? NSNumber else { return nil }
      return users[id.stringValue]?["LoginName"] as? String
    }
    if let me = root["Self"] as? [String: Any] {
      dnsName = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
      addresses = me["TailscaleIPs"] as? [String] ?? []
      login = loginName(ofUser: me["UserID"])
    }
    for peer in (root["Peer"] as? [String: [String: Any]] ?? [:]).values {
      guard let owner = loginName(ofUser: peer["UserID"]) else { continue }
      for address in peer["TailscaleIPs"] as? [String] ?? [] {
        peerLogins[address] = owner
      }
    }
  }

  /// Limit access to your Tailscale account: a caller gets through if it's a device of the same
  /// login as this one. One that can't be told apart, such as a node just joined, doesn't.
  func admits(caller remoteAddress: String, limitToAccount: Bool) -> Bool {
    guard limitToAccount else { return true }
    let host: String
    if remoteAddress.hasPrefix("["), let end = remoteAddress.firstIndex(of: "]") {
      host = String(remoteAddress[remoteAddress.index(after: remoteAddress.startIndex)..<end])
    } else {
      host = remoteAddress.split(separator: ":").first.map(String.init) ?? remoteAddress
    }
    guard let login, let owner = peerLogins[host] else { return false }
    return owner == login
  }

  /// Whether `host` is reached over the tailnet.
  func isTailnetHost(_ host: String) -> Bool {
    if RemoteIP(host)?.isTailscale == true || host.hasSuffix(".ts.net") { return true }
    return magicDNSSuffix.map { host.hasSuffix("." + $0) } ?? false
  }
}

/// Atelier's own place on your tailnet: TailscaleKit makes this app a Tailscale node by itself, with
/// no Tailscale app needed and no VPN. Tailscale is only the network here. A connection still needs
/// its device's key, and the tailnet's connections are bridged into the same TLS-PSK path as any
/// other, so pairing stays end to end. With no TailscaleKit in this build (`Scripts/build-tailscale.sh`
/// makes one), all this is unavailable and a Tailscale app still works through its own addresses.
@MainActor
@Observable
final class RemoteTailnet {
  enum State: Equatable {
    /// This build doesn't include TailscaleKit.
    case unavailable
    case signedOut
    case starting
    /// Waiting for you to sign in at this address.
    case needsLogin(URL)
    case running
    case failed(String)
  }

  /// What differs in a scripted check, which leaves your sign-in alone.
  struct Options {
    var folder = RemotePaths.root.appending(path: "Tailscale", directoryHint: .isDirectory)
    var persists = SessionState.isEnabled
    var controlURL: String?
    var hostname: String?
  }

  private static let signedInKey = "tailscale.signedIn"
  private static let servesKey = "tailscale.serves"
  private static let limitKey = "tailscale.limitToAccount"
  private static let controlKey = "tailscale.controlURL"
  private static let hostnameKey = "tailscale.hostname"

  private(set) var state: State
  private(set) var status = RemoteTailnetStatus()
  /// Told when `state` changes.
  @ObservationIgnored var onChange: (() -> Void)?

  /// Serve over Tailscale.
  var serves: Bool {
    didSet {
      if options.persists { UserDefaults.standard.set(serves, forKey: Self.servesKey) }
      onChange?()
    }
  }

  /// Limit access to your Tailscale account.
  var limitsToAccount: Bool {
    didSet {
      if options.persists { UserDefaults.standard.set(limitsToAccount, forKey: Self.limitKey) }
      shared.withLock { $0.limitsToAccount = limitsToAccount }
    }
  }

  /// Empty for Tailscale's own; a Headscale server's address otherwise. Takes effect at sign-in.
  var controlURL: String {
    didSet { if options.persists { UserDefaults.standard.set(controlURL, forKey: Self.controlKey) } }
  }

  /// The name this device takes on the tailnet. Takes effect the next time the node starts.
  var hostname: String {
    didSet { if options.persists { UserDefaults.standard.set(hostname, forKey: Self.hostnameKey) } }
  }

  var isSignedIn: Bool { state == .running }

  /// This device's name on the tailnet, or else its address, for pairing links.
  var addresses: [String] {
    guard isSignedIn else { return [] }
    let ipv4 = status.addresses.filter { !$0.contains(":") }
    return (status.dnsName.map { [$0] } ?? []) + ipv4
  }

  private let options: Options

  private struct Shared {
    var handle: Int32 = 0
    var status = RemoteTailnetStatus()
    var limitsToAccount = true
    var listener: Int32 = 0
    /// Bumped to end the accept loop of an earlier listener.
    var listening = 0
  }

  /// What the threads carrying connections read.
  private let shared = Mutex(Shared())
  #if canImport(TailscaleKit)
    private var node: TailscaleNode?
  #endif
  private var watching: Task<Void, Never>?
  private var askedForLogin = false

  init(options: Options = Options()) {
    self.options = options
    let defaults = UserDefaults.standard
    serves = options.persists ? defaults.object(forKey: Self.servesKey) as? Bool ?? true : true
    limitsToAccount = options.persists ? defaults.object(forKey: Self.limitKey) as? Bool ?? true : true
    controlURL = options.controlURL ?? (options.persists ? defaults.string(forKey: Self.controlKey) : nil) ?? ""
    hostname = options.hostname ?? (options.persists ? defaults.string(forKey: Self.hostnameKey) : nil)
      ?? Self.defaultHostname(for: RemoteNetworkInfo.deviceName)
    #if canImport(TailscaleKit)
      state = .signedOut
    #else
      state = .unavailable
    #endif
    let limits = limitsToAccount
    shared.withLock { $0.limitsToAccount = limits }
    // Back on the tailnet after a relaunch. The node keeps its sign-in in its folder.
    if options.persists, defaults.bool(forKey: Self.signedInKey) { signIn() }
  }

  /// "Ianiv’s MacBook Pro" as a host name: "ianivs-macbook-pro-atelier".
  nonisolated static func defaultHostname(for deviceName: String) -> String {
    var name = ""
    for character in deviceName.lowercased() where !"'’".contains(character) {
      if character.isASCII, character.isLetter || character.isNumber {
        name.append(character)
      } else if !name.isEmpty, !name.hasSuffix("-") {
        name.append("-")
      }
    }
    while name.hasSuffix("-") { name.removeLast() }
    return name.isEmpty ? "atelier" : "\(name)-atelier"
  }

  private func set(_ new: State) {
    guard state != new else { return }
    state = new
    onChange?()
  }

  // MARK: - Signing in

  /// Starts the node. If it hasn't signed in before, `state` soon holds the page to do that on.
  func signIn() {
    #if canImport(TailscaleKit)
      guard node == nil else { return }
      set(.starting)
      askedForLogin = false
      do {
        try FileManager.default.createDirectory(at: options.folder, withIntermediateDirectories: true)
        let control = controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = Configuration(
          hostName: hostname, path: options.folder.path, authKey: nil,
          controlURL: control.isEmpty ? kDefaultControlURL : control)
        let node = try TailscaleNode(config: configuration, logger: nil)
        self.node = node
        if options.persists { UserDefaults.standard.set(true, forKey: Self.signedInKey) }
        Task {
          let handle = await node.tailscale ?? 0
          shared.withLock { $0.handle = handle }
          watch(node)
        }
      } catch {
        set(.failed(error.localizedDescription))
      }
    #endif
  }

  #if canImport(TailscaleKit)
    /// Follows the node's status: quickly while it's signing in, then now and then. It's the status
    /// rather than the IPN bus because the bus runs over a loopback address, and iOS can take that
    /// away from a suspended app for good; tsnet's own wait for sign-in reads this too.
    private func watch(_ node: TailscaleNode) {
      watching?.cancel()
      watching = Task { [weak self] in
        var waits = 0
        while !Task.isCancelled {
          guard let data = try? await node.statusJSON(), let status = RemoteTailnetStatus(json: data), let self else {
            try? await Task.sleep(for: .seconds(1))
            continue
          }
          self.update(status)
          // tsnet asks for a sign-in page by itself; if none has come after a while, this does.
          if status.backendState == "NeedsLogin", status.authURL == nil {
            waits += 1
            if waits >= 5, !askedForLogin {
              askedForLogin = true
              try? await LocalAPIClient(localNode: node, logger: nil).startLoginInteractive()
            }
          }
          try? await Task.sleep(for: .seconds(self.state == .running ? 15 : 1))
        }
      }
    }

    private func update(_ new: RemoteTailnetStatus) {
      status = new
      shared.withLock { $0.status = new }
      switch new.backendState {
      case "Running":
        set(.running)
      case "NeedsLogin", "NeedsMachineAuth":
        if let url = new.authURL.flatMap(URL.init(string:)) {
          set(.needsLogin(url))
        } else if case .needsLogin = state {
          // Keep showing the page until the next state.
        } else {
          set(.starting)
        }
      default:
        if state != .running { set(.starting) }
      }
    }

    /// A LocalAPI call, for what `LocalAPIClient` doesn't offer.
    private func localAPI(_ path: String, node: TailscaleNode) async throws {
      let loopback = try await node.loopback()
      guard let url = URL(string: "http://\(loopback.address)/localapi/v0/\(path)") else { return }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
      let credential = Data(":\(loopback.localAPIKey)".utf8).base64EncodedString()
      request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
      _ = try await URLSession.shared.data(for: request)
    }
  #endif

  /// Signs out, and forgets this device's node so the next sign-in starts afresh.
  func signOut() async {
    #if canImport(TailscaleKit)
      watching?.cancel()
      watching = nil
      stopListening()
      shared.withLock {
        $0.handle = 0
        $0.status = RemoteTailnetStatus()
      }
      if let node {
        // Takes it off the tailnet if it can; it stops being used either way.
        try? await localAPI("logout", node: node)
        try? await node.close()
      }
      node = nil
      status = RemoteTailnetStatus()
      try? FileManager.default.removeItem(at: options.folder)
      if options.persists { UserDefaults.standard.set(false, forKey: Self.signedInKey) }
      set(.signedOut)
    #endif
  }

  /// Stops the node, keeping its sign-in, to pick up a new host name.
  func restart() async {
    #if canImport(TailscaleKit)
      guard let node else { return }
      watching?.cancel()
      stopListening()
      shared.withLock { $0.handle = 0 }
      try? await node.close()
      self.node = nil
      signIn()
    #endif
  }

  // MARK: - Serving

  /// Accepts tailnet connections on `port` and passes each to this device's bridge listener. The
  /// caller is checked here, where its tailnet address is still known; past the bridge it's a
  /// loopback connection like any other.
  func startListening(port: UInt16, bridgePort: @escaping @Sendable () -> UInt16?) {
    #if canImport(TailscaleKit)
      stopListening()
      let handle = shared.withLock(\.handle)
      guard handle != 0 else { return }
      var listener: Int32 = 0
      guard tailscale_listen(handle, "tcp", ":\(port)", &listener) == 0 else {
        Log.remote.error("Couldn't listen on the tailnet")
        return
      }
      let generation = shared.withLock { state -> Int in
        state.listener = listener
        state.listening += 1
        return state.listening
      }
      Thread.detachNewThread { [self] in
        Self.accept(listener: listener, generation: generation, state: self, bridgePort: bridgePort)
      }
    #endif
  }

  func stopListening() {
    #if canImport(TailscaleKit)
      let listener = shared.withLock { state -> Int32 in
        defer {
          state.listener = 0
          state.listening += 1
        }
        return state.listener
      }
      if listener != 0 { close(listener) }
    #endif
  }

  #if canImport(TailscaleKit)
    private nonisolated static func accept(
      listener: Int32, generation: Int, state: RemoteTailnet, bridgePort: @escaping @Sendable () -> UInt16?
    ) {
      while state.shared.withLock({ $0.listening == generation }) {
        var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let ready = poll(&waiting, 1, 500)
        if ready == 0 { continue }
        guard ready > 0, state.shared.withLock({ $0.listening == generation }) else { break }
        var connection: Int32 = 0
        guard tailscale_accept(listener, &connection) == 0 else { break }
        var buffer = [CChar](repeating: 0, count: 128)
        let hasAddress = tailscale_getremoteaddr(listener, connection, &buffer, buffer.count) == 0
        let caller = hasAddress ? String(cString: buffer) : ""
        guard state.admits(caller: caller) else {
          Log.remote.info("Refused a tailnet connection from outside this Tailscale account")
          close(connection)
          continue
        }
        guard let port = bridgePort(), let bridge = RemoteSocketBridge.connectLoopback(port: port) else {
          close(connection)
          continue
        }
        RemoteSocketBridge.pump(connection, bridge)
      }
    }

    /// Asks the node afresh: a peer may have just joined, and it's asked once per connection.
    private nonisolated func admits(caller: String) -> Bool {
      let (handle, limits) = shared.withLock { ($0.handle, $0.limitsToAccount) }
      guard limits else { return true }
      var json: UnsafeMutablePointer<CChar>?
      guard handle != 0, tailscale_status_json(handle, &json) == 0, let json else { return false }
      defer { free(json) }
      let data = Data(bytes: json, count: strlen(json))
      return RemoteTailnetStatus(json: data)?.admits(caller: caller, limitToAccount: true) ?? false
    }
  #endif

  // MARK: - Connecting

  /// A route to `address` through the node: a loopback address that reaches it, to connect to as if
  /// it were there. Nil when it isn't on the tailnet or this device isn't signed in.
  nonisolated func bridge(to address: RemoteAddress) -> RemoteAddress? {
    #if canImport(TailscaleKit)
      let (handle, status) = shared.withLock { ($0.handle, $0.status) }
      guard handle != 0, status.backendState == "Running", status.isTailnetHost(address.host),
            let local = RemoteSocketBridge.listenLoopback()
      else { return nil }
      let target = address.description
      Thread.detachNewThread {
        guard let incoming = RemoteSocketBridge.acceptOne(local.fd, timeout: 15_000) else { return }
        var connection: Int32 = 0
        guard tailscale_dial(handle, "tcp", target, &connection) == 0 else {
          close(incoming)
          return
        }
        RemoteSocketBridge.pump(incoming, connection)
      }
      return RemoteAddress(host: "127.0.0.1", port: local.port)
    #else
      return nil
    #endif
  }
}

/// A route through the tailnet, for an address that takes one.
typealias RemoteRouter = @Sendable (RemoteAddress) -> RemoteAddress?
