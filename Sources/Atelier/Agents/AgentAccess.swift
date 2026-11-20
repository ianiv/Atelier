#if os(macOS)
import Foundation
import Network
import Security
import Synchronization

/// Settings → Agents → Access: who can reach the MCP server. On the local network the server
/// listens on every interface but answers only the addresses Compute's "Tailscale and local
/// network" filter allows (loopback is one of them), so the same ranges mean the same thing in
/// both places.
nonisolated enum AgentAccess: String, CaseIterable, Identifiable, Sendable {
  case thisMac, localNetwork

  var id: String { rawValue }

  var title: String {
    switch self {
    case .thisMac: "This Mac only"
    case .localNetwork: "Local network"
    }
  }

  /// The peers a local-network server accepts, checked before a connection is started.
  static let networkFilter = RemoteAddressFilter.tailscaleAndLocal
}

/// What a tool call knows about who made it. Set for the whole call with `ToolContext.$current`
/// (a task local, so the jobs a call starts and the image reads it does off the main actor see it
/// too) rather than passed to every tool and helper that reads a file.
nonisolated struct ToolContext: Sendable {
  /// The client isn't on this Mac: its file paths name files on another device, and the paths
  /// Atelier writes are no use to it.
  var isRemote = false

  @TaskLocal static var current = ToolContext()
}

/// The pure decisions behind the server's access rules, kept apart from the networking so the
/// tests can check them.
nonisolated enum AgentAuth {
  private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", "::1"]

  /// 127.0.0.0/8 and ::1. An IPv4-mapped peer (a dual-stack listener reports 127.0.0.1 as
  /// ::ffff:127.0.0.1) is read as IPv4 by `RemoteIP`.
  static func isLoopback(_ ip: RemoteIP?) -> Bool {
    switch ip {
    case .v4(let bytes): bytes[0] == 127
    case .v6(let bytes): bytes == [UInt8](repeating: 0, count: 15) + [1]
    case nil: false
    }
  }

  /// A Host header naming this Mac (any port).
  static func isLoopback(host: String?) -> Bool {
    guard let host else { return false }
    return loopbackHosts.contains(hostName(ofHostHeader: host).lowercased())
  }

  static func isLoopback(origin: String) -> Bool {
    guard let host = URLComponents(string: origin)?.host else { return false }
    return loopbackHosts.contains(host.lowercased())
  }

  private static func hostName(ofHostHeader host: String) -> String {
    host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]" : String(host.prefix { $0 != ":" })
  }

  /// The names a page on this Mac's own server could have as its Origin: its addresses, its
  /// .local name and the embedded Tailscale node's name (`tailnetName`, served over HTTPS).
  /// Brackets come off IPv6 addresses, as `URLComponents.host` gives them.
  static func ownHosts(addresses: [String], hostName: String, tailnetName: String? = nil) -> Set<String> {
    var hosts = Set(addresses.map { $0.lowercased() })
    let name = hostName.lowercased()
    if name.hasSuffix(".local") { hosts.insert(name) }
    if let tailnetName, !tailnetName.isEmpty { hosts.insert(tailnetName.lowercased()) }
    return hosts
  }

  /// A request from another device that carries an Origin is a web page; only a page from this
  /// Mac may call in, so a site the user browses elsewhere can't drive the server from their
  /// browser. Clients that aren't browsers send no Origin.
  /// The page must also be on the server's own port (a scheme's default when the Origin names
  /// none): another web server on this Mac is another site.
  static func allowsRemote(origin: String?, ownHosts: Set<String>, port: Int) -> Bool {
    guard let origin else { return true }
    guard let components = URLComponents(string: origin), let host = components.host?.lowercased() else { return false }
    let defaultPort: Int? =
      switch components.scheme?.lowercased() {
      case "http": 80
      case "https": 443
      default: nil
      }
    guard (components.port ?? defaultPort) == port else { return false }
    let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    return loopbackHosts.contains(host) || ownHosts.contains(bare)
  }

  /// What the listener's access rules are now, as the HTTP server reads them off the main actor.
  struct Gate: Sendable, Equatable {
    /// Access is Local network: other devices may connect at all.
    var networkOpen = false
    var requireToken = true
    var token: String?
  }

  /// Decided as soon as a request's headers are in, before its body is read, so a device
  /// without the token can't make the server take in a large body: the status to answer with,
  /// or nil to read on. A listener from before Access went back to This Mac only can still hand
  /// over a connection, which is refused here (403) rather than let in without a token.
  static func earlyRefusal(peer: RemoteIP?, authorization: String?, gate: Gate) -> Int? {
    if isLoopback(peer) { return nil }
    guard gate.networkOpen else { return 403 }
    return isAuthorized(peerIsLoopback: false, requireToken: gate.requireToken, authorization: authorization, token: gate.token) ? nil : 401
  }

  /// Whether a request gets in. Clients on this Mac never need the token (a correct one is still
  /// fine); other devices need it unless Require Token is off.
  static func isAuthorized(peerIsLoopback: Bool, requireToken: Bool, authorization: String?, token: String?) -> Bool {
    if peerIsLoopback || !requireToken { return true }
    guard let token, !token.isEmpty, let given = bearer(authorization) else { return false }
    return constantTimeEquals(given, token)
  }

  /// The token in an `Authorization: Bearer …` header.
  static func bearer(_ header: String?) -> String? {
    guard let header else { return nil }
    let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
    guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
    return parts[1].trimmingCharacters(in: .whitespaces)
  }

  /// Compares every byte whatever the first difference, so the time a wrong guess takes says
  /// nothing about how much of it was right.
  static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let left = Array(a.utf8)
    let right = Array(b.utf8)
    var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
    for index in 0..<max(left.count, right.count) {
      let x = index < left.count ? left[index] : 0
      let y = index < right.count ? right[index] : 0
      difference |= x ^ y
    }
    return difference == 0
  }

  /// 32 random bytes, base64url without padding: safe in a header, a shell argument and JSON.
  static func makeToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// `http://host:port/mcp`, with an IPv6 address in brackets.
  static func endpoint(host: String, port: Int) -> String {
    endpoint(scheme: "http", host: host, port: port)
  }

  /// `scheme://host:port/mcp`, leaving out the scheme's default port (`https://name.ts.net/mcp`).
  static func endpoint(scheme: String, host: String, port: Int) -> String {
    let defaultPort = scheme == "https" ? 443 : 80
    let address = host.contains(":") ? "[\(host)]" : host
    return "\(scheme)://\(address)\(port == defaultPort ? "" : ":\(port)")/mcp"
  }

  /// The port the local network's HTTPS takes with an imported certificate: two past the
  /// server's own (which then answers this Mac only), since the one after it, 7863, is Compute's
  /// default. If that's a port in `taken` (Compute set elsewhere), the next free one after it.
  /// Nil past 65535.
  static func httpsPort(for port: Int, avoiding taken: Set<Int> = []) -> Int? {
    guard port >= 1 else { return nil }
    var candidate = port + 2
    while taken.contains(candidate) { candidate += 1 }
    return candidate <= 65535 ? candidate : nil
  }

  /// Where the embedded Tailscale node takes the MCP server's HTTPS: the default, so clients name
  /// no port.
  static let tailnetHTTPSPort = 443
}

/// `AgentAuth.Gate` behind a lock, shared by the server (which sets it) and its listener's
/// connections (which read it off the main actor).
final nonisolated class AgentGateBox: Sendable {
  let state = Mutex(AgentAuth.Gate())
}

/// Clients on other devices can't use this Mac's files: a path they send names a file on their
/// own device (or, worse, one here they shouldn't read), and a path written here is no use to
/// them. They send images as data: URLs and get results inline.
nonisolated enum AgentPathGuard {
  static let pathMessage = "File paths are only for agents on this Mac; send a data: URL."
  static let saveToMessage = "File paths are only for agents on this Mac; images come back inline."
  static let fileMessage = "File paths are only for agents on this Mac."

  /// Arguments that are always paths, with what to say instead: a LUT or grain profile can't come
  /// as a data: URL, but the built-in LUTs and the profile library are there.
  static let pathArguments: [(key: String, message: String)] = [
    ("save_to", saveToMessage),
    ("audio", fileMessage),
    ("lut_path", "File paths are only for agents on this Mac; use a built-in `lut`."),
    ("profile_path", "File paths are only for agents on this Mac; use a `profile` from list_grain_profiles."),
    ("save_profile_to", fileMessage),
  ]

  /// Result keys that hold a path on this Mac, left out of what another device gets.
  static let pathResultKeys = ["path", "saved_profile", "folder"]

  /// The arguments that are always paths, checked before a call does anything, so a run isn't
  /// made only to fail at the end. Image arguments can be data: URLs and are checked as they're
  /// read (`checkImageSource`).
  static func refusal(for arguments: [String: Any], isRemote: Bool) -> String? {
    guard isRemote else { return nil }
    for (key, message) in pathArguments {
      if let value = arguments[key] as? String, value.isEmpty { continue }
      if arguments[key] != nil, !(arguments[key] is NSNull) { return message }
    }
    return nil
  }

  /// A job's finished result for another device: the path keys out of its structured content,
  /// and its text without the paths they held (generate's "Saved to … and /path.").
  static func strippingPaths(_ result: [String: Any]) -> [String: Any] {
    guard var structured = result["structuredContent"] as? [String: Any] else { return result }
    let paths = pathResultKeys.compactMap { structured[$0] as? String }.filter { !$0.isEmpty }
    for key in pathResultKeys { structured[key] = nil }
    var result = result
    result["structuredContent"] = structured
    if let content = result["content"] as? [[String: Any]] {
      result["content"] = content.map { item in
        guard var text = item["text"] as? String else { return item }
        for path in paths {
          text = text.replacingOccurrences(of: " and \(path)", with: "").replacingOccurrences(of: path, with: "(a file on the Mac running Atelier)")
        }
        var item = item
        item["text"] = text
        return item
      }
    }
    return result
  }

  /// Takes the paths out of a message for another device (an error quoting a file a client on
  /// this Mac named, say): an absolute or `~` path, up to the end of its sentence or a closing
  /// quote, becomes "…". Then any home folder left (a path cut short at a comma) goes too.
  static func redactingPaths(_ text: String, home: String = NSHomeDirectory()) -> String {
    let range = NSRange(text.startIndex..., in: text)
    var redacted = pathPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "…")
    if home.count > 1 { redacted = redacted.replacingOccurrences(of: home, with: "…") }
    return redacted
  }

  // A slash starts a path only after a space, quote or bracket and before a name, so "1/2" and
  // "http://" are left alone.
  private static let pathPattern = try! NSRegularExpression(
    pattern: #"(?<=^|[\s“"'(])~?/[^\s/“”"'][^\n“”"']*?(?=\.?$|\.?\n|[.,;:]\s|[”"')])"#, options: [.anchorsMatchLines])

  /// Whether `source`, an image argument, may be read for this caller.
  static func allowsImageSource(_ source: String, isRemote: Bool) -> Bool {
    !isRemote || source.hasPrefix("data:")
  }
}

/// The token clients on other devices send, kept in the Keychain (memory in scripted runs) and
/// made the first time it's needed.
nonisolated struct AgentTokenStore: Sendable {
  static let account = "mcpToken"
  let secrets: any RemoteSecretStore

  func load() -> String? {
    secrets.load(Self.account).map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// The token, made and saved if there isn't one.
  func ensure() -> String {
    if let token = load() { return token }
    return regenerate()
  }

  @discardableResult func regenerate() -> String {
    let token = AgentAuth.makeToken()
    secrets.save(Data(token.utf8), account: Self.account)
    return token
  }
}

/// An MCP client Settings → Agents shows setup for.
nonisolated enum AgentClient: String, CaseIterable, Identifiable, Sendable {
  case claudeCode, codex, gemini, cursor, vsCode

  var id: String { rawValue }

  var title: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    case .gemini: "Gemini CLI"
    case .cursor: "Cursor"
    case .vsCode: "VS Code"
    }
  }

  /// A Terminal command, or for Cursor (and Codex with a token) the entry for its config file.
  /// With `token`, the client sends it as `Authorization: Bearer …`. Codex's CLI has no flag for
  /// a fixed header, so it gets the config.toml entry its docs give (`http_headers`).
  func setup(_ endpoint: String, token: String? = nil) -> String {
    let header = token.map { "Authorization: Bearer \($0)" }
    switch self {
    case .claudeCode:
      return "claude mcp add --transport http atelier \(endpoint)" + (header.map { " --header \"\($0)\"" } ?? "")
    case .codex:
      guard let token else { return "codex mcp add atelier --url \(endpoint)" }
      return "[mcp_servers.atelier]\nurl = \"\(endpoint)\"\nhttp_headers = { \"Authorization\" = \"Bearer \(token)\" }"
    case .gemini:
      return "gemini mcp add --transport http " + (header.map { "--header \"\($0)\" " } ?? "") + "atelier \(endpoint)"
    case .cursor:
      let headers = token.map { ", \"headers\": { \"Authorization\": \"Bearer \($0)\" }" } ?? ""
      return "{\n  \"mcpServers\": {\n    \"atelier\": { \"url\": \"\(endpoint)\"\(headers) }\n  }\n}"
    case .vsCode:
      let headers = token.map { ",\"headers\":{\"Authorization\":\"Bearer \($0)\"}" } ?? ""
      return "code --add-mcp '{\"name\":\"atelier\",\"type\":\"http\",\"url\":\"\(endpoint)\"\(headers)}'"
    }
  }

  func instructions(withToken: Bool = false) -> String {
    switch self {
    case .claudeCode:
      "Run this in Terminal once. Add --scope user to use it in every folder, not just the current one."
    case .codex:
      withToken
        ? "Add this to ~/.codex/config.toml, for the Codex CLI and app."
        : "Run this in Terminal once. It's added to ~/.codex/config.toml, for the Codex CLI and app."
    case .gemini:
      "Run this in Terminal once, in your project's folder. Add -s user to use it in every folder."
    case .cursor:
      "Add this to ~/.cursor/mcp.json (or .cursor/mcp.json in a project), merging it with any servers already there."
    case .vsCode:
      "Run this in Terminal once. Copilot's agent mode can then use Atelier's tools."
    }
  }
}
#endif
