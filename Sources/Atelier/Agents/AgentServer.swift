#if os(macOS)
import Foundation
import Observation
import SwiftUI

/// Atelier's MCP server: agents such as Claude Code connect over Streamable HTTP on the loopback
/// interface (`http://127.0.0.1:<port>/mcp`) and generate with the app's own engine, so there's
/// never a second engine competing for the GPU. Off until turned on in Settings → Agents.
///
/// With Access set to Local network it also answers other devices on the local network or
/// tailnet (`AgentAccess.networkFilter`), which send a bearer token unless Require Token is off
/// and can't pass or get file paths (`AgentPathGuard`). Plain HTTP: there's no TLS.
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
  private static let accessKey = "agentServer.access"
  private static let requireTokenKey = "agentServer.requireToken"

  var isEnabled: Bool {
    didSet {
      defaults.set(isEnabled, forKey: Self.enabledKey)
      restart()
    }
  }

  var port: Int {
    didSet {
      guard port != oldValue else { return }
      defaults.set(port, forKey: Self.portKey)
      restart()
    }
  }

  /// Settings → Agents → Access. The listener is replaced, as for the port.
  var access: AgentAccess {
    didSet {
      guard access != oldValue else { return }
      defaults.set(access.rawValue, forKey: Self.accessKey)
      restart()
    }
  }

  /// Whether other devices must send the token. Checked per request, so changing it needs no
  /// restart.
  var requireToken: Bool {
    didSet {
      defaults.set(requireToken, forKey: Self.requireTokenKey)
      if requireToken, activeAccess == .localNetwork { ensureToken() }
    }
  }

  /// The token other devices send; nil until it's first needed. Compared with each request, so a
  /// new one takes effect at once.
  private(set) var token: String?
  /// The addresses other devices use, refreshed when the listener starts and Settings opens.
  private(set) var networkEndpoints: [String] = []

  /// Why the server isn't listening although it's on.
  private(set) var listenError: String?
  private(set) var isListening = false
  let tools: AgentTools
  /// `--mcp` on the command line: on for this launch without changing the setting.
  private let forcedOn: Bool
  /// `--mcp PORT`: that port for this launch.
  private var forcedPort: Int?
  /// `--mcp-network`: on the local network for this launch.
  private let forcedNetwork: Bool
  private let defaults: UserDefaults
  private let tokens: AgentTokenStore

  private var server: LoopbackHTTPServer?
  /// Running tool calls by JSON-RPC id, so `notifications/cancelled` can stop them.
  private var calls: [String: Task<Void, Never>] = [:]

  private var activePort: Int { forcedPort ?? port }
  var activeAccess: AgentAccess { forcedNetwork ? .localNetwork : access }
  var endpoint: String { AgentAuth.endpoint(host: "127.0.0.1", port: activePort) }
  /// Whether a client on another device has to send the token now.
  var networkNeedsToken: Bool { activeAccess == .localNetwork && requireToken }

  private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
  private static let instructions = """
    Atelier generates images on this Mac with local diffusion models (the Draw Things engine). \
    Call list_models first to pick a model, then generate. Images are saved to the user's \
    current Atelier project and written as PNG files; one image is generated at a time, so a \
    call may wait for a run already in progress. Larger models can take minutes per image. \
    To work on the same Create screen as the user, read it with get_create_screen, change its \
    prompt and settings with set_create_screen, and generate it with generate and \
    use_app_settings (no prompt). To see an image, including ones the user generated, use \
    get_image (the canvas by default) and list_history. For videos and other long runs, call \
    generate with background: true and check on the job_id with get_job, which waits up to \
    wait_seconds per call. \
    To redo part of an image (a small face, a hand), work zoomed in: on the canvas, \
    set_canvas_image, then find_faces or get_image to locate it, set_canvas_mask or auto_mask \
    and grow_canvas_mask to mask it, set_canvas_frame to zoom the frame onto it at a scale, \
    and generate with use_app_settings and use_canvas, which merges the result back into the \
    whole image. With a model that takes reference images (list_models), set_canvas_paint can \
    fill the mask with a flat color the prompt names and set_moodboard can add the picture to \
    take from (get_moodboard gives its Picture number). edit_image does the whole of that in \
    one call, as a job that leaves the Create screen exactly as the user has it: use it when \
    they are working there, or for a batch. After an edit, match_colors takes out a color \
    shift; after one made with paint, pass original_history_step (the source) and \
    unchanged_only true. To finish an image without a model (film grain, a grade, a LUT, \
    matching a reference photo's colors and grain), use edit_image_look, with \
    list_grain_profiles and measure_reference. Coordinates are always the image's own pixels from its top left.
    """

  /// `defaults` and `secrets` are where the settings and token are kept: the user's, or a scratch
  /// suite and memory for a scripted check's own server (`commandLine` false: no `--mcp` flags,
  /// and it starts whenever it's on).
  init(
    create: CreateModel, presets: PresetStore, grainProfiles: GrainProfileStore? = nil, defaults: UserDefaults = .standard, secrets: (any RemoteSecretStore)? = nil,
    commandLine: Bool = true
  ) {
    tools = AgentTools(create: create, presets: presets, grainProfiles: grainProfiles)
    self.defaults = defaults
    // A scripted run never touches the user's Keychain.
    tokens = AgentTokenStore(
      secrets: secrets ?? (Automation.isRequested ? MemorySecretStore() : KeychainSecretStore(service: "Atelier Agents")))
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    port = defaults.object(forKey: Self.portKey) as? Int ?? Self.defaultPort
    access = defaults.string(forKey: Self.accessKey).flatMap(AgentAccess.init(rawValue:)) ?? .thisMac
    requireToken = defaults.object(forKey: Self.requireTokenKey) as? Bool ?? true
    let args = commandLine ? CommandLine.arguments : []
    forcedNetwork = args.contains("--mcp-network")
    forcedOn = args.contains("--mcp") || forcedNetwork
    if let index = args.firstIndex(of: "--mcp"), index + 1 < args.count, let port = Int(args[index + 1]) {
      forcedPort = port
    }
    // Read from the Keychain only when it's in use; `ensureToken` reads it otherwise.
    if activeAccess == .localNetwork { token = tokens.load() }
    // Scripted checks leave the user's server (and its port) alone unless asked with `--mcp`.
    if commandLine, Automation.isRequested, !forcedOn { return }
    restart()
  }

  /// The token, made now if there isn't one yet.
  @discardableResult func ensureToken() -> String {
    if let token { return token }
    let made = tokens.ensure()
    token = made
    return made
  }

  /// A new token; clients with the old one get 401 from their next request.
  func regenerateToken() {
    token = tokens.regenerate()
  }

  /// This Mac's addresses as other devices reach it: the local network address, the .local name
  /// and the Tailscale address.
  func refreshEndpoints() {
    let interfaces = RemoteNetworkInfo.interfaces()
    var hosts = [RemoteNetworkInfo.localNetworkHost]
    let hostName = ProcessInfo.processInfo.hostName
    if hostName.hasSuffix(".local") { hosts.append(hostName) }
    if let tailscale = RemoteNetworkInfo.tailscaleAddress(in: interfaces) { hosts.append(tailscale) }
    var seen = Set<String>()
    networkEndpoints = hosts.filter { seen.insert($0).inserted }.map { AgentAuth.endpoint(host: $0, port: activePort) }
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
    let network = activeAccess == .localNetwork
    if network {
      if requireToken { ensureToken() }
      refreshEndpoints()
    }
    let server = LoopbackHTTPServer(port: port, binding: network ? .all(AgentAccess.networkFilter) : .loopback) {
      [weak self] request, responder in
      Task { @MainActor in self?.handle(request, responder) }
    }
    self.server = server
    server.start { [weak self] error in
      Task { @MainActor in
        guard let self, self.server === server else { return }
        self.isListening = error == nil
        self.listenError = error
        if let error {
          Log.agents.error("MCP server on port \(port, privacy: .public) failed: \(error, privacy: .public)")
        } else {
          Log.agents.info("MCP server listening on \(self.endpoint, privacy: .public)")
        }
      }
    }
  }

  // MARK: - HTTP

  private func handle(_ request: LoopbackHTTPServer.Request, _ responder: LoopbackHTTPServer.Responder) {
    let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
    guard path == "/mcp" || path == "/mcp/" else {
      return responder.send(status: 404, body: Data())
    }
    // On the loopback binding every peer is, and the listener only lets in allowed networks.
    let isRemote = !AgentAuth.isLoopback(request.peer)
    if isRemote {
      // Other devices reach this Mac by whatever name or address, so the Host header says
      // nothing; a page from another site must still not drive the server from a browser.
      let own = AgentAuth.ownHosts(
        addresses: RemoteNetworkInfo.interfaces().map(\.address), hostName: ProcessInfo.processInfo.hostName)
      guard AgentAuth.allowsRemote(origin: request.headers["origin"], ownHosts: own) else {
        return responder.send(status: 403, body: Data())
      }
    } else {
      // Only pages and clients on this Mac: a web page elsewhere could otherwise reach the
      // loopback port through DNS rebinding.
      guard AgentAuth.isLoopback(host: request.headers["host"]),
        request.headers["origin"].map({ AgentAuth.isLoopback(origin: $0) }) ?? true
      else {
        return responder.send(status: 403, body: Data())
      }
    }
    guard
      AgentAuth.isAuthorized(
        peerIsLoopback: !isRemote, requireToken: networkNeedsToken, authorization: request.headers["authorization"], token: token)
    else {
      return responder.send(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: Data())
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
      callTool(
        params, id: id, streaming: request.headers["accept"]?.contains("text/event-stream") == true,
        context: ToolContext(isRemote: isRemote), via: responder)
    default:
      respond(error: -32601, "Method not found: \(method)", id: id, via: responder)
    }
  }

  private func callTool(
    _ params: [String: Any], id: Any, streaming: Bool, context: ToolContext, via responder: LoopbackHTTPServer.Responder
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
        result = try await tools.call(name, arguments: arguments, context: context) { progress in
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
    // A client that hangs up (some give up on calls after a few minutes) doesn't stop the run:
    // generate keeps it going as a job for get_job.
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
}

/// Settings → Agents: turn the MCP server on, who can reach it, and how to connect an agent to it.
struct AgentSettingsView: View {
  @Environment(AgentServer.self) private var server
  @State private var portText = ""
  @State private var showsToken = false
  @AppStorage("agentClient") private var client = AgentClient.claudeCode
  /// The address the setup below uses: this Mac's, or one of its network addresses.
  @State private var address = ""

  var body: some View {
    @Bindable var server = server
    let network = server.access == .localNetwork
    Form {
      Section {
        Toggle(isOn: $server.isEnabled) {
          Text("Let agents generate images")
          Text("Runs an MCP server that agents such as Claude Code can use to list models and presets, read and change the Create screen, and generate images. Images are saved to the current project.")
        }
        Picker(selection: $server.access) {
          ForEach(AgentAccess.allCases) { Text($0.title).tag($0) }
        } label: {
          Text("Access")
          Text(accessNote)
        }
        Toggle(isOn: $server.requireToken) {
          Text("Require Token")
          Text("Agents on other devices send this token. Agents on this Mac never need it.")
        }
        .disabled(!network)
        LabeledContent("Token") {
          HStack {
            Text(tokenText)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(1)
              .truncationMode(.middle)
            Button(showsToken ? "Hide" : "Show") { showsToken.toggle() }
            Button("Copy") { Clipboard.copy(server.ensureToken()) }
            Button("Regenerate") { server.regenerateToken() }
          }
        }
        .disabled(!network || !server.requireToken)
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
        Picker("Address", selection: $address) {
          ForEach(addresses, id: \.self) { Text($0).tag($0) }
        }
        Text(client.instructions(withToken: setupToken != nil))
          .foregroundStyle(.secondary)
        Text(client.setup(chosenAddress, token: setupToken.map { showsToken ? $0 : Self.masked }))
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
          Spacer()
          Button("Copy") {
            Clipboard.copy(client.setup(chosenAddress, token: setupToken))
          }
        }
      } header: {
        Text("Connect an Agent")
      } footer: {
        Text("Atelier must be open with the server on while the agent works. Other MCP clients that speak Streamable HTTP can use the same address. For an agent on another device, pick one of this Mac's network addresses.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 600)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      portText = String(server.port)
      server.refreshEndpoints()
      if server.access == .localNetwork, server.requireToken { server.ensureToken() }
      if address.isEmpty { address = server.endpoint }
    }
    .onChange(of: server.access) {
      if server.access == .localNetwork, server.requireToken { server.ensureToken() }
      server.refreshEndpoints()
    }
    .onChange(of: server.requireToken) {
      if server.requireToken, server.access == .localNetwork { server.ensureToken() }
    }
  }

  private static let masked = String(repeating: "•", count: 12)

  private var accessNote: String {
    guard server.access == .localNetwork else { return "Only apps on this Mac can connect." }
    let shared =
      server.requireToken
      ? "Anyone on your network with the token can generate and read or change the Create screen."
      : "Anyone on your network can generate and read or change the Create screen: no token is asked for."
    return shared + " Traffic isn't encrypted; use Tailscale to encrypt it."
  }

  private var tokenText: String {
    guard let token = server.token else { return Self.masked }
    return showsToken ? token : Self.masked
  }

  /// This Mac's endpoint, then the network ones when other devices can connect.
  private var addresses: [String] {
    [server.endpoint] + (server.access == .localNetwork ? server.networkEndpoints : [])
  }

  private var chosenAddress: String {
    addresses.contains(address) ? address : server.endpoint
  }

  /// The token the setup carries: for a network address when one is required.
  private var setupToken: String? {
    guard chosenAddress != server.endpoint, server.networkNeedsToken else { return nil }
    return server.token
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
