import Darwin
import Foundation
import Network

/// An IP address's bytes, with IPv4-mapped IPv6 read as the IPv4 address it is.
nonisolated enum RemoteIP: Hashable, Sendable {
  case v4([UInt8])
  case v6([UInt8])

  /// A zone (`%en0`) is ignored. Nil if `text` isn't an IP address.
  init?(_ text: String) {
    let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
    if let ipv4 = IPv4Address(address) {
      self = .v4(Array(ipv4.rawValue))
    } else if let ipv6 = IPv6Address(address) {
      self.init(ipv6)
    } else {
      return nil
    }
  }

  init(_ address: IPv6Address) {
    if let mapped = address.asIPv4 {
      self = .v4(Array(mapped.rawValue))
    } else {
      self = .v6(Array(address.rawValue))
    }
  }

  /// A peer's address; nil for a name, which a connection's peer never is.
  init?(_ host: NWEndpoint.Host) {
    switch host {
    case .ipv4(let address): self = .v4(Array(address.rawValue))
    case .ipv6(let address): self.init(address)
    default: return nil
    }
  }

  /// Tailscale's ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
  var isTailscale: Bool {
    switch self {
    case .v4(let bytes): bytes[0] == 100 && bytes[1] & 0xC0 == 64
    case .v6(let bytes): Array(bytes.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
    }
  }

  /// Private, link-local and loopback ranges.
  var isLocalNetwork: Bool {
    switch self {
    case .v4(let bytes):
      bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 172 && bytes[1] & 0xF0 == 16)
        || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    case .v6(let bytes):
      bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
        || bytes == [UInt8](repeating: 0, count: 15) + [1]
    }
  }
}

/// Settings ▸ Compute ▸ Accept connections from. On top of the keys every connection needs.
nonisolated enum RemoteAddressFilter: String, CaseIterable, Identifiable, Sendable {
  case tailscale, tailscaleAndLocal, any

  var id: String { rawValue }

  var title: String {
    switch self {
    case .tailscale: "Tailscale only"
    case .tailscaleAndLocal: "Tailscale and local network"
    case .any: "Any network"
    }
  }

  func allows(_ ip: RemoteIP?) -> Bool {
    switch self {
    case .any: true
    case .tailscale: ip?.isTailscale ?? false
    case .tailscaleAndLocal: ip.map { $0.isTailscale || $0.isLocalNetwork } ?? false
    }
  }

  func allows(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return self == .any }
    return allows(RemoteIP(host))
  }
}

/// This device's own addresses, read from its network interfaces. Nothing calls Tailscale's API,
/// so Headscale and other WireGuard setups in the same ranges work the same way.
nonisolated enum RemoteNetworkInfo {
  struct Interface: Hashable, Sendable {
    var name: String
    var address: String
    var ip: RemoteIP
  }

  static func interfaces() -> [Interface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var found: [Interface] = []
    var next = head
    while let current = next {
      defer { next = current.pointee.ifa_next }
      let flags = Int32(current.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let socket = current.pointee.ifa_addr else { continue }
      let family = Int32(socket.pointee.sa_family)
      guard family == AF_INET || family == AF_INET6 else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      guard let ip = RemoteIP(address) else { continue }
      found.append(
        Interface(
          name: String(cString: current.pointee.ifa_name), address: address.split(separator: "%").first.map(String.init) ?? address,
          ip: ip))
    }
    return found
  }

  /// The address of a Tailscale interface, IPv4 first.
  static func tailscaleAddress(in interfaces: [Interface] = interfaces()) -> String? {
    let addresses = interfaces.filter(\.ip.isTailscale)
    return (addresses.first { if case .v4 = $0.ip { true } else { false } } ?? addresses.first)?.address
  }

  /// The MagicDNS name of `address`, by reverse lookup; slow or nil when the tailnet's DNS isn't
  /// in use, so call it off the main actor.
  @concurrent static func reverseName(of address: String) async -> String? {
    var storage = sockaddr_storage()
    var length: socklen_t = 0
    let parsed = withUnsafeMutablePointer(to: &storage) { pointer -> Bool in
      pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4 in
        if inet_pton(AF_INET, address, &ipv4.pointee.sin_addr) == 1 {
          ipv4.pointee.sin_family = sa_family_t(AF_INET)
          ipv4.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
          length = socklen_t(MemoryLayout<sockaddr_in>.size)
          return true
        }
        return false
      }
    }
    guard parsed else { return nil }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let result = withUnsafePointer(to: &storage) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
      }
    }
    guard result == 0 else { return nil }
    let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return name.hasSuffix(".") ? String(name.dropLast()) : name
  }

  /// What goes in a pairing link, best route for a client that's elsewhere first: the tailnet name
  /// and IP, then the local network's name and addresses.
  static func pairingAddresses(port: UInt16, tailscaleName: String?) -> [RemoteAddress] {
    let interfaces = interfaces()
    var hosts: [String] = []
    if let tailscaleName { hosts.append(tailscaleName) }
    hosts += interfaces.filter(\.ip.isTailscale).map(\.address)
    let hostName = ProcessInfo.processInfo.hostName
    if hostName.hasSuffix(".local") { hosts.append(hostName) }
    hosts += interfaces.filter { interface in
      guard case .v4 = interface.ip else { return false }
      return interface.ip.isLocalNetwork
    }.map(\.address)
    var seen = Set<String>()
    return hosts.filter { seen.insert($0).inserted }.map { RemoteAddress(host: $0, port: port) }
  }

  /// How a browsing client on the same network reaches this device: its address there. Not its host
  /// name, which the network may rename (a router's DHCP can make it vimeswifi.home).
  static var localNetworkHost: String {
    let local = interfaces().first { interface in
      guard case .v4 = interface.ip else { return false }
      return interface.ip.isLocalNetwork
    }
    return local?.address ?? ProcessInfo.processInfo.hostName
  }

  /// This device, as servers list it.
  static var deviceName: String {
    #if os(macOS)
      let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
      let name = ProcessInfo.processInfo.hostName
    #endif
    return String(name.prefix(RemoteProtocol.maxDeviceNameLength))
  }
}
