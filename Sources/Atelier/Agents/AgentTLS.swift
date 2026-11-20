#if os(macOS)
import CryptoKit
import Foundation
import Network
import Security

/// Settings → Agents → Encryption: whether other devices reach the MCP server over HTTPS, and with
/// which certificate. With either certificate the network port takes no plain HTTP at all: the
/// server's own port answers this Mac only, and HTTPS is on the next port (an imported
/// certificate) or on the tailnet's 443 (Tailscale's).
nonisolated enum AgentEncryption: String, CaseIterable, Identifiable, Sendable {
  case none, tailscale, certificate

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: "None"
    case .tailscale: "Tailscale certificate"
    case .certificate: "Imported certificate"
    }
  }
}

/// A certificate and its private key, ready for the server's TLS: made from an imported .p12 or
/// from the PEM pair Tailscale hands out. Nothing here goes in the Keychain. The key stays in
/// memory, so an ad hoc signed rebuild is never asked about a key it doesn't own.
nonisolated struct AgentTLSIdentity: @unchecked Sendable {
  // SecIdentity and SecCertificate are immutable CF objects, safe to share between threads.
  let identity: SecIdentity
  /// The leaf first, then any intermediates, as the server sends them.
  let chain: [SecCertificate]

  enum Failure: LocalizedError, Equatable {
    case wrongPassword, noIdentity, unreadable(OSStatus), noCertificate, noKey, keyMismatch

    var errorDescription: String? {
      switch self {
      case .wrongPassword: "The password is wrong."
      case .noIdentity: "The file has no certificate with its private key."
      case .unreadable(let status): "Couldn't read the certificate (\(status))."
      case .noCertificate: "No certificate came back."
      case .noKey: "No P-256 private key came back."
      case .keyMismatch: "The private key doesn't match the certificate."
      }
    }
  }

  init(identity: SecIdentity, chain: [SecCertificate]) {
    self.identity = identity
    self.chain = chain
  }

  /// A .p12 (PKCS #12) file, read into memory only (`kSecImportToMemoryOnly`): the file itself is
  /// what's kept, in the Keychain as a password item (`AgentCertificateStore`).
  init(pkcs12 data: Data, password: String) throws {
    var items: CFArray?
    let options: [CFString: Any] = [kSecImportExportPassphrase: password, kSecImportToMemoryOnly: true]
    let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
    if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure { throw Failure.wrongPassword }
    guard status == errSecSuccess else { throw Failure.unreadable(status) }
    guard let first = (items as? [[String: Any]])?.first(where: { $0[kSecImportItemIdentity as String] != nil }),
      let value = first[kSecImportItemIdentity as String]
    else { throw Failure.noIdentity }
    let identity = value as! SecIdentity
    var leaf: SecCertificate?
    SecIdentityCopyCertificate(identity, &leaf)
    guard let leaf else { throw Failure.noIdentity }
    // The chain the file carries, leaf first; a root in it is left in (clients ignore it).
    let carried = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
    let rest = carried.filter { SecCertificateCopyData($0) as Data != SecCertificateCopyData(leaf) as Data }
    self.init(identity: identity, chain: [leaf] + rest)
  }

  /// Tailscale's `type=pair` answer, or any PEM text with a P-256 private key and its certificate
  /// chain (leaf first), in either order.
  init(pem text: String) throws {
    let blocks = Self.pemBlocks(text)
    let certificates = blocks.filter { $0.label == "CERTIFICATE" }.compactMap {
      SecCertificateCreateWithData(nil, $0.der as CFData)
    }
    guard let leaf = certificates.first else { throw Failure.noCertificate }
    guard let keyBlock = blocks.first(where: { $0.label.hasSuffix("PRIVATE KEY") }),
      let key = Self.p256Key(label: keyBlock.label, der: keyBlock.der)
    else { throw Failure.noKey }
    try self.init(certificate: leaf, intermediates: Array(certificates.dropFirst()), key: key)
  }

  /// A certificate and its key, joined in memory with `SecIdentityCreate` (no Keychain lookup).
  init(certificate: SecCertificate, intermediates: [SecCertificate] = [], key: P256.Signing.PrivateKey) throws {
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
    guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil) else {
      throw Failure.noKey
    }
    guard let identity = SecIdentityCreate(nil, certificate, secKey) else { throw Failure.keyMismatch }
    self.init(identity: identity, chain: [certificate] + intermediates)
  }

  private static func p256Key(label: String, der: Data) -> P256.Signing.PrivateKey? {
    let pem = "-----BEGIN \(label)-----\n\(der.base64EncodedString(options: .lineLength64Characters))\n-----END \(label)-----"
    return try? P256.Signing.PrivateKey(pemRepresentation: pem)
  }

  struct PEMBlock: Equatable {
    var label: String
    var der: Data
  }

  /// The `-----BEGIN X-----` … `-----END X-----` blocks in `text`, decoded.
  static func pemBlocks(_ text: String) -> [PEMBlock] {
    var blocks: [PEMBlock] = []
    var label: String?
    var body = ""
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----") {
        label = String(line.dropFirst(11).dropLast(5))
        body = ""
      } else if line.hasPrefix("-----END "), let current = label {
        if let der = Data(base64Encoded: body) { blocks.append(PEMBlock(label: current, der: der)) }
        label = nil
      } else if label != nil, !line.contains(":") {
        body += line
      }
    }
    return blocks
  }

  var leaf: SecCertificate { chain[0] }

  /// What Network.framework's TLS takes, with the intermediates the server sends after the leaf.
  var secIdentity: sec_identity_t? {
    sec_identity_create_with_certificates(identity, chain as CFArray)
  }

  /// The leaf's SHA-256 fingerprint, as browsers and `openssl x509 -fingerprint -sha256` show it.
  var fingerprint: String { Self.fingerprint(of: SecCertificateCopyData(leaf) as Data) }

  static func fingerprint(of der: Data) -> String {
    SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
  }

  var expires: Date? { SecCertificateCopyNotValidAfterDate(leaf) as Date? }

  /// The leaf's common name, or what Security says it's for.
  var name: String { (SecCertificateCopySubjectSummary(leaf) as String?) ?? "Certificate" }
}

/// The imported .p12 and its password, kept in the Keychain (memory in scripted runs) next to
/// the token, and read back into memory each time the server starts.
nonisolated struct AgentCertificateStore: Sendable {
  static let fileAccount = "mcpCertificate"
  static let passwordAccount = "mcpCertificatePassword"
  let secrets: any RemoteSecretStore

  func load() -> AgentTLSIdentity? {
    guard let data = secrets.load(Self.fileAccount), !data.isEmpty else { return nil }
    let password = secrets.load(Self.passwordAccount).map { String(decoding: $0, as: UTF8.self) } ?? ""
    return try? AgentTLSIdentity(pkcs12: data, password: password)
  }

  /// Checks the file opens with `password` before keeping it.
  func save(pkcs12 data: Data, password: String) throws -> AgentTLSIdentity {
    let identity = try AgentTLSIdentity(pkcs12: data, password: password)
    secrets.save(data, account: Self.fileAccount)
    secrets.save(Data(password.utf8), account: Self.passwordAccount)
    return identity
  }

  func remove() {
    secrets.save(nil, account: Self.fileAccount)
    secrets.save(nil, account: Self.passwordAccount)
  }
}
#endif
