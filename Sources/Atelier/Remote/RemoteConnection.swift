import Foundation
import Network
import Security
import Synchronization

/// TLS-PSK for every connection: TLS 1.2 with TLS_PSK_WITH_AES_128_GCM_SHA256, so neither side can
/// talk to the other without the key, and there are no certificates to mint, expire or pin.
nonisolated enum RemoteTLS {
  private static func dispatchData(_ data: Data) -> dispatch_data_t {
    data.withUnsafeBytes { DispatchData(bytes: $0) as dispatch_data_t }
  }

  private static func parameters(_ configure: (sec_protocol_options_t) -> Void) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
      sec_protocol_options_append_tls_ciphersuite(options, suite)
    }
    configure(options)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 30
    let parameters = NWParameters(tls: tls, tcp: tcp)
    parameters.defaultProtocolStack.applicationProtocols.insert(
      NWProtocolFramer.Options(definition: RemoteFramer.definition), at: 0)
    return parameters
  }

  static func client(identity: String, key: Data) -> NWParameters {
    parameters { sec_protocol_options_add_pre_shared_key($0, dispatchData(key), dispatchData(Data(identity.utf8))) }
  }

  /// A listener's parameters: every key it can accept, and `accepts`, asked about each connecting
  /// identity. The selection block answers with an identity, not a key: see `RemoteListener`.
  static func server(
    keys: [String: Data], queue: DispatchQueue, accepts: @escaping @Sendable (String) -> Bool
  ) -> NWParameters {
    parameters { options in
      for (identity, key) in keys {
        sec_protocol_options_add_pre_shared_key(options, dispatchData(key), dispatchData(Data(identity.utf8)))
      }
      sec_protocol_options_set_pre_shared_key_selection_block(options, { _, identity, complete in
        // This API hands back the data it was given, as an NSData-bridged dispatch_data_t.
        let name = identity.flatMap { (($0 as AnyObject) as? NSData) as Data? }
          .flatMap { String(data: $0, encoding: .utf8) }
        guard let name, accepts(name) else { return complete(nil) }
        complete(identity)
      }, queue)
    }
  }

  /// Whether `error` means the server turned the key down, so trying again won't help.
  static func isKeyRefusal(_ error: Error) -> Bool {
    guard let error = error as? NWError, case .tls(let status) = error else { return false }
    return [errSSLUnknownPSKIdentity, errSSLBadRecordMac, errSSLPeerBadRecordMac, errSSLPeerHandshakeFail].contains(status)
  }
}

/// A single-shot continuation that several callbacks race to finish.
private final nonisolated class Once<Value: Sendable>: Sendable {
  private let continuation: Mutex<CheckedContinuation<Value, Error>?>

  init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = Mutex(continuation) }

  @discardableResult
  func resume(_ result: Result<Value, Error>) -> Bool {
    guard let continuation = continuation.withLock({ value -> CheckedContinuation<Value, Error>? in
      defer { value = nil }
      return value
    }) else { return false }
    continuation.resume(with: result)
    return true
  }
}

/// An `NWConnection` speaking frames.
final nonisolated class RemoteConnection: Sendable {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "Atelier.RemoteConnection")

  init(_ connection: NWConnection) { self.connection = connection }

  /// A client's connection to `address`, not started.
  convenience init(to address: RemoteAddress, identity: String, key: Data) {
    let host = NWEndpoint.Host(address.host)
    let port = NWEndpoint.Port(rawValue: address.port) ?? .any
    self.init(NWConnection(host: host, port: port, using: RemoteTLS.client(identity: identity, key: key)))
  }

  /// Connects, up to the handshake's end. `.waiting` counts as a failure: a client tries its next
  /// address rather than waiting on this one.
  func start(timeout: TimeInterval = 8) async throws {
    let connection = connection
    let queue = queue
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = Once(continuation)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          once.resume(.success(()))
        case .failed(let error), .waiting(let error):
          if once.resume(.failure(error)) { connection.cancel() }
        case .cancelled:
          once.resume(.failure(RemoteError.connectionLost))
        default:
          break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + timeout) {
        if once.resume(.failure(NWError.posix(.ETIMEDOUT))) { connection.cancel() }
      }
    }
  }

  /// Starts an accepted connection; a handshake that fails closes it, ending `receive`.
  func startAccepted() {
    let connection = connection
    connection.stateUpdateHandler = { state in
      switch state {
      case .failed, .waiting: connection.cancel()
      default: break
      }
    }
    connection.start(queue: queue)
  }

  /// Sends in order; a failure shows up as `receive` ending.
  func sendNow(_ frame: RemoteFrame) {
    do {
      let (kind, payload) = try frame.encoded()
      connection.send(content: payload, contentContext: RemoteFramer.context(for: kind), isComplete: true, completion: .contentProcessed { error in
        if let error { Log.remote.debug("Send failed: \(error.localizedDescription, privacy: .public)") }
      })
    } catch {
      Log.remote.error("Couldn't encode a frame: \(error.localizedDescription, privacy: .public)")
    }
  }

  func receive() async throws -> RemoteFrame {
    let connection = connection
    return try await withCheckedThrowingContinuation { continuation in
      connection.receiveMessage { data, context, _, error in
        if let error { return continuation.resume(throwing: error) }
        guard let data, let kind = RemoteFramer.kind(in: context) else {
          return continuation.resume(throwing: RemoteError.connectionLost)
        }
        continuation.resume(with: Result { try RemoteFrame(kind: kind, payload: data) })
      }
    }
  }

  func cancel() { connection.cancel() }
}
