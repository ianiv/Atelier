#if os(macOS)
import CryptoKit
import Foundation
import Network
import Security
import X509

/// A throwaway certificate authority, an intermediate it signed and a server certificate the
/// intermediate signed, made in memory for the HTTPS checks and unit tests: the server gets the
/// identity with the intermediate in its chain, the client trusts only the root (`authority`), so a
/// connection that succeeds shows the server sends the intermediate. Never offered to users (they
/// bring their own or use Tailscale's); nothing touches the Keychain.
nonisolated struct AutomationTestCertificate: @unchecked Sendable {
  let authority: SecCertificate
  let intermediate: SecCertificate
  let identity: AgentTLSIdentity
  /// The leaf's key, then its certificate and the intermediate, as PEM: the order Tailscale's
  /// `type=pair` gives them.
  let pemPair: String

  /// A leaf for `hosts` (IP addresses or DNS names), valid for an hour.
  init(hosts: [String], lifetime: TimeInterval = 3600) throws {
    let now = Date()
    let rootKey = P256.Signing.PrivateKey()
    let rootName = try DistinguishedName { CommonName("Atelier Test Root CA") }
    let root = try Certificate(
      version: .v3, serialNumber: .init(), publicKey: .init(rootKey.publicKey), notValidBefore: now - 60, notValidAfter: now + lifetime,
      issuer: rootName, subject: rootName, signatureAlgorithm: .ecdsaWithSHA256,
      extensions: try Certificate.Extensions {
        Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 1))
        Critical(KeyUsage(keyCertSign: true))
      }, issuerPrivateKey: .init(rootKey))
    let intermediateKey = P256.Signing.PrivateKey()
    let intermediateName = try DistinguishedName { CommonName("Atelier Test Intermediate CA") }
    let intermediate = try Certificate(
      version: .v3, serialNumber: .init(), publicKey: .init(intermediateKey.publicKey), notValidBefore: now - 60,
      notValidAfter: now + lifetime, issuer: rootName, subject: intermediateName, signatureAlgorithm: .ecdsaWithSHA256,
      extensions: try Certificate.Extensions {
        Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
        Critical(KeyUsage(keyCertSign: true))
      }, issuerPrivateKey: .init(rootKey))
    let leafKey = P256.Signing.PrivateKey()
    let names: [GeneralName] = hosts.map { host in
      if let v4 = IPv4Address(host) { return .ipAddress(.init(contentBytes: ArraySlice(v4.rawValue))) }
      if let v6 = IPv6Address(host) { return .ipAddress(.init(contentBytes: ArraySlice(v6.rawValue))) }
      return .dnsName(host)
    }
    let leaf = try Certificate(
      version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey), notValidBefore: now - 60, notValidAfter: now + lifetime,
      issuer: intermediateName, subject: try DistinguishedName { CommonName(hosts.first ?? "atelier-test") },
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: try Certificate.Extensions {
        Critical(BasicConstraints.notCertificateAuthority)
        Critical(KeyUsage(digitalSignature: true))
        try ExtendedKeyUsage([.serverAuth])
        SubjectAlternativeNames(names)
      }, issuerPrivateKey: .init(intermediateKey))
    func secCertificate(_ certificate: Certificate) throws -> SecCertificate {
      guard let made = SecCertificateCreateWithData(nil, Data(try certificate.serializeAsPEM().derBytes) as CFData) else {
        throw AgentTLSIdentity.Failure.noCertificate
      }
      return made
    }
    authority = try secCertificate(root)
    self.intermediate = try secCertificate(intermediate)
    identity = try AgentTLSIdentity(certificate: try secCertificate(leaf), intermediates: [self.intermediate], key: leafKey)
    pemPair = leafKey.pemRepresentation + "\n" + (try leaf.serializeAsPEM().pemString) + "\n"
      + (try intermediate.serializeAsPEM().pemString) + "\n"
  }
}

/// A URLSession delegate that trusts only `anchor`: the server must show a certificate it signed,
/// for the host asked for.
final nonisolated class AutomationAnchoredTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
  private let anchor: SecCertificate?

  /// nil trusts nothing beyond the system's roots, as an ordinary client would.
  init(anchor: SecCertificate?) {
    self.anchor = anchor
  }

  func urlSession(
    _: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust, let anchor
    else { return completionHandler(.performDefaultHandling, nil) }
    SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    guard SecTrustEvaluateWithError(trust, nil) else { return completionHandler(.cancelAuthenticationChallenge, nil) }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}
#endif
