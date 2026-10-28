#if os(macOS)
import Foundation
import Observation
import SwiftUI

/// Atelier's MCP server: agents such as Claude Code connect over Streamable HTTP on the loopback
/// interface (`http://127.0.0.1:<port>/mcp`) and generate with the app's own engine, so there's
/// never a second engine competing for the GPU. Off until turned on in Settings → Agents.
///
/// Requests are JSON-RPC over POST. A `tools/call` whose client accepts an event stream gets one,
/// with progress notifications while it generates; anything else gets a plain JSON response.
/// There are no sessions and no server-to-client requests, so GET (the optional standalone
/// stream) is refused with 405, as the transport allows.
@MainActor
@Observable
final class AgentServer {
  static let defaultPort = 7862
  private static let enabledKey = "agentServer.enabled"
  private static let portKey = "agentServer.port"

  var isEnabled = UserDefaults.standard.bool(forKey: AgentServer.enabledKey) {
    didSet {
      UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
      restart()
    }
  }

  var port = UserDefaults.standard.object(forKey: AgentServer.portKey) as? Int ?? AgentServer.defaultPort {
    didSet {
      guard port != oldValue else { return }
      UserDefaults.standard.set(port, forKey: Self.portKey)
      restart()
    }
  }

  /// Why the server isn't listening although it's on.
  private(set) var listenError: String?
  private(set) var isListening = false
  let tools: AgentTools
  /// `--mcp` on the command line: on for this launch without changing the setting.
  private let forcedOn: Bool
  /// `--mcp PORT`: that port for this launch.
  private var forcedPort: Int?

  private var server: LoopbackHTTPServer?
  /// Running tool calls by JSON-RPC id, so `notifications/cancelled` can stop them.
  private var calls: [String: Task<Void, Never>] = [:]

  private var activePort: Int { forcedPort ?? port }
  var endpoint: String { "http://127.0.0.1:\(activePort)/mcp" }

  private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
  private static let instructions = """
    Atelier generates images on this Mac with local diffusion models (the Draw Things engine). \
    Call list_models first to pick a model, then generate. Images are saved to the user's \
    current Atelier project and written as PNG files; one image is generated at a time, so a \
    call may wait for a run already in progress. Larger models can take minutes per image. \
    To work on the same Create screen as the user, read it with get_create_screen, change its \
    prompt and settings with set_create_screen, and generate it with generate and \
    use_app_settings (no prompt). To see an image, including ones the user generated, use \
    get_image (the canvas by default) and list_history.
    """

  init(create: CreateModel, presets: PresetStore) {
    tools = AgentTools(create: create, presets: presets)
    let args = CommandLine.arguments
    forcedOn = args.contains("--mcp")
    if let index = args.firstIndex(of: "--mcp"), index + 1 < args.count, let port = Int(args[index + 1]) {
      forcedPort = port
    }
    // Scripted checks leave the user's server (and its port) alone unless asked with `--mcp`.
    if Automation.isRequested, !forcedOn { return }
    restart()
  }

  private func restart() {
    server?.stop()
    server = nil
    isListening = false
    listenError = nil
    guard isEnabled || forcedOn else { return }
    guard let port = UInt16(exactly: activePort), port > 0 else {
      listenError = "Pick a port from 1 to 65535."
      return
    }
    let server = LoopbackHTTPServer(port: port) { [weak self] request, responder in
      Task { @MainActor in self?.handle(request, responder) }
    }
    self.server = server
    server.start { [weak self] error in
      Task { @MainActor in
        guard let self, self.server === server else { return }
        self.isListening = error == nil
        self.listenError = error
        if let error { print("Agents: MCP server on port \(port) failed: \(error)") }
        else { print("Agents: MCP server listening on \(self.endpoint)") }
      }
    }
  }

  // MARK: - HTTP

  private func handle(_ request: LoopbackHTTPServer.Request, _ responder: LoopbackHTTPServer.Responder) {
    let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
    guard path == "/mcp" || path == "/mcp/" else {
      return responder.send(status: 404, body: Data())
    }
    // Only pages and clients on this Mac: a web page elsewhere could otherwise reach the
    // loopback port through DNS rebinding.
    guard Self.isLoopback(host: request.headers["host"]),
      request.headers["origin"].map({ Self.isLoopback(origin: $0) }) ?? true
    else {
      return responder.send(status: 403, body: Data())
    }
    guard request.method == "POST" else {
      return responder.send(status: 405, headers: ["Allow": "POST"], body: Data())
    }
    guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
      return respond(error: -32700, "Expected one JSON-RPC message.", id: NSNull(), via: responder)
    }
    guard let id = message["id"], let method = message["method"] as? String else {
      // A notification, or a response (the server sends no requests, so it's ignored).
      if message["method"] as? String == "notifications/cancelled",
        let params = message["params"] as? [String: Any], let id = params["requestId"]
      {
        calls[Self.key(id)]?.cancel()
      }
      return responder.send(status: 202, body: Data())
    }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
      let requested = params["protocolVersion"] as? String ?? ""
      respond(
        result: [
          "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": [
            "name": "atelier", "title": "Atelier",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
          ],
          "instructions": Self.instructions,
        ], id: id, via: responder)
    case "ping":
      respond(result: [:], id: id, via: responder)
    case "tools/list":
      respond(result: ["tools": AgentTools.definitions], id: id, via: responder)
    case "tools/call":
      callTool(params, id: id, streaming: request.headers["accept"]?.contains("text/event-stream") == true, via: responder)
    default:
      respond(error: -32601, "Method not found: \(method)", id: id, via: responder)
    }
  }

  private func callTool(
    _ params: [String: Any], id: Any, streaming: Bool, via responder: LoopbackHTTPServer.Responder
  ) {
    guard let name = params["name"] as? String else {
      return respond(error: -32602, "tools/call needs a tool name.", id: id, via: responder)
    }
    guard AgentTools.definitions.contains(where: { $0["name"] as? String == name }) else {
      return respond(error: -32602, "Unknown tool: \(name)", id: id, via: responder)
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    let progressToken = (params["_meta"] as? [String: Any])?["progressToken"]
    let key = Self.key(id)
    if streaming { responder.startEvents() }
    let task = Task { @MainActor [tools] in
      let keepAlive = streaming ? Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(15))
          responder.sendKeepAlive()
        }
      } : nil
      defer { keepAlive?.cancel() }
      var result: [String: Any]
      do {
        // MCP progress must only increase, and the steps restart at 0 between phases.
        var reached = 0
        var total: Int?
        result = try await tools.call(name, arguments: arguments) { progress in
          guard streaming, let progressToken else { return }
          reached = max(reached, progress.step)
          total = progress.total ?? total
          var params: [String: Any] = [
            "progressToken": progressToken, "progress": reached, "message": progress.message,
          ]
          if let total { params["total"] = total }
          Self.send(["jsonrpc": "2.0", "method": "notifications/progress", "params": params], streamingTo: responder)
        }
      } catch is CancellationError {
        result = ["content": [["type": "text", "text": "Cancelled."]], "isError": true]
      } catch {
        result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
      }
      calls[key] = nil
      let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
      if streaming {
        Self.send(response, streamingTo: responder)
        responder.finish()
      } else {
        Self.send(response, via: responder)
      }
    }
    calls[key] = task
    responder.onClientClose { task.cancel() }
  }

  private func respond(result: [String: Any], id: Any, via responder: LoopbackHTTPServer.Responder) {
    Self.send(["jsonrpc": "2.0", "id": id, "result": result], via: responder)
  }

  private func respond(error code: Int, _ message: String, id: Any, via responder: LoopbackHTTPServer.Responder) {
    Self.send(
      ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]], via: responder)
  }

  private static func send(_ message: [String: Any], via responder: LoopbackHTTPServer.Responder) {
    let data = (try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)) ?? Data()
    responder.send(status: 200, contentType: "application/json", body: data)
  }

  private static func send(_ message: [String: Any], streamingTo responder: LoopbackHTTPServer.Responder) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
    else { return }
    responder.sendEvent(data)
  }

  private static func key(_ id: Any) -> String { "\(id)" }

  private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", "::1"]

  /// A Host header naming this Mac (any port).
  private static func isLoopback(host: String?) -> Bool {
    guard let host else { return false }
    let name = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]" : String(host.prefix { $0 != ":" })
    return loopbackHosts.contains(name.lowercased())
  }

  private static func isLoopback(origin: String) -> Bool {
    guard let host = URLComponents(string: origin)?.host else { return false }
    return loopbackHosts.contains(host.lowercased())
  }
}

/// An MCP client Settings → Agents shows setup for.
enum AgentClient: String, CaseIterable, Identifiable {
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

  /// A Terminal command, or for Cursor the entry for its mcp.json.
  func setup(_ endpoint: String) -> String {
    switch self {
    case .claudeCode: "claude mcp add --transport http atelier \(endpoint)"
    case .codex: "codex mcp add atelier --url \(endpoint)"
    case .gemini: "gemini mcp add --transport http atelier \(endpoint)"
    case .cursor: "{\n  \"mcpServers\": {\n    \"atelier\": { \"url\": \"\(endpoint)\" }\n  }\n}"
    case .vsCode: "code --add-mcp '{\"name\":\"atelier\",\"type\":\"http\",\"url\":\"\(endpoint)\"}'"
    }
  }

  var instructions: String {
    switch self {
    case .claudeCode:
      "Run this in Terminal once. Add --scope user to use it in every folder, not just the current one."
    case .codex:
      "Run this in Terminal once. It's added to ~/.codex/config.toml, for the Codex CLI and app."
    case .gemini:
      "Run this in Terminal once, in your project's folder. Add -s user to use it in every folder."
    case .cursor:
      "Add this to ~/.cursor/mcp.json (or .cursor/mcp.json in a project), merging it with any servers already there."
    case .vsCode:
      "Run this in Terminal once. Copilot's agent mode can then use Atelier's tools."
    }
  }
}

/// Settings → Agents: turn the MCP server on, and how to connect an agent to it.
struct AgentSettingsView: View {
  @Environment(AgentServer.self) private var server
  @State private var portText = ""
  @AppStorage("agentClient") private var client = AgentClient.claudeCode

  var body: some View {
    @Bindable var server = server
    Form {
      Section {
        Toggle(isOn: $server.isEnabled) {
          Text("Let agents generate images")
          Text("Runs an MCP server that apps on this Mac, such as Claude Code, can use to list models and presets, read and change the Create screen, and generate images. Images are saved to the current project.")
        }
        LabeledContent("Port") {
          TextField("Port", text: $portText)
            .labelsHidden()
            .frame(width: 80)
            .onSubmit { applyPort() }
        }
        LabeledContent("Status") {
          if !server.isEnabled, !server.isListening {
            Text("Off").foregroundStyle(.secondary)
          } else if let error = server.listenError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
          } else if server.isListening {
            Text(server.tools.activity ?? "Listening at \(server.endpoint)")
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          } else {
            Text("Starting…").foregroundStyle(.secondary)
          }
        }
        if let last = server.tools.lastResult {
          LabeledContent("Last image", value: last)
        }
      } header: {
        Text("MCP Server")
      }
      Section {
        Picker("Agent", selection: $client) {
          ForEach(AgentClient.allCases) { Text($0.title).tag($0) }
        }
        Text(client.instructions)
          .foregroundStyle(.secondary)
        Text(client.setup(server.endpoint))
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
          Spacer()
          Button("Copy") {
            Clipboard.copy(client.setup(server.endpoint))
          }
        }
      } header: {
        Text("Connect an Agent")
      } footer: {
        Text("Atelier must be open with the server on while the agent works. Other MCP clients that speak Streamable HTTP can use the same address.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 600)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear { portText = String(server.port) }
  }

  private func applyPort() {
    if let port = Int(portText), (1...65535).contains(port) {
      server.port = port
    } else {
      portText = String(server.port)
    }
  }
}
#endif
