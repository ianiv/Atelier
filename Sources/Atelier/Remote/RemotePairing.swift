import CryptoKit
import Foundation

/// Where a server can be reached.
nonisolated struct RemoteAddress: Codable, Hashable, Sendable, CustomStringConvertible {
  var host: String
  var port: UInt16

  /// `host`, `host:port` or `[v6]:port`; without a port, `defaultPort`.
  init?(_ text: String, defaultPort: UInt16 = RemoteProtocol.defaultPort) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.hasPrefix("[") {
      guard let end = text.firstIndex(of: "]") else { return nil }
      host = String(text[text.index(after: text.startIndex)..<end])
      let rest = text[text.index(after: end)...]
      if rest.isEmpty {
        port = defaultPort
      } else {
        guard rest.hasPrefix(":"), let value = UInt16(rest.dropFirst()), value > 0 else { return nil }
        port = value
      }
    } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
      guard let value = UInt16(text[text.index(after: colon)...]), value > 0 else { return nil }
      host = String(text[..<colon])
      port = value
    } else {
      // More than one colon without brackets is a bare IPv6 address.
      host = text
      port = defaultPort
    }
    guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
  }

  init(host: String, port: UInt16) {
    self.host = host
    self.port = port
  }

  var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

  /// Which route to try first: the local network is faster, then a tailnet name, then its IP.
  var routeRank: Int {
    if let ip = RemoteIP(host) {
      if ip.isTailscale { return 2 }
      return ip.isLocalNetwork ? 0 : 3
    }
    if host.hasSuffix(".local") { return 0 }
    return host.hasSuffix(".ts.net") ? 1 : 3
  }
}

/// `atelier-pair://<host>:<port>?id=<serverID>&s=<secret>&a=<other addresses>`, what a QR code
/// carries: everything a client needs to find a server and pair with it once.
nonisolated struct RemotePairingLink: Hashable, Identifiable, Sendable {
  static let scheme = "atelier-pair"

  var id: String { text }

  /// The first is the one in the link's host; the rest go in `a`.
  var addresses: [RemoteAddress]
  var serverID: UUID
  var secret: String

  init(addresses: [RemoteAddress], serverID: UUID, secret: String) {
    self.addresses = addresses
    self.serverID = serverID
    self.secret = secret
  }

  init?(_ text: String) {
    guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          components.scheme == Self.scheme, let rawHost = components.host, !rawHost.isEmpty
    else { return nil }
    let items = components.queryItems ?? []
    func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
    guard let id = item("id").flatMap(UUID.init(uuidString:)),
          let secret = item("s").flatMap(RemotePairing.normalizedCode)
    else { return nil }
    let port = components.port.flatMap { UInt16(exactly: $0) } ?? RemoteProtocol.defaultPort
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let others = (item("a") ?? "").split(separator: ",").compactMap { RemoteAddress(String($0), defaultPort: port) }
    self.init(addresses: [RemoteAddress(host: host, port: port)] + others, serverID: id, secret: secret)
  }

  var text: String {
    guard let first = addresses.first else { return "" }
    var link = "\(Self.scheme)://\(first)?id=\(serverID.uuidString)&s=\(secret)"
    let others = addresses.dropFirst().map(\.description)
    if !others.isEmpty { link += "&a=\(others.joined(separator: ","))" }
    return link
  }
}

/// The codes and keys of pairing a device with a server.
///
/// TLS-PSK has no forward secrecy, and a 50-bit code could be searched offline by someone who
/// recorded the handshake. So the device key doesn't travel under the code's key alone: the two
/// sides also do a Curve25519 exchange inside the connection, which someone who only recorded it
/// and cracks the code later can't undo. The code still stops an active attacker, who has to guess
/// it live, within its two minutes and few attempts.
nonisolated enum RemotePairing {
  /// Crockford base32: no I, L, O or U, so a typed code can't be misread.
  static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
  static let codeLength = 10
  static let codeLifetime: TimeInterval = 120
  /// A code is abandoned after this many tries, spaced at least `attemptSpacing` apart.
  static let maxAttempts = 5
  static let attemptSpacing: TimeInterval = 1

  /// A new code, from the system's cryptographic random source.
  static func newCode() -> String {
    var generator = SystemRandomNumberGenerator()
    return String((0..<codeLength).map { _ in alphabet.randomElement(using: &generator)! })
  }

  /// `text` as a code, read the way Crockford base32 says: any case, O as 0, I and L as 1, with
  /// spaces and hyphens ignored. Nil if it isn't one.
  static func normalizedCode(_ text: String) -> String? {
    var code = ""
    for character in text.uppercased() {
      switch character {
      case " ", "-": continue
      case "O": code.append("0")
      case "I", "L": code.append("1")
      default:
        guard alphabet.contains(character) else { return nil }
        code.append(character)
      }
    }
    return code.count == codeLength ? code : nil
  }

  /// The TLS pre-shared key while pairing with `code`.
  static func pairingKey(code: String) -> Data {
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data("atelier-pair-psk-v1".utf8),
      info: Data(), outputByteCount: 32)
    return key.withUnsafeBytes { Data($0) }
  }

  static func newDeviceKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

  /// Shows that the holder of `key` is `deviceID`. It's only ever sent inside that key's TLS.
  static func proof(key: Data, deviceID: UUID, purpose: String) -> Data {
    let message = Data("atelier-\(purpose)-v1|\(deviceID.uuidString)".utf8)
    return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
  }

  static func isValidProof(_ proof: Data, key: Data, deviceID: UUID, purpose: String) -> Bool {
    let message = Data("atelier-\(purpose)-v1|\(deviceID.uuidString)".utf8)
    return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: key))
  }

  private static func sealingKey(
    _ privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Data, code: String
  ) throws -> SymmetricKey {
    let shared = try privateKey.sharedSecretFromKeyAgreement(
      with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
    return shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: pairingKey(code: code), sharedInfo: Data("atelier-device-key-v1".utf8),
      outputByteCount: 32)
  }

  /// The server's half: `deviceKey` sealed for the client whose public key is `clientKey`.
  static func seal(deviceKey: Data, clientKey: Data, code: String) throws -> (publicKey: Data, sealed: Data) {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    let key = try sealingKey(privateKey, peer: clientKey, code: code)
    let sealed = try ChaChaPoly.seal(deviceKey, using: key).combined
    return (privateKey.publicKey.rawRepresentation, sealed)
  }

  /// The client's half.
  static func open(
    sealed: Data, serverKey: Data, privateKey: Curve25519.KeyAgreement.PrivateKey, code: String
  ) throws -> Data {
    let key = try sealingKey(privateKey, peer: serverKey, code: code)
    return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
  }
}
