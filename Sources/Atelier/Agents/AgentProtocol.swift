#if os(macOS)
import Foundation

/// Which MCP revision a request speaks, and the rules that differ between them, kept pure so the
/// tests can pin every case.
///
/// The server is dual-era (base protocol 2026-07-28, Versioning: Backward Compatibility): a legacy
/// client (2025-11-25 and earlier) opens with `initialize` and is served as before; a modern one
/// (2026-07-28) sends its version and capabilities in every request's `_meta` and mirrors the
/// version, method and name into headers (Streamable HTTP: Request Metadata), which are checked
/// against the body. Neither era keeps any state on the server.
nonisolated enum AgentProtocol {
  static let modernVersions = ["2026-07-28"]
  static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
  /// Newest first, as `server/discover`'s `supportedVersions` and -32022's `supported` list them.
  static let allVersions = modernVersions + legacyVersions

  static let versionKey = "io.modelcontextprotocol/protocolVersion"
  static let clientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
  static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
  static let skillsExtension = "io.modelcontextprotocol/skills"

  /// Header names as the listener gives them (lowercased).
  static let versionHeader = "mcp-protocol-version"
  static let methodHeader = "mcp-method"
  static let nameHeader = "mcp-name"

  /// JSON-RPC codes the base protocol defines beyond JSON-RPC's own.
  static let headerMismatch = -32020
  static let unsupportedVersion = -32022

  enum Era: Equatable {
    /// Served as 2025: `version` is the one the request named, if any.
    case legacy(version: String?)
    case modern(version: String)

    var isModern: Bool {
      if case .modern = self { return true }
      return false
    }
  }

  /// A request refused before it's dispatched: the HTTP status and the JSON-RPC error.
  struct ProtocolError: Error, Equatable {
    var httpStatus: Int
    var code: Int
    var message: String
    /// -32022's `data`: what the server supports and what was asked for.
    var supported: [String]?
    var requested: String?

    var data: [String: Any]? {
      guard let supported else { return nil }
      var data: [String: Any] = ["supported": supported]
      if let requested { data["requested"] = requested }
      return data
    }

    static func mismatch(_ message: String) -> ProtocolError {
      ProtocolError(httpStatus: 400, code: AgentProtocol.headerMismatch, message: "Header mismatch: \(message)")
    }
  }

  /// The methods whose `params` value a modern request also sends as `Mcp-Name`.
  static let namedMethods: [String: String] = ["tools/call": "name", "resources/read": "uri", "prompts/get": "name"]

  /// Results a modern client may cache (Caching): they carry `ttlMs` and `cacheScope`.
  static let cacheableMethods: Set<String> = [
    "server/discover", "tools/list", "resources/list", "resources/read", "resources/templates/list",
    "resources/directory/read", "skills/list", "skills/get",
  ]

  /// How long a modern client may keep a result: the server's own description and tools change
  /// only with an update, skills whenever the user edits one.
  static func ttlMs(for method: String) -> Int? {
    guard cacheableMethods.contains(method) else { return nil }
    return method == "server/discover" || method == "tools/list" ? 3_600_000 : 60_000
  }

  /// Which era a request is, or why it's refused. Lenient where the spec leaves room: a request
  /// with no version anywhere is legacy (2025-03-26 clients sent no header), and a legacy
  /// version in either place keeps it legacy, as long as nothing names 2026-07-28.
  ///
  /// Modern validation runs in the spec's order: an unknown version (-32022), then the mirrored
  /// headers (-32020, Streamable HTTP: Server Validation), then the required `_meta` (-32602).
  static func classify(method: String, params: [String: Any], headers: [String: String]) -> Result<Era, ProtocolError> {
    let meta = params["_meta"] as? [String: Any]
    let metaValue = meta?[versionKey]
    if metaValue != nil, !(metaValue is String) {
      return .failure(ProtocolError(httpStatus: 400, code: -32602, message: "_meta[\"\(versionKey)\"] must be a string."))
    }
    let metaVersion = metaValue as? String
    let rawHeader = headers[versionHeader]
    if method == "initialize" {
      return .success(.legacy(version: params["protocolVersion"] as? String))
    }
    for version in [rawHeader, metaVersion].compactMap(\.self) where !allVersions.contains(version) {
      return .failure(
        ProtocolError(
          httpStatus: 400, code: unsupportedVersion, message: "Unsupported protocol version", supported: allVersions,
          requested: version))
    }
    let namesModern = [rawHeader, metaVersion].contains { $0.map(modernVersions.contains) ?? false }
    let namesLegacy = [rawHeader, metaVersion].contains { $0.map(legacyVersions.contains) ?? false }
    let isModern = namesModern || (method == "server/discover" && !namesLegacy)
    guard isModern else { return .success(.legacy(version: metaVersion ?? rawHeader)) }

    // Every header is checked as the listener got it: a value with characters a header can't
    // carry is malformed, whatever it would have matched.
    guard let rawHeader else { return .failure(.mismatch("MCP-Protocol-Version header is missing.")) }
    guard let headerVersion = plainHeaderValue(rawHeader) else { return .failure(.mismatch("MCP-Protocol-Version header is malformed.")) }
    guard let metaVersion else {
      return .failure(ProtocolError(httpStatus: 400, code: -32602, message: "params._meta must carry \(versionKey)."))
    }
    guard headerVersion == metaVersion else {
      return .failure(.mismatch("MCP-Protocol-Version header value '\(headerVersion)' does not match body value '\(metaVersion)'."))
    }
    guard let rawMethod = headers[methodHeader] else { return .failure(.mismatch("Mcp-Method header is missing.")) }
    guard let headerMethod = plainHeaderValue(rawMethod), headerMethod == method else {
      return .failure(.mismatch("Mcp-Method header does not match the request's method."))
    }
    if let field = namedMethods[method] {
      guard let rawName = headers[nameHeader] else { return .failure(.mismatch("Mcp-Name header is missing.")) }
      guard let name = decodeHeaderValue(rawName) else { return .failure(.mismatch("Mcp-Name header is malformed.")) }
      guard let body = params[field] as? String, body == name else {
        return .failure(.mismatch("Mcp-Name header does not match params.\(field)."))
      }
    }
    guard meta?[clientCapabilitiesKey] is [String: Any] else {
      return .failure(ProtocolError(httpStatus: 400, code: -32602, message: "params._meta must carry \(clientCapabilitiesKey)."))
    }
    return .success(.modern(version: metaVersion))
  }

  /// A header value as sent, if every character is one a header may carry plainly (RFC 9110
  /// field values: visible ASCII, space and tab).
  static func plainHeaderValue(_ raw: String) -> String? {
    raw.unicodeScalars.allSatisfy { $0 == "\t" || (0x20...0x7E).contains($0.value) } ? raw : nil
  }

  /// `Mcp-Name`'s value: plain ASCII, or `=?base64?…?=` around the UTF-8 bytes base64-encoded
  /// (Streamable HTTP: Value Encoding; the markers are case-sensitive). Nil when the header
  /// itself has characters a header can't carry, or the base64 isn't valid UTF-8. Decoded text
  /// may hold anything (that's why it was encoded); it only has to match the body.
  static func decodeHeaderValue(_ raw: String) -> String? {
    guard let plain = plainHeaderValue(raw) else { return nil }
    let prefix = "=?base64?"
    let suffix = "?="
    guard plain.hasPrefix(prefix), plain.hasSuffix(suffix), plain.count >= prefix.count + suffix.count else { return plain }
    let encoded = plain.dropFirst(prefix.count).dropLast(suffix.count)
    guard let data = Data(base64Encoded: String(encoded)), let text = String(data: data, encoding: .utf8) else { return nil }
    return text
  }

  /// What `initialize` and `server/discover` declare. Skills ride on Resources, so declaring the
  /// extension means declaring `resources` too (Skills: Capability Negotiation).
  static func capabilities() -> [String: Any] {
    [
      "tools": ["listChanged": false],
      "resources": [String: Any](),
      "extensions": [skillsExtension: ["directoryRead": true]],
    ]
  }

  /// Wraps a result for its era: modern results say they're complete, carry the server's name in
  /// `_meta` and, when cacheable, how long to keep them (always private: every result depends on
  /// this user's library). Legacy results are left as 2025 shaped them.
  static func envelope(_ result: [String: Any], era: Era, method: String, serverInfo: [String: Any]) -> [String: Any] {
    guard era.isModern else { return result }
    var result = result
    result["resultType"] = "complete"
    var meta = result["_meta"] as? [String: Any] ?? [:]
    meta[serverInfoKey] = serverInfo
    result["_meta"] = meta
    if let ttl = ttlMs(for: method) {
      result["ttlMs"] = ttl
      result["cacheScope"] = "private"
    }
    return result
  }
}
#endif
