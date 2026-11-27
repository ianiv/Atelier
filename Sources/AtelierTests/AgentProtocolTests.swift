@testable import Atelier
import Foundation
import Testing

@Suite(.tags(.smoke))
struct AgentProtocolTests {
  private static var meta: [String: Any] {
    [
      AgentProtocol.versionKey: "2026-07-28", AgentProtocol.clientCapabilitiesKey: [String: Any](),
      "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
    ]
  }

  private static func modern(_ method: String, name: String? = nil) -> [String: String] {
    var headers = [AgentProtocol.versionHeader: "2026-07-28", AgentProtocol.methodHeader: method]
    if let name { headers[AgentProtocol.nameHeader] = name }
    return headers
  }

  private func classify(_ method: String, _ params: [String: Any] = [:], _ headers: [String: String] = [:]) -> Result<AgentProtocol.Era, AgentProtocol.ProtocolError> {
    AgentProtocol.classify(method: method, params: params, headers: headers)
  }

  private func failure(_ result: Result<AgentProtocol.Era, AgentProtocol.ProtocolError>) -> AgentProtocol.ProtocolError? {
    if case .failure(let error) = result { return error }
    return nil
  }

  @Test func legacyRequests() {
    #expect(classify("initialize", ["protocolVersion": "2025-11-25"]) == .success(.legacy(version: "2025-11-25")))
    #expect(classify("initialize", ["protocolVersion": "2026-07-28"], Self.modern("initialize")) == .success(.legacy(version: "2026-07-28")), "initialize is always legacy")
    #expect(classify("tools/list") == .success(.legacy(version: nil)), "no version anywhere: 2025-03-26 clients sent no header")
    #expect(classify("tools/list", [:], [AgentProtocol.versionHeader: "2025-06-18"]) == .success(.legacy(version: "2025-06-18")))
    #expect(classify("tools/list", ["_meta": [AgentProtocol.versionKey: "2025-11-25"]]) == .success(.legacy(version: "2025-11-25")))
    #expect(classify("server/discover", [:], [AgentProtocol.versionHeader: "2025-11-25"]) == .success(.legacy(version: "2025-11-25")))
    #expect(classify("tools/call", ["name": "x"]) == .success(.legacy(version: nil)), "legacy needs no Mcp-Name")
  }

  @Test func modernRequests() {
    #expect(classify("tools/list", ["_meta": Self.meta], Self.modern("tools/list")) == .success(.modern(version: "2026-07-28")))
    #expect(classify("server/discover", ["_meta": Self.meta], Self.modern("server/discover")) == .success(.modern(version: "2026-07-28")))
    #expect(classify("tools/call", ["name": "list_models", "_meta": Self.meta], Self.modern("tools/call", name: "list_models")) == .success(.modern(version: "2026-07-28")))
    let uri = "skill://pdf-processing/SKILL.md"
    #expect(classify("resources/read", ["uri": uri, "_meta": Self.meta], Self.modern("resources/read", name: uri)) == .success(.modern(version: "2026-07-28")))
  }

  @Test func base64Name() {
    let name = "héllo tool"
    let encoded = "=?base64?\(Data(name.utf8).base64EncodedString())?="
    #expect(AgentProtocol.decodeHeaderValue(encoded) == name)
    #expect(classify("tools/call", ["name": name, "_meta": Self.meta], Self.modern("tools/call", name: encoded)) == .success(.modern(version: "2026-07-28")))
    #expect(AgentProtocol.decodeHeaderValue("plain") == "plain")
    #expect(AgentProtocol.decodeHeaderValue("=?base64?!!!?=") == nil, "not base64")
    #expect(AgentProtocol.decodeHeaderValue("h\u{e9}") == nil, "non-ASCII must be encoded")
    #expect(AgentProtocol.decodeHeaderValue("a\nb") == nil, "control characters")
    #expect(AgentProtocol.decodeHeaderValue("=?BASE64?aGk=?=") == "=?BASE64?aGk=?=", "the markers are case-sensitive")
  }

  @Test func headerMismatches() {
    // _meta names 2026-07-28 but the header is missing.
    #expect(failure(classify("tools/list", ["_meta": Self.meta]))?.code == -32020)
    #expect(failure(classify("tools/list", ["_meta": Self.meta]))?.httpStatus == 400)
    // The header names a legacy version, _meta the modern one.
    var legacyHeader = Self.modern("tools/list")
    legacyHeader[AgentProtocol.versionHeader] = "2025-11-25"
    #expect(failure(classify("tools/list", ["_meta": Self.meta], legacyHeader))?.code == -32020)
    // The header names the modern version, _meta a legacy one.
    #expect(failure(classify("tools/list", ["_meta": [AgentProtocol.versionKey: "2025-11-25", AgentProtocol.clientCapabilitiesKey: [:]]], Self.modern("tools/list")))?.code == -32020)
    // Wrong or missing Mcp-Method.
    #expect(failure(classify("tools/list", ["_meta": Self.meta], Self.modern("resources/list")))?.code == -32020)
    #expect(failure(classify("tools/list", ["_meta": Self.meta], [AgentProtocol.versionHeader: "2026-07-28"]))?.code == -32020)
    // Mcp-Name missing, wrong, or malformed.
    #expect(failure(classify("tools/call", ["name": "list_models", "_meta": Self.meta], Self.modern("tools/call")))?.code == -32020)
    #expect(failure(classify("tools/call", ["name": "list_models", "_meta": Self.meta], Self.modern("tools/call", name: "generate")))?.code == -32020)
    #expect(failure(classify("resources/read", ["uri": "skill://a/SKILL.md", "_meta": Self.meta], Self.modern("resources/read")))?.code == -32020)
    #expect(failure(classify("tools/call", ["name": "a", "_meta": Self.meta], Self.modern("tools/call", name: "=?base64?***?=")))?.code == -32020)
    // server/discover with nothing at all is modern, so its headers are missing.
    #expect(failure(classify("server/discover"))?.code == -32020)
  }

  @Test func unsupportedVersion() throws {
    let error = try #require(failure(classify("tools/list", ["_meta": [AgentProtocol.versionKey: "1900-01-01", AgentProtocol.clientCapabilitiesKey: [:]]], Self.modern("tools/list"))))
    #expect(error.code == -32022 && error.httpStatus == 400)
    #expect(error.supported == ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"])
    #expect(error.requested == "1900-01-01", "the header is valid, so _meta's version is the one reported")
    let header = try #require(failure(classify("tools/list", [:], [AgentProtocol.versionHeader: "2024-11-05"])))
    #expect(header.code == -32022 && header.requested == "2024-11-05", "an unknown version in the header alone")
    #expect((header.data?["supported"] as? [String])?.first == "2026-07-28")
  }

  @Test func missingCapabilities() {
    let params: [String: Any] = ["_meta": [AgentProtocol.versionKey: "2026-07-28"]]
    let error = failure(classify("tools/list", params, Self.modern("tools/list")))
    #expect(error?.code == -32602 && error?.httpStatus == 400)
    let notObject: [String: Any] = ["_meta": [AgentProtocol.versionKey: "2026-07-28", AgentProtocol.clientCapabilitiesKey: "x"]]
    #expect(failure(classify("tools/list", notObject, Self.modern("tools/list")))?.code == -32602)
    // The header with no _meta version at all.
    #expect(failure(classify("tools/list", [:], Self.modern("tools/list")))?.code == -32602)
    #expect(failure(classify("tools/list", ["_meta": [AgentProtocol.versionKey: 5]], [:]))?.code == -32602, "a version that isn't a string")
  }

  @Test func envelopes() {
    let info: [String: Any] = ["name": "atelier", "version": "1"]
    let modern = AgentProtocol.envelope(["tools": []], era: .modern(version: "2026-07-28"), method: "tools/list", serverInfo: info)
    #expect(modern["resultType"] as? String == "complete")
    #expect(modern["ttlMs"] as? Int == 3_600_000)
    #expect(modern["cacheScope"] as? String == "private")
    #expect(((modern["_meta"] as? [String: Any])?[AgentProtocol.serverInfoKey] as? [String: Any])?["name"] as? String == "atelier")
    let skills = AgentProtocol.envelope(["skills": []], era: .modern(version: "2026-07-28"), method: "skills/list", serverInfo: info)
    #expect(skills["ttlMs"] as? Int == 60_000)
    let call = AgentProtocol.envelope(["content": []], era: .modern(version: "2026-07-28"), method: "tools/call", serverInfo: info)
    #expect(call["resultType"] as? String == "complete")
    #expect(call["ttlMs"] == nil && call["cacheScope"] == nil, "tools/call isn't cacheable")
    let legacy = AgentProtocol.envelope(["skills": []], era: .legacy(version: nil), method: "skills/list", serverInfo: info)
    #expect(legacy["resultType"] == nil && legacy["ttlMs"] == nil && legacy["_meta"] == nil)
  }

  @Test func capabilitiesDeclareSkills() {
    for modern in [false, true] {
      let capabilities = AgentProtocol.capabilities(modern: modern)
      #expect(capabilities["resources"] is [String: Any])
      let extensions = capabilities["extensions"] as? [String: Any]
      #expect((extensions?[AgentProtocol.skillsExtension] as? [String: Any])?["directoryRead"] as? Bool == true)
    }
  }

  @Test func capabilitiesDeclareTasksOnlyWhenModern() {
    let modern = AgentProtocol.capabilities(modern: true)["extensions"] as? [String: Any]
    #expect(modern?[AgentProtocol.tasksExtension] is [String: Any])
    let legacy = AgentProtocol.capabilities(modern: false)["extensions"] as? [String: Any]
    #expect(legacy?[AgentProtocol.tasksExtension] == nil, "the extension isn't defined for 2025")
    #expect(AgentProtocol.capabilities(modern: false)["tasks"] == nil, "no 2025 experimental tasks")
  }

  @Test func tasksMethodsNeedMcpName() {
    let id = "job-0f8fad5b-d9cb-469f-a165-70867728950e"
    for method in ["tasks/get", "tasks/update", "tasks/cancel"] {
      let params: [String: Any] = ["taskId": id, "_meta": Self.meta]
      #expect(classify(method, params, Self.modern(method, name: id)) == .success(.modern(version: "2026-07-28")))
      #expect(failure(classify(method, params, Self.modern(method)))?.code == AgentProtocol.headerMismatch, "\(method) without Mcp-Name")
      #expect(failure(classify(method, params, Self.modern(method)))?.httpStatus == 400)
      #expect(failure(classify(method, params, Self.modern(method, name: "job-other")))?.code == AgentProtocol.headerMismatch, "mismatched")
      let encoded = "=?base64?\(Data(id.utf8).base64EncodedString())?="
      #expect(classify(method, params, Self.modern(method, name: encoded)) == .success(.modern(version: "2026-07-28")), "base64")
      #expect(failure(classify(method, ["_meta": Self.meta], Self.modern(method, name: id)))?.code == AgentProtocol.headerMismatch, "no taskId in the body")
    }
  }

  @Test func declaresTasks() {
    let modern = AgentProtocol.Era.modern(version: "2026-07-28")
    func params(_ extensions: Any?) -> [String: Any] {
      var capabilities: [String: Any] = [:]
      if let extensions { capabilities["extensions"] = extensions }
      return ["_meta": [AgentProtocol.versionKey: "2026-07-28", AgentProtocol.clientCapabilitiesKey: capabilities]]
    }
    let declared: [String: Any] = [AgentProtocol.tasksExtension: [String: Any]()]
    #expect(AgentProtocol.declaresTasks(era: modern, params: params(declared)))
    #expect(!AgentProtocol.declaresTasks(era: .legacy(version: "2025-11-25"), params: params(declared)), "legacy era never")
    #expect(!AgentProtocol.declaresTasks(era: modern, params: params(nil)))
    #expect(!AgentProtocol.declaresTasks(era: modern, params: params([AgentProtocol.skillsExtension: [String: Any]()])))
    #expect(!AgentProtocol.declaresTasks(era: modern, params: params([AgentProtocol.tasksExtension: true])), "must be an object")
    #expect(!AgentProtocol.declaresTasks(era: modern, params: ["task": ["ttl": 1000]]), "a 2025 params.task doesn't count")
  }

  @Test func envelopeKeepsTaskResults() {
    let info: [String: Any] = ["name": "atelier", "version": "1"]
    let modern = AgentProtocol.Era.modern(version: "2026-07-28")
    let created: [String: Any] = ["resultType": "task", "taskId": "job-x", "status": "working", "ttlMs": NSNull()]
    let call = AgentProtocol.envelope(created, era: modern, method: "tools/call", serverInfo: info)
    #expect(call["resultType"] as? String == "task")
    #expect(call["ttlMs"] is NSNull, "the Task's own ttlMs, not a cache one")
    #expect(call["cacheScope"] == nil)
    // Only a tools/call answer may be a task.
    let other = AgentProtocol.envelope(["resultType": "task"], era: modern, method: "tools/list", serverInfo: info)
    #expect(other["resultType"] as? String == "complete")
    for method in ["tasks/get", "tasks/update", "tasks/cancel"] {
      #expect(!AgentProtocol.cacheableMethods.contains(method))
      let task = AgentProtocol.envelope(["taskId": "job-x", "ttlMs": 5000], era: modern, method: method, serverInfo: info)
      #expect(task["resultType"] as? String == "complete")
      #expect(task["ttlMs"] as? Int == 5000 && task["cacheScope"] == nil, "\(method) results are never cached")
    }
  }
}
