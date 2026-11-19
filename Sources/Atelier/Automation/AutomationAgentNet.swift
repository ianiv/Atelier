#if os(macOS)
import Foundation

extension Automation {
  /// The MCP server on the local network, as PASS/FAIL lines: a second server of its own (settings
  /// in a scratch UserDefaults suite, the token in memory, a spare port), so the user's server,
  /// settings and Keychain are left alone. It listens on every interface and is called at this
  /// Mac's local network address, which counts as another device: without the token, with a wrong
  /// one, and with it (401, 401, 200 tools/list); from 127.0.0.1 without one (200); a page from
  /// another site (403); file paths refused (get_image save_to, set_canvas_image with a path,
  /// edit_image_look lut_path, measure_reference path) and list_grain_profiles without its folder;
  /// Regenerate (the old token 401, the new 200); Require Token off (200 without one); and This
  /// Mac only (the network address refused). Needs no model and changes nothing in the project.
  ///
  ///   Atelier --agent-net-check --project NAME [--quit]
  static func agentNetCheck(_ model: CreateModel, presets: PresetStore) {
    let args = CommandLine.arguments
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      let suiteName = "Atelier.agent-net-check.\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else {
        check(false, "a scratch settings suite")
        return
      }
      var server: AgentServer?
      @MainActor func finish() {
        server?.isEnabled = false
        defaults.removePersistentDomain(forName: suiteName)
        print(failures == 0 ? "agent net check: all passed" : "agent net check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      guard let lan = RemoteNetworkInfo.interfaces().first(where: { interface in
        guard case .v4 = interface.ip else { return false }
        return interface.ip.isLocalNetwork && !interface.ip.isTailscale
      })?.address else {
        check(false, "this Mac has a local network address")
        return finish()
      }
      let port = Int.random(in: 41000...48000)
      defaults.set(true, forKey: "agentServer.enabled")
      defaults.set(port, forKey: "agentServer.port")
      defaults.set(AgentAccess.localNetwork.rawValue, forKey: "agentServer.access")
      defaults.set(true, forKey: "agentServer.requireToken")
      let started = AgentServer(create: model, presets: presets, defaults: defaults, secrets: MemorySecretStore(), commandLine: false)
      server = started
      let deadline = Date().addingTimeInterval(10)
      while !started.isListening, started.listenError == nil, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      check(started.isListening, "listens on every interface at port \(port)\(started.listenError.map { ": \($0)" } ?? "")")
      guard started.isListening, let token = started.token else {
        check(false, "made a token")
        return finish()
      }
      check(started.networkEndpoints.contains(AgentAuth.endpoint(host: lan, port: port)), "lists \(lan) among its network addresses")

      let session = URLSession(configuration: .ephemeral)
      func post(
        _ host: String, _ message: [String: Any], token: String? = nil, origin: String? = nil
      ) async -> (status: Int, body: [String: Any], authenticate: String?) {
        var request = URLRequest(url: URL(string: AgentAuth.endpoint(host: host, port: port))!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: message)
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
          return (0, [:], nil)
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, body, http.value(forHTTPHeaderField: "WWW-Authenticate"))
      }
      let list: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
      func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
      }
      func errorText(_ body: [String: Any]) -> String? {
        guard let result = body["result"] as? [String: Any], result["isError"] as? Bool == true else { return nil }
        return ((result["content"] as? [[String: Any]])?.first)?["text"] as? String
      }

      let missing = await post(lan, list)
      check(missing.status == 401 && missing.authenticate == "Bearer", "\(lan) without the token: 401 with WWW-Authenticate: Bearer (got \(missing.status))")
      let wrong = await post(lan, list, token: token + "x")
      check(wrong.status == 401, "\(lan) with a wrong token: 401 (got \(wrong.status))")
      let allowed = await post(lan, list, token: token)
      let tools = ((allowed.body["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
      let getImage = tools.first { $0["name"] as? String == "get_image" }
      let fullSize = ((getImage?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["full_size"]
      check(allowed.status == 200 && !tools.isEmpty, "\(lan) with the token: 200 tools/list (got \(allowed.status), \(tools.count) tools)")
      check(fullSize != nil, "get_image lists full_size")
      let local = await post("127.0.0.1", list)
      check(local.status == 200, "127.0.0.1 without a token: 200 (got \(local.status))")
      let foreign = await post(lan, list, token: token, origin: "http://example.com")
      check(foreign.status == 403, "\(lan) from a page on another site: 403 (got \(foreign.status))")
      let own = await post(lan, list, token: token, origin: "http://\(lan):\(port)")
      check(own.status == 200, "\(lan) from a page on this Mac's address: 200 (got \(own.status))")
      let otherPort = await post(lan, list, token: token, origin: "http://\(lan):\(port + 1)")
      check(otherPort.status == 403, "\(lan) from a page on another port of this Mac: 403 (got \(otherPort.status))")
      // A large body without the token is answered from its headers alone.
      var big = URLRequest(url: URL(string: AgentAuth.endpoint(host: lan, port: port))!)
      big.httpMethod = "POST"
      big.timeoutInterval = 10
      big.httpBody = Data(count: 8 << 20)
      let bigStatus = ((try? await session.data(for: big))?.1 as? HTTPURLResponse)?.statusCode
      check(bigStatus == 401 || bigStatus == nil, "\(lan) sending 8 MB without the token: refused before the body (got \(bigStatus.map(String.init) ?? "connection closed"))")

      let saveTo = await post(lan, call("get_image", ["save_to": NSTemporaryDirectory()]), token: token)
      check(errorText(saveTo.body) == AgentPathGuard.saveToMessage, "get_image save_to from another device is refused (\(errorText(saveTo.body) ?? "no error"))")
      let path = await post(lan, call("set_canvas_image", ["image": "/nonexistent/atelier-agent-net-check.png"]), token: token)
      check(errorText(path.body) == AgentPathGuard.pathMessage, "set_canvas_image with a path from another device is refused (\(errorText(path.body) ?? "no error"))")
      let lut = await post(lan, call("edit_image_look", ["lut_path": "/nonexistent/look.cube"]), token: token)
      check(errorText(lut.body)?.hasPrefix("File paths are only for agents on this Mac;") == true, "edit_image_look lut_path from another device is refused (\(errorText(lut.body) ?? "no error"))")
      let measure = await post(lan, call("measure_reference", ["path": "/nonexistent/reference.png"]), token: token)
      check(errorText(measure.body) == AgentPathGuard.pathMessage, "measure_reference path from another device is refused (\(errorText(measure.body) ?? "no error"))")
      let profiles = await post(lan, call("list_grain_profiles", [:]), token: token)
      let profilesText = ((profiles.body["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
      check(profiles.status == 200 && !profilesText.contains("\"folder\""), "list_grain_profiles from another device leaves out the folder")
      let localPath = await post("127.0.0.1", call("set_canvas_image", ["image": "/nonexistent/atelier-agent-net-check.png"]))
      check(
        errorText(localPath.body)?.hasPrefix("Couldn't read an image") == true,
        "the same path from this Mac is read (\(errorText(localPath.body) ?? "no error"))")

      started.regenerateToken()
      let old = await post(lan, list, token: token)
      let new = await post(lan, list, token: started.token)
      check(old.status == 401 && new.status == 200 && started.token != token, "after Regenerate: old token 401, new 200 (got \(old.status), \(new.status))")

      started.requireToken = false
      let open = await post(lan, list)
      check(open.status == 200, "Require Token off: \(lan) without a token 200 (got \(open.status))")
      let openPath = await post(lan, call("get_image", ["save_to": NSTemporaryDirectory()]))
      check(errorText(openPath.body) == AgentPathGuard.saveToMessage, "Require Token off: paths still refused")

      // A restart on the local network (the port may still be held a moment): listening again.
      started.isEnabled = false
      started.isEnabled = true
      let againDeadline = Date().addingTimeInterval(15)
      while !started.isListening, started.listenError == nil, Date() < againDeadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      let again = await post(lan, list)
      check(started.isListening && again.status == 200, "restarted on the local network: listening again (\(started.listenError ?? "got \(again.status)"))")

      started.access = .thisMac
      let restartDeadline = Date().addingTimeInterval(10)
      while !started.isListening, started.listenError == nil, Date() < restartDeadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      let shut = await post(lan, list)
      let loopback = await post("127.0.0.1", list)
      check(shut.status == 0 && loopback.status == 200, "This Mac only: \(lan) refused, 127.0.0.1 200 (got \(shut.status), \(loopback.status))")
      finish()
    }
  }
}
#endif
