#if os(macOS)
import Foundation
import Network
import Synchronization

/// A minimal HTTP/1.1 server for the MCP endpoint, on the loopback interface or (Settings → Agents →
/// Access → Local network) every interface with a peer filter, in plain HTTP or, with an identity,
/// HTTPS. One request per connection: the response (a plain body, or an event stream) ends with
/// the connection closed.
final nonisolated class LoopbackHTTPServer: Sendable {
  struct Request {
    var method: String
    var path: String
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data
    /// The client's address; nil if the connection didn't say or came through the tailnet bridge,
    /// where every peer looks like this Mac. Nil never counts as this Mac.
    var peer: RemoteIP?
  }

  /// Where it listens.
  enum Binding: Sendable {
    /// 127.0.0.1 and ::1 only.
    case loopback
    /// Every interface, both IPv4 and IPv6, answering only peers `filter` allows.
    case all(RemoteAddressFilter)
    /// 127.0.0.1 on a free port (port 0), where `RemoteTailnet` hands over the tailnet's
    /// connections. Their peer is always 127.0.0.1 here, so none of them counts as this Mac's:
    /// each is treated as another device's (token and path rules), as is anything else on this
    /// Mac that finds the port.
    case tailnetBridge
  }

  /// Reports why listening failed (the port is taken, say); nil once it's listening.
  typealias StateHandler = @Sendable (_ failure: ListenFailure?) -> Void
  typealias Handler = @Sendable (Request, Responder) -> Void
  /// Looks at a request's peer and headers before its body is read: a status to refuse it with
  /// (the connection then closes without reading on), or nil.
  typealias HeadCheck = @Sendable (_ peer: RemoteIP?, _ headers: [String: String]) -> Int?

  let port: UInt16
  let binding: Binding
  /// The certificate HTTPS is served with; nil for plain HTTP. Fixed for the listener's life, so a
  /// new certificate means a new server.
  private let tls: AgentTLSIdentity?
  private let handler: Handler
  private let headCheck: HeadCheck?
  /// Open connections from other devices, closed when the server stops: what an old listener let
  /// in mustn't outlive it.
  private let remoteConnections = Mutex<[ObjectIdentifier: NWConnection]>([:])
  private let queue = DispatchQueue(label: "Atelier.LoopbackHTTPServer")
  private let listeners = Mutex<[NWListener]>([])
  private let isStopped = Mutex(false)
  private let bound = Mutex<UInt16?>(nil)

  /// The port listened on once it's ready: `port`, or the one picked for port 0.
  var boundPort: UInt16? { bound.withLock { $0 } }

  /// Bodies past this are refused; images sent inline as base64 fit well under it.
  static let maxBodySize = 64 << 20

  init(
    port: UInt16, binding: Binding = .loopback, tls: AgentTLSIdentity? = nil, headCheck: HeadCheck? = nil,
    handler: @escaping Handler
  ) {
    self.port = port
    self.binding = binding
    self.tls = tls
    self.headCheck = headCheck
    self.handler = handler
  }

  /// Listens on 127.0.0.1 and ::1 (clients may resolve "localhost" to either), or on every
  /// interface.
  func start(stateHandler: @escaping StateHandler) {
    queue.async { [self] in
      guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 || isBridge else {
        stateHandler(ListenFailure(PortClaims.invalidMessage, isPortError: false))
        return
      }
      guard tls == nil || tls?.secIdentity != nil else {
        stateHandler(ListenFailure("The certificate can't be used for HTTPS.", isPortError: false))
        return
      }
      if case .all(let filter) = binding {
        startAll(port: nwPort, filter: filter, retries: 1, stateHandler: stateHandler)
        return
      }
      startLoopback(port: nwPort, retries: 1, stateHandler: stateHandler)
    }
  }

  /// 127.0.0.1 and ::1, or 127.0.0.1 alone for the bridge (`RemoteSocketBridge.connectLoopback`
  /// reaches it there). Switching from every interface back to this Mac (Access, or Encryption
  /// turning HTTPS on) can find the old wildcard listener still closing, so a busy port is tried
  /// again once, as `startAll` does.
  private func startLoopback(port nwPort: NWEndpoint.Port, retries: Int, stateHandler: @escaping StateHandler) {
    let hosts: [NWEndpoint.Host] = isBridge ? [.ipv4(.loopback)] : [.ipv4(.loopback), .ipv6(.loopback)]
    // Only the IPv4 listener's state is reported: IPv6 loopback can be missing.
    let started: [(listener: NWListener, isPrimary: Bool)] = hosts.enumerated().compactMap { index, host in
      let parameters = makeParameters()
      parameters.requiredLocalEndpoint = .hostPort(host: host, port: nwPort)
      parameters.allowLocalEndpointReuse = true
      return (try? NWListener(using: parameters)).map { ($0, index == 0) }
    }
    let group = started.map(\.listener)
    for (listener, isPrimary) in started {
      listener.stateUpdateHandler = { [weak self] state in
        guard isPrimary else { return }
        switch state {
        case .ready:
          self?.bound.withLock { $0 = listener.port?.rawValue }
          stateHandler(nil)
        case .failed(let error):
          if retries > 0, case .posix(let code) = error, code == .EADDRINUSE, let self {
            group.forEach { $0.cancel() }
            self.listeners.withLock { $0.removeAll { listener in group.contains { $0 === listener } } }
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
              guard let self, !self.isStopped.withLock({ $0 }) else { return }
              self.startLoopback(port: nwPort, retries: retries - 1, stateHandler: stateHandler)
            }
          } else {
            stateHandler(self?.describe(error) ?? ListenFailure(error.localizedDescription, isPortError: false))
          }
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }
    listeners.withLock { $0.append(contentsOf: group) }
    group.forEach { $0.start(queue: queue) }
  }

  private var isBridge: Bool {
    if case .tailnetBridge = binding { return true }
    return false
  }

  /// TCP, or TLS over it with this server's certificate: TLS 1.2 at least, and HTTP/1.1 offered
  /// by ALPN, since that's all this server speaks.
  private func makeParameters() -> NWParameters {
    guard let identity = tls?.secIdentity else { return .tcp }
    let options = NWProtocolTLS.Options()
    let security = options.securityProtocolOptions
    sec_protocol_options_set_local_identity(security, identity)
    sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
    return NWParameters(tls: options, tcp: NWProtocolTCP.Options())
  }

  /// One dual-stack listener on every interface. Without endpoint reuse, which would let the
  /// wildcard bind succeed while another app holds 127.0.0.1 on the port, and that app would then
  /// get this Mac's own clients. The port can still be briefly busy right after a restart, so a
  /// busy port is tried again once.
  private func startAll(
    port nwPort: NWEndpoint.Port, filter: RemoteAddressFilter, retries: Int, stateHandler: @escaping StateHandler
  ) {
    guard let listener = try? NWListener(using: makeParameters(), on: nwPort) else {
      stateHandler(ListenFailure("Couldn't listen on port \(port).", isPortError: false))
      return
    }
    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.bound.withLock { $0 = listener.port?.rawValue }
        stateHandler(nil)
      case .failed(let error):
        listener.cancel()
        if retries > 0, case .posix(let code) = error, code == .EADDRINUSE, let self {
          self.listeners.withLock { $0.removeAll { $0 === listener } }
          self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            // Stopped meanwhile: nothing to start.
            guard let self, !self.isStopped.withLock({ $0 }) else { return }
            self.startAll(port: nwPort, filter: filter, retries: retries - 1, stateHandler: stateHandler)
          }
        } else {
          stateHandler(self?.describe(error) ?? ListenFailure(error.localizedDescription, isPortError: false))
        }
      default: break
      }
    }
    // As Compute's server does (`RemoteServer.start`): the address is checked before the
    // connection starts, so a peer outside the allowed networks gets nothing at all.
    listener.newConnectionHandler = { [weak self] connection in
      guard filter.allows(connection.endpoint) else { return connection.cancel() }
      self?.accept(connection)
    }
    listener.start(queue: queue)
    listeners.withLock { $0.append(listener) }
  }

  func stop() {
    isStopped.withLock { $0 = true }
    queue.async { [self] in
      listeners.withLock {
        $0.forEach { $0.cancel() }
        $0 = []
      }
      remoteConnections.withLock {
        $0.values.forEach { $0.cancel() }
        $0 = [:]
      }
    }
  }

  /// Runs on the listener's queue, off the main actor, where looking up a busy port's owner can
  /// take its time.
  private func describe(_ error: NWError) -> ListenFailure {
    ListenFailure.describe(error, port: Int(port))
  }

  private func accept(_ connection: NWConnection) {
    let peer = isBridge ? nil : Self.peer(of: connection)
    if !AgentAuth.isLoopback(peer) {
      let key = ObjectIdentifier(connection)
      remoteConnections.withLock { $0[key] = connection }
      connection.stateUpdateHandler = { [weak self] state in
        switch state {
        case .cancelled, .failed: self?.remoteConnections.withLock { $0[key] = nil }
        default: break
        }
      }
    }
    connection.start(queue: queue)
    receive(on: connection, peer: peer, buffer: Data(), headChecked: headCheck == nil)
  }

  private static func peer(of connection: NWConnection) -> RemoteIP? {
    if case .hostPort(let host, _) = connection.endpoint { return RemoteIP(host) }
    return nil
  }

  private func receive(on connection: NWConnection, peer: RemoteIP?, buffer: Data, headChecked: Bool) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
      [self] data, _, isComplete, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      var headChecked = headChecked
      if !headChecked, let headers = Self.headers(in: buffer) {
        headChecked = true
        if let status = headCheck?(peer, headers) {
          let extra = status == 401 ? ["WWW-Authenticate": "Bearer"] : [:]
          return Responder(connection: connection).send(status: status, headers: extra, body: Data())
        }
      }
      switch Self.parse(buffer) {
      case .request(var request):
        request.peer = peer
        let responder = Responder(connection: connection)
        watchForClose(connection, responder: responder)
        handler(request, responder)
      case .tooLarge:
        Responder(connection: connection).send(status: 413, body: Data())
      case .malformed:
        Responder(connection: connection).send(status: 400, body: Data())
      case .incomplete:
        if isComplete || error != nil {
          connection.cancel()
        } else {
          receive(on: connection, peer: peer, buffer: buffer, headChecked: headChecked)
        }
      }
    }
  }

  /// The client sends nothing after its request, so a read that ends means it hung up.
  private func watchForClose(_ connection: NWConnection, responder: Responder) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
      [self] data, _, isComplete, error in
      if isComplete || error != nil || data == nil {
        responder.clientDidClose()
      } else {
        watchForClose(connection, responder: responder)
      }
    }
  }

  private enum ParseResult {
    case incomplete, malformed, tooLarge
    case request(Request)
  }

  /// The request's headers once they're all in (names lowercased), whatever of the body has
  /// come; nil before that.
  static func headers(in buffer: Data) -> [String: String]? {
    guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
    var lines = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    lines.removeFirst()
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return headers
  }

  private static func parse(_ buffer: Data) -> ParseResult {
    guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
      return buffer.count > 64 << 10 ? .malformed : .incomplete
    }
    let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return .malformed }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { return .malformed }
    let length = Int(headers["content-length"] ?? "0") ?? -1
    guard length >= 0 else { return .malformed }
    guard length <= maxBodySize else { return .tooLarge }
    let bodyStart = headerEnd.upperBound
    guard buffer.count - bodyStart >= length else { return .incomplete }
    return .request(
      Request(
        method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
        body: Data(buffer[bodyStart..<bodyStart + length])))
  }

  /// Answers one request: a whole response with `send`, or an event stream with `startEvents`,
  /// `sendEvent` and `finish`.
  final class Responder: Sendable {
    private struct State {
      var closeHandler: (@Sendable () -> Void)?
      var isClosed = false
    }

    private let connection: NWConnection
    private let state = Mutex(State())

    fileprivate init(connection: NWConnection) {
      self.connection = connection
    }

    /// Called once if the client hangs up before the response is finished.
    func onClientClose(_ handler: @escaping @Sendable () -> Void) {
      state.withLock { $0.closeHandler = handler }
    }

    fileprivate func clientDidClose() {
      let handler = state.withLock {
        defer { $0.closeHandler = nil }
        return $0.isClosed ? nil : $0.closeHandler
      }
      handler?()
    }

    func send(status: Int, contentType: String? = nil, headers: [String: String] = [:], body: Data) {
      var all = headers
      if let contentType { all["Content-Type"] = contentType }
      all["Content-Length"] = String(body.count)
      write(Self.head(status: status, headers: all) + body, final: true)
    }

    func startEvents(headers: [String: String] = [:]) {
      write(
        Self.head(
          status: 200, headers: headers.merging(["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]) { _, fixed in fixed }),
        final: false)
    }

    func sendEvent(_ json: Data) {
      write(Data("event: message\ndata: ".utf8) + json + Data("\n\n".utf8), final: false)
    }

    /// An SSE comment, so proxies and clients see the stream is alive during long steps.
    func sendKeepAlive() {
      write(Data(": keep-alive\n\n".utf8), final: false)
    }

    func finish() {
      write(Data(), final: true)
    }

    private func write(_ data: Data, final: Bool) {
      let proceed = state.withLock {
        guard !$0.isClosed else { return false }
        if final { $0.isClosed = true }
        return true
      }
      guard proceed else { return }
      if final {
        connection.send(
          content: data, contentContext: .finalMessage, isComplete: true,
          completion: .contentProcessed { [connection] _ in connection.cancel() })
      } else {
        connection.send(content: data, completion: .contentProcessed { _ in })
      }
    }

    private static func head(status: Int, headers: [String: String]) -> Data {
      let reason =
        [
          200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
          405: "Method Not Allowed", 413: "Payload Too Large", 415: "Unsupported Media Type",
        ][status] ?? "Status"
      var text = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
      for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
        text += "\(name): \(value)\r\n"
      }
      return Data((text + "\r\n").utf8)
    }
  }
}
#endif
