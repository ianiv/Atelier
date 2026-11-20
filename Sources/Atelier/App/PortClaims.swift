import Foundation
import Network
import Observation

/// The ports Atelier's own servers hold: the MCP server's plain port and its HTTPS (the local
/// network's, or the tailnet's 443), and Compute's (the same number on the local network and the
/// tailnet). Each counts only while its server is on.
///
/// The operating system can't be left to catch a clash between them: with HTTPS on, the MCP
/// server's plain port binds 127.0.0.1 and Compute binds every interface, both with endpoint reuse,
/// so the same port succeeds for both and connections go to whichever the system picks. So a port
/// is checked here before a server takes it, and a clash says whose port it is.
nonisolated struct PortClaims: Equatable, Sendable {
  enum Role: Sendable {
    case mcp, mcpHTTPS, compute
  }

  /// Where the MCP server's HTTPS goes.
  enum HTTPSPort: Equatable, Sendable {
    /// Two past the plain port, skipping every port Atelier claims (`automaticHTTPSPort`).
    case automatic
    /// Typed in Settings ▸ Agents ▸ Encryption ▸ HTTPS Port.
    case explicit(Int)
    /// Tailscale's certificate: the tailnet's 443, so clients name no port.
    case tailnet
  }

  static let validPorts = 1...65535
  static let invalidMessage = "Pick a port from 1 to 65535."
  static let tailnetHTTPSPort = 443

  private(set) var mcp: Int?
  private(set) var mcpHTTPS: Int?
  /// The HTTPS port is the automatic one: it moves out of the way of the others rather than
  /// refusing them.
  private(set) var mcpHTTPSIsAutomatic = false
  private(set) var compute: Int?

  /// The MCP server's plain port; nothing while it's off.
  mutating func claimMCP(isOn: Bool, port: Int) {
    mcp = isOn ? port : nil
  }

  /// The MCP server's HTTPS; nothing while it's off or serves none (`https` nil).
  mutating func claimMCPHTTPS(isOn: Bool, _ https: HTTPSPort?, plainPort: Int) {
    guard isOn, let https else {
      mcpHTTPS = nil
      mcpHTTPSIsAutomatic = false
      return
    }
    mcpHTTPS = httpsPort(https, plainPort: plainPort)
    mcpHTTPSIsAutomatic = https == .automatic
  }

  /// Compute's port, on the local network and the tailnet alike; nothing while it's off.
  mutating func claimCompute(isOn: Bool, port: Int) {
    compute = isOn && port != 0 ? port : nil
  }

  /// The port `https` resolves to with the plain port at `plainPort`: nil when automatic runs past
  /// 65535.
  func httpsPort(_ https: HTTPSPort, plainPort: Int) -> Int? {
    switch https {
    case .tailnet: Self.tailnetHTTPSPort
    case .explicit(let port): port
    case .automatic: automaticHTTPSPort(for: plainPort)
    }
  }

  /// Two past the MCP server's own port, since the one after it, 7863, is Compute's default; if
  /// that's a port Atelier claims (Compute moved there), the next one free.
  func automaticHTTPSPort(for plainPort: Int) -> Int? {
    Self.automaticHTTPSPort(for: plainPort, avoiding: Set([plainPort, compute].compactMap(\.self)))
  }

  /// The rule behind `automaticHTTPSPort`, for any set of taken ports. Nil past 65535.
  static func automaticHTTPSPort(for port: Int, avoiding taken: Set<Int>) -> Int? {
    guard port >= 1 else { return nil }
    var candidate = port + 2
    while taken.contains(candidate) { candidate += 1 }
    return candidate <= 65535 ? candidate : nil
  }

  /// Why `role` can't take `port`: out of range, or another of Atelier's servers holds it. An
  /// automatic HTTPS port never blocks anyone, since it moves.
  func conflict(port: Int, for role: Role) -> String? {
    guard Self.validPorts.contains(port) else { return Self.invalidMessage }
    if role != .mcp, mcp == port { return Self.message(port: port, of: .mcp) }
    if role != .mcpHTTPS, mcpHTTPS == port, !mcpHTTPSIsAutomatic { return Self.message(port: port, of: .mcpHTTPS) }
    if role != .compute, compute == port { return Self.message(port: port, of: .compute) }
    return nil
  }

  /// "Port 7863 is Compute's (Settings ▸ Compute).": whose it is and where to change it.
  static func message(port: Int, of role: Role) -> String {
    switch role {
    case .mcp: "Port \(port) is the MCP server's (Settings ▸ Agents)."
    case .mcpHTTPS: "Port \(port) is the MCP server's HTTPS (Settings ▸ Agents ▸ Encryption)."
    case .compute: "Port \(port) is Compute's (Settings ▸ Compute)."
    }
  }
}

/// `PortClaims` shared by the MCP server and Compute's, which each keep their own claims in it and
/// read the other's. The MCP server watches it so automatic HTTPS can follow Compute's port.
@MainActor
@Observable
final class PortRegistry {
  private(set) var claims = PortClaims()
  @ObservationIgnored private var observers: [UUID: () -> Void] = [:]

  func update(_ change: (inout PortClaims) -> Void) {
    var updated = claims
    change(&updated)
    guard updated != claims else { return }
    claims = updated
    observers.values.forEach { $0() }
  }

  /// Adds `handler`, told after every change; pass what it returns to `removeObserver`.
  @discardableResult func observe(_ handler: @escaping () -> Void) -> UUID {
    let token = UUID()
    observers[token] = handler
    return token
  }

  func removeObserver(_ token: UUID) { observers[token] = nil }
}

/// Why a listener couldn't start, as the person reads it.
nonisolated struct ListenFailure: Error, Sendable, Equatable {
  var message: String
  /// The port itself was the trouble (in use, not allowed, or another of Atelier's servers'), so
  /// Try Again can help once it's free.
  var isPortError: Bool

  init(_ message: String, isPortError: Bool) {
    self.message = message
    self.isPortError = isPortError
  }

  /// A clash with another of Atelier's servers, found before listening.
  static func clash(_ message: String) -> ListenFailure { ListenFailure(message, isPortError: true) }

  /// What a listener's error on `port` means. A busy port names whoever holds it, which looks
  /// through every process's sockets (`PortOwner`), so call this off the main actor.
  static func describe(_ error: NWError, port: Int) -> ListenFailure {
    guard case .posix(let code) = error else { return ListenFailure(error.localizedDescription, isPortError: false) }
    switch code {
    case .EADDRINUSE:
      return ListenFailure(inUse(port: port), isPortError: true)
    case .EACCES, .EPERM:
      #if os(macOS)
        return ListenFailure("macOS didn't allow port \(port).", isPortError: true)
      #else
        return ListenFailure("iPadOS didn't allow port \(port).", isPortError: true)
      #endif
    default:
      return ListenFailure(error.localizedDescription, isPortError: false)
    }
  }

  static func inUse(port: Int) -> String {
    #if os(macOS)
      if let owner = UInt16(exactly: port).flatMap(PortOwner.lookup(port:)) {
        if owner.pid == getpid() { return "Another of Atelier's servers is using port \(port)." }
        if let name = owner.name { return "\(name) is using port \(port)." }
      }
    #endif
    return "Another app or system service is using port \(port)."
  }

  /// `describe`, run off the main actor.
  @concurrent static func describeOffMain(_ error: NWError, port: Int) async -> ListenFailure {
    describe(error, port: port)
  }
}
