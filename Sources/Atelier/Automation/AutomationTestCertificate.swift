#if os(macOS)
import CryptoKit
import Foundation
import Network
import Security
import X509

/// A throwaway certificate authority and a server certificate it signed, made in memory for the
/// HTTPS checks and unit tests: the server gets the identity, the client trusts only `authority`.
/// Never offered to users (they bring their own or use Tailscale's); nothing touches the Keychain.
nonisolated struct AutomationTestCertificate: @unchecked Sendable {
  let authority: SecCertificate
  let identity: AgentTLSIdentity
  /// The leaf's key and certificate as PEM, in the order Tailscale's `type=pair` gives them.
  let pemPair: String

  /// A leaf for `hosts` (IP addresses or DNS names), valid for an hour.
  init(hosts: [String], lifetime: TimeInterval = 3600) throws {
    let now = Date()
    let authorityKey = P256.Signing.PrivateKey()
    let authorityName = try DistinguishedName { CommonName("Atelier Test CA") }
    let authority = try Certificate(
      version: .v3, serialNumber: .init(), publicKey: .init(authorityKey.publicKey), notValidBefore: now - 60, notValidAfter: now + lifetime,
      issuer: authorityName, subject: authorityName, signatureAlgorithm: .ecdsaWithSHA256,
      extensions: try Certificate.Extensions {
        Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
        Critical(KeyUsage(keyCertSign: true))
      }, issuerPrivateKey: .init(authorityKey))
    let leafKey = P256.Signing.PrivateKey()
    let names: [GeneralName] = hosts.map { host in
      if let v4 = IPv4Address(host) { return .ipAddress(.init(contentBytes: ArraySlice(v4.rawValue))) }
      if let v6 = IPv6Address(host) { return .ipAddress(.init(contentBytes: ArraySlice(v6.rawValue))) }
      return .dnsName(host)
    }
    let leaf = try Certificate(
      version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey), notValidBefore: now - 60, notValidAfter: now + lifetime,
      issuer: authorityName, subject: try DistinguishedName { CommonName(hosts.first ?? "atelier-test") },
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: try Certificate.Extensions {
        Critical(BasicConstraints.notCertificateAuthority)
        Critical(KeyUsage(digitalSignature: true))
        try ExtendedKeyUsage([.serverAuth])
        SubjectAlternativeNames(names)
      }, issuerPrivateKey: .init(authorityKey))
    guard let authorityCertificate = SecCertificateCreateWithData(nil, Data(try authority.serializeAsPEM().derBytes) as CFData),
      let leafCertificate = SecCertificateCreateWithData(nil, Data(try leaf.serializeAsPEM().derBytes) as CFData)
    else { throw AgentTLSIdentity.Failure.noCertificate }
    self.authority = authorityCertificate
    identity = try AgentTLSIdentity(certificate: leafCertificate, key: leafKey)
    pemPair = leafKey.pemRepresentation + "\n" + (try leaf.serializeAsPEM().pemString) + "\n"
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
