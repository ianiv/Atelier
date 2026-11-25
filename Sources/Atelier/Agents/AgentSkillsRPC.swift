#if os(macOS)
import Foundation

/// The Skills extension's methods and the Resources methods its files are read with
/// (`io.modelcontextprotocol/skills`): `skills/list`, `skills/get`, `resources/list`,
/// `resources/templates/list`, `resources/read` and `resources/directory/read`. Results are the
/// bare result objects; the server wraps them for the request's era (`AgentProtocol.envelope`).
///
/// Every answer comes from the store's current scan, which checks each folder's fingerprint
/// first, so the digests listed always describe what `resources/read` returns. Clients only ever
/// see `skill://` URIs, never where the files are.
@MainActor
struct SkillsRPC {
  nonisolated struct RPCError: Error, Equatable {
    var code: Int
    var message: String
  }

  let store: SkillStore

  static let methods: Set<String> = [
    "skills/list", "skills/get", "resources/list", "resources/templates/list", "resources/read", "resources/directory/read",
  ]

  /// `isRemote`: the caller is on another device, so an internal error's text loses any path.
  func handle(_ method: String, params: [String: Any], isRemote: Bool) async -> Result<[String: Any], RPCError> {
    do {
      switch method {
      case "skills/list":
        // Every skill fits one page (the catalog is a folder's worth), so the cursor is ignored.
        return .success(["skills": await store.current().map(Self.entry)])
      case "skills/get":
        let uri = try Self.uri(params)
        _ = await store.current()
        guard let (skill, path) = store.served(uri: uri), path == SkillScanner.skillFileName else {
          throw RPCError(code: -32602, message: "No skill is served at \(uri)")
        }
        return .success(["skill": Self.entry(skill)])
      case "resources/list":
        return .success(["resources": await store.current().flatMap(Self.resources)])
      case "resources/templates/list":
        return .success(["resourceTemplates": [Any]()])
      case "resources/read":
        let uri = try Self.uri(params)
        guard let (file, data) = try await store.read(uri: uri) else {
          throw RPCError(code: -32602, message: "Resource not found: \(uri)")
        }
        var content: [String: Any] = ["uri": uri, "mimeType": file.mimeType]
        if let text = SkillScanner.text(data, mimeType: file.mimeType) {
          content["text"] = text
        } else {
          content["blob"] = data.base64EncodedString()
        }
        return .success(["contents": [content]])
      case "resources/directory/read":
        let uri = try Self.uri(params)
        _ = await store.current()
        guard let (skill, path) = store.served(uri: uri) else {
          throw RPCError(code: -32602, message: "No directory resource at \(uri)")
        }
        guard path.isEmpty || skill.directories.contains(path) else {
          let message = skill.file(path) != nil ? "\(uri) is not a directory resource" : "No directory resource at \(uri)"
          throw RPCError(code: -32602, message: message)
        }
        return .success(["resources": Self.children(of: path, in: skill)])
      default:
        return .failure(RPCError(code: -32601, message: "Method not found: \(method)"))
      }
    } catch let error as RPCError {
      return .failure(error)
    } catch {
      let message = isRemote ? AgentPathGuard.redactingPaths(error.localizedDescription) : error.localizedDescription
      return .failure(RPCError(code: -32603, message: message))
    }
  }

  private static func uri(_ params: [String: Any]) throws -> String {
    guard let uri = params["uri"] as? String, !uri.isEmpty else { throw RPCError(code: -32602, message: "params.uri is required.") }
    return uri
  }

  /// A `Skill` entry: SKILL.md's URI, its frontmatter as written, and every file's digest and size.
  static func entry(_ skill: Skill) -> [String: Any] {
    [
      "uri": skill.uri,
      "frontmatter": skill.frontmatter ?? [:],
      "resources": skill.files.map { ["uri": SkillURI.make(skill: skill.name, path: $0.relPath), "digest": $0.digest, "size": $0.size] },
    ]
  }

  /// A skill's files as Resources; SKILL.md named and described by its frontmatter (Skills:
  /// Resource Metadata).
  static func resources(_ skill: Skill) -> [[String: Any]] {
    skill.files.map { file in
      var resource: [String: Any] = [
        "uri": SkillURI.make(skill: skill.name, path: file.relPath), "name": (file.relPath as NSString).lastPathComponent,
        "mimeType": file.mimeType, "size": file.size,
      ]
      if file.relPath == SkillScanner.skillFileName {
        resource["name"] = skill.frontmatter?["name"] as? String ?? skill.name
        if let description = skill.summary { resource["description"] = description }
      }
      return resource
    }
  }

  /// The direct children of one of a skill's folders ("" for its top): files as Resources,
  /// folders as directory resources, without trailing slashes.
  static func children(of path: String, in skill: Skill) -> [[String: Any]] {
    let prefix = path.isEmpty ? "" : path + "/"
    func isChild(_ candidate: String) -> Bool {
      candidate.hasPrefix(prefix) && !candidate.dropFirst(prefix.count).contains("/") && candidate.count > prefix.count
    }
    let folders: [[String: Any]] = skill.directories.filter(isChild).sorted().map {
      ["uri": SkillURI.make(skill: skill.name, path: $0), "name": ($0 as NSString).lastPathComponent, "mimeType": "inode/directory"]
    }
    let files = resources(skill).filter { resource in
      guard let uri = resource["uri"] as? String, let (_, filePath) = SkillURI.parse(uri) else { return false }
      return isChild(filePath)
    }.map { resource in
      var resource = resource
      if let uri = resource["uri"] as? String, let (_, filePath) = SkillURI.parse(uri) { resource["name"] = (filePath as NSString).lastPathComponent }
      resource["description"] = nil
      return resource
    }
    return files + folders
  }
}
#endif
