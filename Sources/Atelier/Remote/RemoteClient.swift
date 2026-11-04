import CryptoKit
import Foundation
import Network

/// A connection to one paired server: connects when needed, reconnects after a drop, matches
/// replies to requests, and hands job events to whoever's waiting for them.
actor RemoteClient {
  enum Update: Sendable {
    case event(RemoteJobEvent)
    /// The connection dropped. The job carries on at the server; ask again to catch up.
    case lost
  }

  nonisolated let server: RemoteServerRecord
  nonisolated let device: RemoteDeviceIdentity
  nonisolated let downloads: URL

  private var connection: RemoteConnection?
  private var opening: Task<RemoteConnection, Error>?
  private var reading: Task<Void, Never>?
  private var pending: [UUID: CheckedContinuation<RemoteFrame, Error>] = [:]
  private var updates: [UUID: AsyncStream<Update>.Continuation] = [:]

  init(server: RemoteServerRecord, device: RemoteDeviceIdentity, downloads: URL) {
    self.server = server
    self.device = device
    self.downloads = downloads
  }

  // MARK: - Connecting

  /// Whether the server answers right now, without the patience a job gets.
  func isReachable() async -> Bool {
    (try? await connected(rounds: 1, timeout: 3)) != nil
  }

  private func connected(rounds: Int = 4, timeout: TimeInterval = 8) async throws -> RemoteConnection {
    if let connection { return connection }
    if let opening { return try await opening.value }
    let server = server
    let device = device
    let task = Task { try await Self.open(server, device: device, rounds: rounds, timeout: timeout) }
    opening = task
    defer { opening = nil }
    let connection = try await task.value
    self.connection = connection
    reading = Task { [weak self] in await self?.read(connection) }
    return connection
  }

  /// Tries each address, a few rounds with short backoff: a server replacing its listener refuses
  /// connections for a moment. A server that turned the key down isn't asked again.
  private static func open(
    _ server: RemoteServerRecord, device: RemoteDeviceIdentity, rounds: Int, timeout: TimeInterval
  ) async throws -> RemoteConnection {
    for round in 0..<rounds {
      if round > 0 { try await Task.sleep(for: .milliseconds(250 << (round - 1))) }
      for address in server.addresses {
        let connection = RemoteConnection(to: address, identity: device.id.uuidString, key: server.key)
        do {
          try await connection.start(timeout: timeout)
          let proof = RemotePairing.proof(key: server.key, deviceID: device.id, purpose: "hello")
          connection.sendNow(.message(RemoteEnvelope(
            message: .hello(version: RemoteProtocol.version, deviceID: device.id, deviceName: device.name, proof: proof))))
          guard case .message(let answer) = try await connection.receive() else { throw RemoteError.connectionLost }
          switch answer.message {
          case .welcome(let version, let serverID, _):
            guard version == RemoteProtocol.version else { throw RemoteError.versionMismatch }
            guard serverID == server.id else { throw RemoteError.wrongServer }
            return connection
          case .refused:
            throw RemoteError.notPaired(server: server.name)
          default:
            throw RemoteError.connectionLost
          }
        } catch {
          connection.cancel()
          if RemoteTLS.isKeyRefusal(error) { throw RemoteError.notPaired(server: server.name) }
          if let error = error as? RemoteError, error != .connectionLost { throw error }
        }
      }
    }
    throw RemoteError.unreachable(server: server.name)
  }

  private func read(_ connection: RemoteConnection) async {
    while let frame = try? await connection.receive() {
      switch frame {
      case .chunk(let header, _):
        pending.removeValue(forKey: header.requestID)?.resume(returning: frame)
      case .message(let envelope):
        if let id = envelope.requestID {
          pending.removeValue(forKey: id)?.resume(returning: frame)
        } else if case .jobEvent(let event) = envelope.message {
          updates[event.jobID]?.yield(.event(event))
        }
      }
    }
    dropped(connection)
  }

  private func dropped(_ dropped: RemoteConnection) {
    guard connection === dropped else { return }
    connection = nil
    dropped.cancel()
    let waiting = pending
    pending = [:]
    for continuation in waiting.values { continuation.resume(throwing: RemoteError.connectionLost) }
    for continuation in updates.values { continuation.yield(.lost) }
  }

  /// Closes the connection; the next request opens a new one.
  func disconnect() { connection.map(dropped) }

  // MARK: - Requests

  private func send(_ frame: (UUID) -> RemoteFrame) async throws -> RemoteFrame {
    let connection = try await connected()
    return try await withCheckedThrowingContinuation { continuation in
      guard self.connection === connection else { return continuation.resume(throwing: RemoteError.connectionLost) }
      let id = UUID()
      pending[id] = continuation
      connection.sendNow(frame(id))
    }
  }

  /// Sends `message`; returns its reply, or throws what the server answered with.
  func request(_ message: RemoteMessage) async throws -> RemoteMessage {
    let reply = try await send { .message(RemoteEnvelope(requestID: $0, message: message)) }
    guard case .message(let envelope) = reply else { throw RemoteError.connectionLost }
    if case .failure(let text) = envelope.message { throw RemoteError.server(text) }
    return envelope.message
  }

  /// The job's events until `endUpdates`. Ask before submitting, to miss none.
  func startUpdates(job: UUID) -> AsyncStream<Update> {
    AsyncStream { updates[job] = $0 }
  }

  func endUpdates(job: UUID) { updates.removeValue(forKey: job)?.finish() }

  /// The job's latest state, after a drop.
  func latest(job: UUID) async throws -> RemoteJobEvent {
    guard case .jobEvent(let event) = try await request(.subscribe(jobID: job)) else { throw RemoteError.connectionLost }
    return event
  }

  // MARK: - Files

  /// Uploads `blob` unless the server has it, going on from whatever it has of an earlier try.
  func upload(_ blob: RemoteBlob, sent: @Sendable (Int) -> Void) async throws {
    guard case .blobStatus(let complete, let partial) = try await request(.blobCheck(hashes: [blob.hash])) else {
      throw RemoteError.connectionLost
    }
    guard !complete.contains(blob.hash) else { return sent(blob.data.count) }
    var offset = partial[blob.hash] ?? 0
    let total = blob.data.count
    while offset < total {
      try Task.checkCancellation()
      let end = min(offset + RemoteProtocol.chunkSize, total)
      let bytes = Data(blob.data[(blob.data.startIndex + offset)..<(blob.data.startIndex + end)])
      let current = offset
      let reply = try await send { .chunk(RemoteChunkHeader(requestID: $0, kind: .upload, id: blob.hash, offset: current, total: total), bytes) }
      guard case .message(let envelope) = reply else { throw RemoteError.connectionLost }
      switch envelope.message {
      case .blobAck(_, let next): offset = next
      case .failure(let text): throw RemoteError.server(text)
      default: throw RemoteError.connectionLost
      }
      sent(offset)
    }
  }

  private func partURL(_ job: UUID) -> URL { downloads.appending(path: "\(job.uuidString).part") }

  /// How much of a job's result is already here.
  func downloadedSize(job: UUID) -> Int {
    (try? partURL(job).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
  }

  /// Downloads a job's result from where an earlier try stopped, and checks it arrived intact.
  /// With `stopAfter`, stops early after that many chunks and returns nil.
  func download(
    job: UUID, size: Int, hash: String, chunkLength: Int = RemoteProtocol.chunkSize, stopAfter: Int? = nil,
    received: @Sendable (Int) -> Void
  ) async throws -> URL? {
    let manager = FileManager.default
    try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
    let url = partURL(job)
    if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
    var offset = downloadedSize(job: job)
    if offset > size {
      try manager.removeItem(at: url)
      manager.createFile(atPath: url.path, contents: nil)
      offset = 0
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    var chunks = 0
    while offset < size {
      try Task.checkCancellation()
      if let stopAfter, chunks >= stopAfter { return nil }
      let current = offset
      let reply = try await send {
        .message(RemoteEnvelope(requestID: $0, message: .resultRequest(jobID: job, offset: current, length: chunkLength)))
      }
      switch reply {
      case .chunk(let header, let bytes):
        guard header.offset == offset, !bytes.isEmpty else { throw RemoteError.corruptResult }
        try handle.write(contentsOf: bytes)
        offset += bytes.count
        chunks += 1
        received(offset)
      case .message(let envelope):
        if case .failure(let text) = envelope.message { throw RemoteError.server(text) }
        throw RemoteError.connectionLost
      }
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard SHA256.hash(data: data).hexString == hash else {
      try? manager.removeItem(at: url)
      throw RemoteError.corruptResult
    }
    return url
  }

  func removeDownload(job: UUID) { try? FileManager.default.removeItem(at: partURL(job)) }

  // MARK: - Pairing

  /// Pairs with the server at `addresses` using its code. A wrong code fails the TLS handshake.
  /// Returns the server, with this device's new key: nothing is saved here.
  static func pair(
    addresses: [RemoteAddress], code: String, expectedServerID: UUID?, device: RemoteDeviceIdentity
  ) async throws -> RemoteServerRecord {
    let key = RemotePairing.pairingKey(code: code)
    let ordered = addresses.enumerated().sorted { ($0.element.routeRank, $0.offset) < ($1.element.routeRank, $1.offset) }.map(\.element)
    var lastError: Error = RemoteError.unreachable(server: addresses.first?.host ?? "the server")
    for round in 0..<3 {
      if round > 0 { try await Task.sleep(for: .milliseconds(500 << (round - 1))) }
      for address in ordered {
        let connection = RemoteConnection(to: address, identity: RemoteProtocol.pairIdentity, key: key)
        defer { connection.cancel() }
        do {
          try await connection.start()
        } catch {
          guard let tlsError = error as? NWError, case .tls(let status) = tlsError else {
            lastError = error
            continue
          }
          if status == errSSLUnknownPSKIdentity || status == errSSLPeerHandshakeFail { throw RemoteError.pairingClosed }
          throw RemoteError.wrongCode
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let proof = RemotePairing.proof(key: key, deviceID: device.id, purpose: "pair")
        connection.sendNow(.message(RemoteEnvelope(
          message: .pairRequest(
            version: RemoteProtocol.version, deviceID: device.id, deviceName: device.name, proof: proof,
            publicKey: privateKey.publicKey.rawRepresentation))))
        guard case .message(let answer) = try await connection.receive() else { throw RemoteError.connectionLost }
        switch answer.message {
        case .pairGranted(let serverID, let serverName, let publicKey, let sealedKey):
          if let expectedServerID, expectedServerID != serverID { throw RemoteError.wrongServer }
          let deviceKey = try RemotePairing.open(sealed: sealedKey, serverKey: publicKey, privateKey: privateKey, code: code)
          return RemoteServerRecord(id: serverID, name: serverName, addresses: ordered, key: deviceKey)
        case .refused(let reason):
          throw RemoteError.server(reason)
        default:
          throw RemoteError.connectionLost
        }
      }
    }
    throw lastError
  }
}

/// An input of a job, by its SHA-256.
nonisolated struct RemoteBlob: Sendable {
  var hash: String
  var data: Data

  init(_ data: Data) {
    self.data = data
    hash = SHA256.hash(data: data).hexString
  }
}
