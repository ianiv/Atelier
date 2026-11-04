#if os(macOS)
import Foundation
import Network
import Synchronization

/// A minimal HTTP/1.1 server on the loopback interface, for the MCP endpoint. One request per
/// connection: the response (a plain body, or an event stream) ends with the connection closed.
final nonisolated class LoopbackHTTPServer: Sendable {
  struct Request {
    var method: String
    var path: String
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data
  }

  /// Reports why listening failed (the port is taken, say); nil once it's listening.
  typealias StateHandler = @Sendable (_ error: String?) -> Void
  typealias Handler = @Sendable (Request, Responder) -> Void

  let port: UInt16
  private let handler: Handler
  private let queue = DispatchQueue(label: "Atelier.LoopbackHTTPServer")
  private let listeners = Mutex<[NWListener]>([])

  /// Bodies past this are refused; images sent inline as base64 fit well under it.
  static let maxBodySize = 64 << 20

  init(port: UInt16, handler: @escaping Handler) {
    self.port = port
    self.handler = handler
  }

  /// Listens on 127.0.0.1 and ::1 (clients may resolve "localhost" to either).
  func start(stateHandler: @escaping StateHandler) {
    queue.async { [self] in
      guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        stateHandler("\(port) isn't a valid port.")
        return
      }
      for (index, host) in [NWEndpoint.Host.ipv4(.loopback), .ipv6(.loopback)].enumerated() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: nwPort)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { continue }
        // Only the IPv4 listener's state is reported: IPv6 loopback can be missing.
        let isPrimary = index == 0
        listener.stateUpdateHandler = { state in
          guard isPrimary else { return }
          switch state {
          case .ready: stateHandler(nil)
          case .failed(let error): stateHandler(Self.describe(error))
          default: break
          }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        listeners.withLock { $0.append(listener) }
      }
    }
  }

  func stop() {
    queue.async { [self] in
      listeners.withLock {
        $0.forEach { $0.cancel() }
        $0 = []
      }
    }
  }

  private static func describe(_ error: NWError) -> String {
    if case .posix(let code) = error, code == .EADDRINUSE {
      return "Another app is using this port."
    }
    return error.localizedDescription
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(on: connection, buffer: Data())
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
      [self] data, _, isComplete, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      switch Self.parse(buffer) {
      case .request(let request):
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
          receive(on: connection, buffer: buffer)
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

    func startEvents() {
      write(
        Self.head(
          status: 200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]),
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
          200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
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
