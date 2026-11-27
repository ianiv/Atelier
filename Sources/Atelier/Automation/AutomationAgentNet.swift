#if os(macOS)
import Foundation

/// Settings kept in memory only, for a check's own server. A scratch suite would do, but removing
/// it still leaves an empty plist in ~/Library/Preferences: cfprefsd writes the emptied domain out
/// when the app quits, after any attempt to delete the file.
final nonisolated class MemoryDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private nonisolated(unsafe) var values: [String: Any] = [:]

  // Every read and write below stays in `values`: nothing reaches the suite this is made with.
  override init?(suiteName suitename: String?) {
    super.init(suiteName: suitename)
  }

  /// One with no suite, which can't fail (`UserDefaults(suiteName: nil)` never does); never the
  /// real settings in its place.
  static func make() -> MemoryDefaults {
    guard let defaults = MemoryDefaults(suiteName: nil) else { preconditionFailure("UserDefaults(suiteName: nil) failed") }
    return defaults
  }

  override func object(forKey defaultName: String) -> Any? { lock.withLock { values[defaultName] } }
  override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
  override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
  override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
  override func removeObject(forKey defaultName: String) { lock.withLock { values[defaultName] = nil } }
  override func bool(forKey defaultName: String) -> Bool { object(forKey: defaultName) as? Bool ?? false }
  override func integer(forKey defaultName: String) -> Int { object(forKey: defaultName) as? Int ?? 0 }
  override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
}

/// A plain BSD socket listening on a port, standing in for another app that holds it: on 127.0.0.1,
/// or on every interface (IPv6 with IPv4 mapped, as the servers' wildcard listeners are). No
/// endpoint reuse, as most apps have none.
final nonisolated class AutomationPortHolder {
  private var fd: Int32

  init?(port: Int, loopback: Bool) {
    fd = socket(loopback ? AF_INET : AF_INET6, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let result: Int32
    if loopback {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      address.sin_port = UInt16(port).bigEndian
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }
    } else {
      var off: Int32 = 0
      setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
      var address = sockaddr_in6()
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_addr = in6addr_any
      address.sin6_port = UInt16(port).bigEndian
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
      }
    }
    guard result == 0, listen(fd, 1) == 0 else {
      Darwin.close(fd)
      return nil
    }
  }

  func close() {
    guard fd >= 0 else { return }
    Darwin.close(fd)
    fd = -1
  }

  deinit { close() }
}

extension Automation {
  /// The MCP server on the local network, as PASS/FAIL lines: a second server of its own (settings
  /// and token in memory, a spare port), so the user's server, settings and Keychain are left
  /// alone. It listens on every interface and is called at this
  /// Mac's local network address, which counts as another device: without the token, with a wrong
  /// one, and with it (401, 401, 200 tools/list); from 127.0.0.1 without one (200); a page from
  /// another site (403); file paths refused (get_image save_to, set_canvas_image with a path,
  /// edit_image_look lut_path, measure_reference path) and list_grain_profiles without its folder;
  /// Regenerate (the old token 401, the new 200); Require Token off (200 without one); HTTPS with
  /// an imported certificate (a throwaway root, intermediate and leaf, made in memory; the client
  /// trusts only the root): the HTTPS port (two past the server's) without the token, with it and from its own
  /// page (401, 200, 200), plain HTTP to it and the network address on the plain port refused,
  /// 127.0.0.1 still 200, a client that doesn't trust the certificate refused; Tailscale's
  /// certificate without a signed-in node (an error, this Mac still 200); and This Mac only (the
  /// network address refused). Then ports: a port held by a socket of its own names Atelier in
  /// Status with Try Again on, and Try Again listens once it's free, for the plain port and an
  /// HTTPS Port; a Compute server of its own taking the automatic HTTPS port moves HTTPS, and each
  /// field refuses the other's port. Every request above is a 2025 client's; `modernChecks` adds a
  /// 2026-07-28 client's (headers and `_meta`) and the rules between the two, and `taskChecks`
  /// the Tasks extension. Needs no model, and leaves the user's settings and Keychain alone; the
  /// tasks section adds a test image and its edits to the project, so always pass a scratch
  /// `--project`.
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
      guard let defaults = MemoryDefaults(suiteName: nil) else {
        check(false, "scratch settings")
        return
      }
      var server: AgentServer?
      var compute: RemoteServer?
      let computeRoot = FileManager.default.temporaryDirectory.appending(path: "atelier-agent-net-\(UUID())", directoryHint: .isDirectory)
      @MainActor func finish() {
        server?.isEnabled = false
        compute?.isEnabled = false
        try? FileManager.default.removeItem(at: computeRoot)
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
      guard let testCertificate = try? AutomationTestCertificate(hosts: [lan, "127.0.0.1"]) else {
        check(false, "made a test certificate")
        return finish()
      }
      defaults.set(true, forKey: "agentServer.enabled")
      defaults.set(port, forKey: "agentServer.port")
      defaults.set(AgentAccess.localNetwork.rawValue, forKey: "agentServer.access")
      defaults.set(true, forKey: "agentServer.requireToken")
      let started = AgentServer(
        create: model, presets: presets, defaults: defaults, secrets: MemorySecretStore(), certificate: testCertificate.identity,
        commandLine: false)
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
      // Trusts the test authority and nothing else.
      let trusting = URLSession(configuration: .ephemeral, delegate: AutomationAnchoredTrust(anchor: testCertificate.authority), delegateQueue: nil)
      func post(
        _ host: String, _ message: [String: Any], token: String? = nil, origin: String? = nil, scheme: String = "http",
        port: Int = port, session: URLSession = session, headers: [String: String] = [:]
      ) async -> (status: Int, body: [String: Any], authenticate: String?, raw: String) {
        var request = URLRequest(url: URL(string: AgentAuth.endpoint(scheme: scheme, host: host, port: port))!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: message)
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
          return (0, [:], nil, "")
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, body, http.value(forHTTPHeaderField: "WWW-Authenticate"), String(decoding: data, as: UTF8.self))
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

      await modernChecks(lan: lan, port: port, token: token, post: { host, message, token, headers in await post(host, message, token: token, headers: headers) }, check: check)
      // The tasks section saves steps: never into the project you were working in.
      if let index = args.firstIndex(of: "--project"), index + 1 < args.count {
        await taskChecks(model, lan: lan, port: port, token: token, post: { host, message, token, headers in await post(host, message, token: token, headers: headers) }, check: check)
      } else {
        check(false, "tasks: --project NAME is given (the tasks section saves steps, so it's skipped)")
      }

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

      // HTTPS with an imported certificate: the next port, and the plain one for this Mac only.
      started.requireToken = true
      let httpsToken = started.ensureToken()
      let httpsPort = started.httpsPort ?? port + 2
      started.encryption = .certificate
      let httpsDeadline = Date().addingTimeInterval(15)
      while started.httpsEndpoint == nil || !started.isListening, started.httpsError == nil, started.listenError == nil, Date() < httpsDeadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      check(
        started.httpsEndpoint != nil && started.isListening,
        "HTTPS listening on port \(httpsPort)\(started.httpsError.map { ": \($0)" } ?? "")")
      let httpsURL = AgentAuth.endpoint(scheme: "https", host: lan, port: httpsPort)
      check(started.networkEndpoints.contains(httpsURL), "lists \(httpsURL) (got \(started.networkEndpoints))")
      check(
        started.activeCertificate?.fingerprint == testCertificate.identity.fingerprint,
        "serves the imported certificate (\(started.activeCertificate?.fingerprint.prefix(11) ?? "none"))")
      let httpsMissing = await post(lan, list, scheme: "https", port: httpsPort, session: trusting)
      check(httpsMissing.status == 401, "HTTPS \(lan) without the token: 401 (got \(httpsMissing.status))")
      let httpsAllowed = await post(lan, list, token: httpsToken, scheme: "https", port: httpsPort, session: trusting)
      check(
        httpsAllowed.status == 200 && started.activeCertificate?.chain.count == 2,
        "HTTPS \(lan) with the token, trusting only the root (the leaf is the intermediate's, so the server sent it): 200 (got \(httpsAllowed.status))")
      let httpsPage = await post(lan, list, token: httpsToken, origin: "https://\(lan):\(httpsPort)", scheme: "https", port: httpsPort, session: trusting)
      check(httpsPage.status == 200, "HTTPS \(lan) from a page on its own address: 200 (got \(httpsPage.status))")
      let httpsForeign = await post(lan, list, token: httpsToken, origin: "https://example.com", scheme: "https", port: httpsPort, session: trusting)
      check(httpsForeign.status == 403, "HTTPS \(lan) from a page on another site: 403 (got \(httpsForeign.status))")
      let httpsPath = await post(lan, call("get_image", ["save_to": NSTemporaryDirectory()]), token: httpsToken, scheme: "https", port: httpsPort, session: trusting)
      check(errorText(httpsPath.body) == AgentPathGuard.saveToMessage, "HTTPS: paths from another device refused")
      let plainToTLS = await post(lan, list, token: httpsToken, port: httpsPort)
      check(plainToTLS.status == 0, "plain HTTP to the HTTPS port: refused (got \(plainToTLS.status))")
      let plainNetwork = await post(lan, list, token: httpsToken)
      check(plainNetwork.status == 0, "with HTTPS, \(lan) on plain port \(port): refused (got \(plainNetwork.status))")
      let plainLocal = await post("127.0.0.1", list)
      check(plainLocal.status == 200, "with HTTPS, 127.0.0.1 on plain port \(port): 200 (got \(plainLocal.status))")
      let untrusted = await post(lan, list, token: httpsToken, scheme: "https", port: httpsPort)
      check(untrusted.status == 0, "a client that doesn't trust the certificate: refused (got \(untrusted.status))")

      // Tailscale's certificate needs the embedded node signed in, which a scripted run never is.
      started.encryption = .tailscale
      let tailnetDeadline = Date().addingTimeInterval(10)
      while started.httpsError == nil || !started.isListening, Date() < tailnetDeadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      let tailnetLocal = await post("127.0.0.1", list)
      check(
        started.httpsError != nil && started.httpsEndpoint == nil && tailnetLocal.status == 200,
        "Tailscale certificate without a signed-in node: \(started.httpsError ?? "no error"); 127.0.0.1 \(tailnetLocal.status)")
      started.encryption = .none

      started.access = .thisMac
      let restartDeadline = Date().addingTimeInterval(10)
      while !started.isListening, started.listenError == nil, Date() < restartDeadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      let shut = await post(lan, list)
      let loopback = await post("127.0.0.1", list)
      check(
        shut.status == 0 && loopback.status == 200,
        "This Mac only: \(lan) refused, 127.0.0.1 200 (got \(shut.status), \(loopback.status)\(started.listenError.map { ", \($0)" } ?? ""), listening \(started.isListening))")

      @MainActor func wait(_ seconds: Double = 15, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
      }
      // A port another app holds (a socket of this process's own, so Atelier is named).
      let busy = Int.random(in: 49000...52000)
      if let holder = AutomationPortHolder(port: busy, loopback: true) {
        check(started.choosePort(busy), "the Port field takes a free port \(busy)")
        await wait { started.isListening || started.listenError != nil }
        check(
          !started.isListening && started.listenError?.contains("Atelier") == true && started.listenPortError,
          "port \(busy) held elsewhere: \(started.listenError ?? "no error"), Try Again \(started.listenPortError ? "on" : "off")")
        holder.close()
        started.retryListening()
        await wait { started.isListening || started.listenError != nil }
        let freed = await post("127.0.0.1", list, port: busy)
        check(started.isListening && !started.listenPortError && freed.status == 200, "Try Again once it's free: listening on \(busy) (\(started.listenError ?? "got \(freed.status)"))")
      } else {
        check(false, "held port \(busy) for the check")
      }

      // The same for an HTTPS Port.
      started.access = .localNetwork
      started.encryption = .certificate
      let busyHTTPS = busy + 10
      if let holder = AutomationPortHolder(port: busyHTTPS, loopback: false) {
        check(started.chooseHTTPSPort(busyHTTPS), "the HTTPS Port field takes \(busyHTTPS)")
        await wait { started.httpsEndpoint != nil || started.httpsError != nil }
        check(
          started.httpsEndpoint == nil && started.httpsError?.contains("Atelier") == true && started.httpsPortError,
          "HTTPS port \(busyHTTPS) held elsewhere: \(started.httpsError ?? "no error"), Try Again \(started.httpsPortError ? "on" : "off")")
        holder.close()
        started.retryHTTPS()
        await wait { started.httpsEndpoint != nil || started.httpsError != nil }
        let secure = await post(lan, list, token: started.token, scheme: "https", port: busyHTTPS, session: trusting)
        check(
          started.httpsEndpoint != nil && !started.httpsPortError && secure.status == 200,
          "HTTPS Try Again once it's free: listening on \(busyHTTPS) (\(started.httpsError ?? "got \(secure.status)"))")
      } else {
        check(false, "held port \(busyHTTPS) for the check")
      }
      check(!started.chooseHTTPSPort(busy) && started.httpsPortRefusal == PortClaims.message(port: busy, of: .mcp), "the HTTPS Port field refuses the server's own port (\(started.httpsPortRefusal ?? "taken"))")

      // Automatic HTTPS moves off Compute's port when Compute takes it.
      check(started.chooseHTTPSPort(nil), "HTTPS Port back to Automatic")
      await wait { started.httpsEndpoint != nil || started.httpsError != nil }
      let automatic = started.httpsPort ?? 0
      check(started.httpsEndpoint != nil && automatic == busy + 2, "automatic HTTPS on \(automatic), two past \(busy)")
      var options = RemoteServer.Options()
      options.store = MemorySecretStore()
      options.root = computeRoot
      options.isApp = false
      options.loopbackOnly = true
      options.filter = .any
      options.port = UInt16(automatic)
      let computeServer = RemoteServer(create: model, library: nil, options: options)
      compute = computeServer
      computeServer.isEnabled = true
      await computeServer.settled()
      await wait { started.httpsPort != automatic && (started.httpsEndpoint != nil || started.httpsError != nil) }
      let moved = started.httpsPort ?? 0
      let movedCall = await post(lan, list, token: started.token, scheme: "https", port: moved, session: trusting)
      check(
        computeServer.isListening && Int(computeServer.boundPort) == automatic && moved != automatic && movedCall.status == 200,
        "Compute on \(automatic): HTTPS moved to \(moved) (Compute \(computeServer.listenError ?? "listening"), HTTPS \(started.httpsError ?? "got \(movedCall.status)"))")
      check(
        !computeServer.choosePort(UInt16(busy)) && computeServer.portRefusal == PortClaims.message(port: busy, of: .mcp),
        "Compute's Port field refuses the MCP server's port (\(computeServer.portRefusal ?? "taken"))")
      check(
        !started.choosePort(automatic) && started.portRefusal == PortClaims.message(port: automatic, of: .compute),
        "the MCP Port field refuses Compute's port (\(started.portRefusal ?? "taken"))")
      check(!started.chooseHTTPSPort(automatic), "the HTTPS Port field refuses Compute's port too")
      computeServer.isEnabled = false
      await computeServer.settled()
      finish()
    }
  }

  /// A modern list_skills call over a plain socket that shuts its sending side right after the
  /// request (a FIN, as some clients and the tailnet bridge send), then reads the reply to the end.
  nonisolated static func halfClosedCall(port: Int) -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return "" }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = UInt16(port).bigEndian
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return "" }
    let body = #"{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"list_skills","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
    let request =
      "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nAccept: application/json\r\n"
      + "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\nMcp-Name: list_skills\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
    let bytes = Array(request.utf8)
    guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else { return "" }
    shutdown(fd, SHUT_WR)
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      guard count > 0 else { break }
      reply.append(contentsOf: buffer[0..<count])
    }
    return String(decoding: reply, as: UTF8.self)
  }

  typealias AgentNetPost = (
    _ host: String, _ message: [String: Any], _ token: String?, _ headers: [String: String]
  ) async -> (status: Int, body: [String: Any], authenticate: String?, raw: String)

  /// The 2026-07-28 protocol on the check's server (`AgentProtocol`): server/discover's fields,
  /// modern tools/list and tools/call results, each mirrored header refused when it's missing,
  /// wrong or doesn't match the body (-32020), base64 in Mcp-Name, an unknown version (-32022
  /// with the supported ones), missing client capabilities (-32602), the removed ping and the
  /// unimplemented subscriptions/listen (404 -32601), the network address without the token
  /// (401), no paths in what another device gets, and beside them the 2025 forms: initialize
  /// asking for 2026-07-28 answered with 2025-11-25, resources and the skills extension
  /// declared, and tools/list without modern fields.
  @MainActor
  static func modernChecks(
    lan: String, port: Int, token: String,
    post: AgentNetPost, check: (Bool, String) -> Void
  ) async {
    func message(_ method: String, _ params: [String: Any] = [:], version: String = "2026-07-28", capabilities: Bool = true) -> [String: Any] {
      var meta: [String: Any] = [AgentProtocol.versionKey: version, "io.modelcontextprotocol/clientInfo": ["name": "agent-net-check", "version": "1"]]
      if capabilities { meta[AgentProtocol.clientCapabilitiesKey] = [String: Any]() }
      var params = params
      params["_meta"] = meta
      return ["jsonrpc": "2.0", "id": 50, "method": method, "params": params]
    }
    func headers(_ method: String, name: String? = nil, version: String = "2026-07-28") -> [String: String] {
      var headers = ["MCP-Protocol-Version": version, "Mcp-Method": method]
      if let name { headers["Mcp-Name"] = name }
      return headers
    }
    func send(_ message: [String: Any], _ headers: [String: String], host: String = "127.0.0.1", token: String? = nil) async -> (
      status: Int, body: [String: Any], authenticate: String?, raw: String
    ) {
      await post(host, message, token, headers)
    }
    func code(_ body: [String: Any]) -> Int? { (body["error"] as? [String: Any])?["code"] as? Int }

    let discover = await send(message("server/discover"), headers("server/discover"))
    let result = discover.body["result"] as? [String: Any] ?? [:]
    let capabilities = result["capabilities"] as? [String: Any]
    let skills = (capabilities?["extensions"] as? [String: Any])?[AgentProtocol.skillsExtension] as? [String: Any]
    let info = (result["_meta"] as? [String: Any])?[AgentProtocol.serverInfoKey] as? [String: Any]
    check(
      discover.status == 200 && result["resultType"] as? String == "complete"
        && result["supportedVersions"] as? [String] == ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]
        && result["ttlMs"] as? Int == 3_600_000 && result["cacheScope"] as? String == "private" && info?["name"] as? String == "atelier"
        && skills?["directoryRead"] as? Bool == true && capabilities?["resources"] != nil && result["instructions"] is String,
      "modern server/discover: resultType, four versions, ttlMs, cacheScope, serverInfo, the skills extension (got \(discover.status))")
    let tools = await send(message("tools/list"), headers("tools/list"))
    let toolsResult = tools.body["result"] as? [String: Any]
    check(
      tools.status == 200 && toolsResult?["ttlMs"] as? Int == 3_600_000 && (toolsResult?["tools"] as? [Any])?.isEmpty == false,
      "modern tools/list carries ttlMs")
    let call = await send(message("tools/call", ["name": "list_skills", "arguments": [String: Any]()]), headers("tools/call", name: "list_skills"))
    let callResult = call.body["result"] as? [String: Any]
    check(call.status == 200 && callResult?["resultType"] as? String == "complete" && callResult?["ttlMs"] == nil, "modern tools/call: resultType, no ttlMs")

    let noHeader = await send(message("tools/list"), [:])
    check(noHeader.status == 400 && code(noHeader.body) == -32020, "modern _meta without MCP-Protocol-Version: 400 -32020 (got \(noHeader.status) \(code(noHeader.body) ?? 0))")
    let mismatch = await send(message("tools/list"), headers("tools/list", version: "2025-11-25"))
    check(mismatch.status == 400 && code(mismatch.body) == -32020, "MCP-Protocol-Version unlike _meta's: 400 -32020")
    let wrongMethod = await send(message("tools/list"), headers("resources/list"))
    check(wrongMethod.status == 400 && code(wrongMethod.body) == -32020, "wrong Mcp-Method: 400 -32020")
    let noName = await send(message("tools/call", ["name": "list_skills", "arguments": [String: Any]()]), headers("tools/call"))
    check(noName.status == 400 && code(noName.body) == -32020, "tools/call without Mcp-Name: 400 -32020")
    let encoded = "=?base64?\(Data("list_skills".utf8).base64EncodedString())?="
    let base64 = await send(message("tools/call", ["name": "list_skills", "arguments": [String: Any]()]), headers("tools/call", name: encoded))
    check(base64.status == 200 && (base64.body["result"] as? [String: Any])?["resultType"] as? String == "complete", "a base64 Mcp-Name: 200 (got \(base64.status))")
    let old = await send(message("tools/list", version: "1900-01-01"), headers("tools/list", version: "1900-01-01"))
    let data = (old.body["error"] as? [String: Any])?["data"] as? [String: Any]
    check(
      old.status == 400 && code(old.body) == -32022 && (data?["supported"] as? [String])?.first == "2026-07-28" && data?["requested"] as? String == "1900-01-01",
      "protocol version 1900-01-01: 400 -32022 with the supported versions (got \(old.status) \(code(old.body) ?? 0))")
    let noCapabilities = await send(message("tools/list", capabilities: false), headers("tools/list"))
    check(noCapabilities.status == 400 && code(noCapabilities.body) == -32602, "missing clientCapabilities: 400 -32602")
    let ping = await send(message("ping"), headers("ping"))
    check(ping.status == 404 && code(ping.body) == -32601, "modern ping: 404 -32601 (got \(ping.status))")
    let listen = await send(message("subscriptions/listen"), headers("subscriptions/listen"))
    check(listen.status == 404 && code(listen.body) == -32601, "subscriptions/listen: 404 -32601")
    let remoteMissing = await send(message("server/discover"), headers("server/discover"), host: lan)
    check(remoteMissing.status == 401, "modern \(lan) without the token: 401 (got \(remoteMissing.status))")
    let remote = await send(message("server/discover"), headers("server/discover"), host: lan, token: token)
    let remoteCall = await send(message("tools/call", ["name": "list_skills", "arguments": [String: Any]()]), headers("tools/call", name: "list_skills"), host: lan, token: token)
    check(
      remote.status == 200 && remoteCall.status == 200 && ![remote.raw, remoteCall.raw].contains { $0.contains("/Users/") || $0.contains(NSHomeDirectory()) },
      "modern \(lan) with the token: 200 and no paths")

    // A client that half-closes once its request is sent still gets the whole answer. Every tool
    // slow enough to prove the FIN came first needs a model or a job, so LoopbackHTTPServerTests
    // pins that with a handler that answers 800 ms after the half-close.
    let halfClosed = await Task.detached { halfClosedCall(port: port) }.value
    check(
      halfClosed.contains("200 OK") && halfClosed.contains("\"resultType\":\"complete\"") && !halfClosed.contains("Cancelled."),
      "modern tools/call from a client that half-closes after its request: answered, not cancelled")

    let initialize = await send(["jsonrpc": "2.0", "id": 51, "method": "initialize", "params": ["protocolVersion": "2026-07-28", "capabilities": [String: Any]()]], [:])
    let initialized = initialize.body["result"] as? [String: Any]
    let initCapabilities = initialized?["capabilities"] as? [String: Any]
    check(
      initialized?["protocolVersion"] as? String == "2025-11-25" && initCapabilities?["resources"] != nil
        && (initCapabilities?["extensions"] as? [String: Any])?[AgentProtocol.skillsExtension] != nil && initialized?["resultType"] == nil,
      "legacy initialize asking for 2026-07-28: 2025-11-25, with resources and the skills extension")
    let legacyTools = await send(["jsonrpc": "2.0", "id": 52, "method": "tools/list"], [:])
    let legacyResult = legacyTools.body["result"] as? [String: Any]
    check(legacyTools.status == 200 && legacyResult?["tools"] != nil && legacyResult?["resultType"] == nil && legacyResult?["ttlMs"] == nil, "legacy tools/list has no resultType or ttlMs")
  }

  /// The Tasks extension (`AgentTasks`) on the check's server, with edit_image_look as the job
  /// (it needs no model) on a test image this adds to the project: server/discover declares it
  /// and initialize doesn't; a call that doesn't declare it gets its CallToolResult; a declaring
  /// one, with the Queue paused, gets a task (resultType "task", a job-<UUID> id, working, ttlMs
  /// null, pollIntervalMs) that get_job and list_jobs (with its status) see too; tasks/get
  /// without or with the wrong Mcp-Name (-32020), from a request that doesn't declare it
  /// (400 -32021 naming the extension), for an unknown id (-32602); tasks/update's ack, and -32602
  /// without inputResponses; tasks/cancel's ack and the task then cancelled, and its ack again
  /// once it's over; another task polled to completed with the step in its result and an hour's
  /// ttlMs, read from another device without paths; tasks/result and tasks/list 404 -32601, a
  /// 2025 tasks/get and tasks/update -32601; an argument error and a tool that isn't a job answered inline. The
  /// Queue's paused state is put back.
  @MainActor
  static func taskChecks(
    _ model: CreateModel, lan: String, port _: Int, token: String,
    post: AgentNetPost, check: (Bool, String) -> Void
  ) async {
    let tasksID = AgentTasks.extensionID
    var nextID = 70
    func message(_ method: String, _ params: [String: Any] = [:], declares: Bool = true) -> [String: Any] {
      let capabilities: [String: Any] = declares ? ["extensions": [tasksID: [String: Any]()]] : [:]
      var params = params
      params["_meta"] = [
        AgentProtocol.versionKey: "2026-07-28", AgentProtocol.clientCapabilitiesKey: capabilities,
        "io.modelcontextprotocol/clientInfo": ["name": "agent-net-check", "version": "1"],
      ]
      nextID += 1
      return ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
    }
    func headers(_ method: String, name: String? = nil) -> [String: String] {
      var headers = ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": method]
      if let name { headers["Mcp-Name"] = name }
      return headers
    }
    func code(_ body: [String: Any]) -> Int? { (body["error"] as? [String: Any])?["code"] as? Int }
    func result(_ body: [String: Any]) -> [String: Any] { body["result"] as? [String: Any] ?? [:] }
    func callTool(_ name: String, _ arguments: [String: Any], declares: Bool = true) async -> (status: Int, body: [String: Any], authenticate: String?, raw: String) {
      await post("127.0.0.1", message("tools/call", ["name": name, "arguments": arguments], declares: declares), nil, headers("tools/call", name: name))
    }
    func task(_ method: String, _ id: String, _ extra: [String: Any] = [:], declares: Bool = true, name: String?? = .none, host: String = "127.0.0.1", token: String? = nil) async -> (
      status: Int, body: [String: Any], authenticate: String?, raw: String
    ) {
      var params = extra
      params["taskId"] = id
      return await post(host, message(method, params, declares: declares), token, headers(method, name: name ?? id))
    }
    /// A legacy (2025) tools/call's JSON answer.
    func legacyJSON(_ name: String, _ arguments: [String: Any]) async -> Any? {
      let answer = await post("127.0.0.1", ["jsonrpc": "2.0", "id": 90, "method": "tools/call", "params": ["name": name, "arguments": arguments]], nil, [:])
      let text = (result(answer.body)["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
      return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    let discover = await post("127.0.0.1", message("server/discover"), nil, headers("server/discover"))
    let discovered = (result(discover.body)["capabilities"] as? [String: Any])?["extensions"] as? [String: Any]
    check(discovered?[tasksID] is [String: Any], "server/discover declares \(tasksID)")
    let initialize = await post("127.0.0.1", ["jsonrpc": "2.0", "id": 69, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [String: Any]()]], nil, [:])
    let initCapabilities = result(initialize.body)["capabilities"] as? [String: Any]
    check(
      initCapabilities != nil && (initCapabilities?["extensions"] as? [String: Any])?[tasksID] == nil && initCapabilities?["tasks"] == nil,
      "legacy initialize declares no tasks")

    // A step to edit, as the Edit checks make one.
    var waited = 0
    while model.settings == nil || !model.history.isLoaded, waited < 600 {
      try? await Task.sleep(for: .milliseconds(100))
      waited += 1
    }
    guard let settings = model.settings, let image = testImage(width: 640, height: 448), let tensor = ImageTensor.tensor(from: image) else {
      return check(false, "tasks: the project didn't load or the test image couldn't be made")
    }
    var configuration = settings
    configuration.width = 640
    configuration.height = 448
    var request = GenerationEngine.Request(model: model.selectedModel ?? "", prompt: "agent tasks check", negativePrompt: "", seed: 1, configuration: configuration)
    request.canvas = image
    request.canvasIsImported = true
    guard let source = try? await model.history.save(GenerationEngine.Output(frames: [tensor]), request: request, startedAt: Date(), finishedAt: Date())
    else { return check(false, "tasks: the test image couldn't be added to the project") }
    let step = Int(source.id.logicalTime)
    func look(_ amount: Double) -> [String: Any] { ["history_step": step, "options": ["vignette": ["amount": amount]]] }

    let pausedBefore = model.queue.isPaused
    model.setQueuePaused(false)
    defer { model.setQueuePaused(pausedBefore) }
    // Without the extension: the plain CallToolResult, job id and all.
    let plain = await callTool("edit_image_look", look(0.11), declares: false)
    let plainResult = result(plain.body)
    let plainStructured = plainResult["structuredContent"] as? [String: Any]
    let plainJob = plainStructured?["job_id"] as? String ?? ""
    check(
      plainResult["resultType"] as? String == "complete" && plainStructured?["history_step"] is Int && plainJob.hasPrefix("job-")
        && UUID(uuidString: String(plainJob.dropFirst(4))) != nil,
      "tasks: a call that doesn't declare the extension gets its result, job id \(plainJob)\(plainResult["isError"] as? Bool == true ? " (error: \(plain.raw.prefix(200)))" : "")")

    model.setQueuePaused(true)
    let created = await callTool("edit_image_look", look(0.12))
    let createdResult = result(created.body)
    let taskID = createdResult["taskId"] as? String ?? ""
    check(
      created.status == 200 && createdResult["resultType"] as? String == "task" && taskID.hasPrefix("job-") && UUID(uuidString: String(taskID.dropFirst(4))) != nil
        && createdResult["status"] as? String == "working" && createdResult["ttlMs"] is NSNull && createdResult["pollIntervalMs"] as? Int == 5000
        && createdResult["createdAt"] is String && createdResult["lastUpdatedAt"] is String && createdResult["result"] == nil,
      "tasks: a declaring call with the Queue paused gets a working task (\(created.raw.prefix(300)))")
    let gotJob = await legacyJSON("get_job", ["job_id": taskID, "wait_seconds": 0]) as? [String: Any]
    check(gotJob?["status"] as? String == "waiting", "tasks: get_job reads the task's job: \(gotJob?["status"] ?? "not found")")
    let listed = await legacyJSON("list_jobs", [:]) as? [[String: Any]] ?? []
    check(
      listed.contains { $0["job_id"] as? String == taskID } && listed.allSatisfy { $0["status"] is String },
      "tasks: list_jobs lists it, every entry with a status")

    let working = await task("tasks/get", taskID)
    let workingResult = result(working.body)
    check(
      working.status == 200 && workingResult["resultType"] as? String == "complete" && workingResult["status"] as? String == "working"
        && workingResult["statusMessage"] as? String == "Waiting for the current run to finish" && workingResult["ttlMs"] is NSNull,
      "tasks/get on the waiting task: working (\(working.raw.prefix(200)))")
    let noName = await task("tasks/get", taskID, name: .some(nil))
    check(noName.status == 400 && code(noName.body) == -32020, "tasks/get without Mcp-Name: 400 -32020 (got \(noName.status) \(code(noName.body) ?? 0))")
    let wrongName = await task("tasks/get", taskID, name: "job-other")
    check(wrongName.status == 400 && code(wrongName.body) == -32020, "tasks/get with another Mcp-Name: 400 -32020")
    let undeclared = await task("tasks/get", taskID, declares: false)
    let required = ((undeclared.body["error"] as? [String: Any])?["data"] as? [String: Any])?["requiredCapabilities"] as? [String: Any]
    check(
      undeclared.status == 400 && code(undeclared.body) == -32021 && (required?["extensions"] as? [String: Any])?[tasksID] is [String: Any],
      "tasks/get from a request that doesn't declare the extension: 400 -32021 naming it (got \(undeclared.status) \(code(undeclared.body) ?? 0))")
    let unknownID = AgentTasks.newJobID()
    let unknown = await task("tasks/get", unknownID)
    check(code(unknown.body) == -32602, "tasks/get for an unknown task: -32602")
    let update = await task("tasks/update", taskID, ["inputResponses": [String: Any]()])
    let updated = result(update.body)
    check(
      update.status == 200 && updated["resultType"] as? String == "complete" && Set(updated.keys) == ["resultType", "_meta"],
      "tasks/update: an empty ack (\(update.raw.prefix(200)))")
    let badUpdate = await task("tasks/update", taskID)
    check(code(badUpdate.body) == -32602, "tasks/update without inputResponses: -32602")
    let unknownCancel = await task("tasks/cancel", unknownID)
    check(code(unknownCancel.body) == -32602, "tasks/cancel for an unknown task: -32602")

    let cancel = await task("tasks/cancel", taskID)
    check(cancel.status == 200 && result(cancel.body)["resultType"] as? String == "complete", "tasks/cancel: an ack")
    var cancelledStatus = ""
    for _ in 0..<50 where cancelledStatus != "cancelled" {
      cancelledStatus = result(await task("tasks/get", taskID).body)["status"] as? String ?? ""
      if cancelledStatus != "cancelled" { try? await Task.sleep(for: .milliseconds(200)) }
    }
    let cancelledTask = result(await task("tasks/get", taskID).body)
    check(
      cancelledStatus == "cancelled" && cancelledTask["result"] == nil && cancelledTask["pollIntervalMs"] == nil && cancelledTask["ttlMs"] is Int,
      "the cancelled task reads cancelled, with no result (got \(cancelledStatus))")
    let cancelAgain = await task("tasks/cancel", taskID)
    check(result(cancelAgain.body)["resultType"] as? String == "complete", "tasks/cancel on a task that's over: an ack")

    // Another one, polled to the end once the Queue runs.
    let second = result(await callTool("edit_image_look", look(0.13)).body)
    let secondID = second["taskId"] as? String ?? ""
    model.setQueuePaused(false)
    var final: [String: Any] = [:]
    for _ in 0..<300 {
      final = result(await task("tasks/get", secondID).body)
      if final["status"] as? String != "working" { break }
      try? await Task.sleep(for: .milliseconds(200))
    }
    let finalResult = final["result"] as? [String: Any]
    let finalStructured = finalResult?["structuredContent"] as? [String: Any]
    check(
      second["resultType"] as? String == "task" && final["status"] as? String == "completed" && finalStructured?["history_step"] is Int
        && finalStructured?["job_id"] as? String == secondID && finalResult?["isError"] as? Bool != true
        && (final["ttlMs"] as? Int ?? 0) >= 3_600_000 && final["pollIntervalMs"] == nil,
      "tasks/get polls a task to completed, with the step in its result and an hour's ttlMs (\(final["status"] ?? "no status"))")
    let remote = await task("tasks/get", secondID, host: lan, token: token)
    check(
      remote.status == 200 && result(remote.body)["status"] as? String == "completed"
        && !remote.raw.contains("/Users/") && !remote.raw.contains(NSHomeDirectory()),
      "tasks/get from another device: the result without paths")

    let taskResult = await task("tasks/result", secondID)
    check(taskResult.status == 404 && code(taskResult.body) == -32601, "tasks/result: 404 -32601 (got \(taskResult.status))")
    let taskList = await post("127.0.0.1", message("tasks/list"), nil, headers("tasks/list"))
    check(taskList.status == 404 && code(taskList.body) == -32601, "tasks/list: 404 -32601 (got \(taskList.status))")
    let legacy = await post("127.0.0.1", ["jsonrpc": "2.0", "id": 91, "method": "tasks/get", "params": ["taskId": secondID]], nil, [:])
    check(legacy.status == 200 && code(legacy.body) == -32601, "a 2025 tasks/get: 200 -32601 (got \(legacy.status))")
    let legacyUpdate = await post(
      "127.0.0.1", ["jsonrpc": "2.0", "id": 92, "method": "tasks/update", "params": ["taskId": secondID, "inputResponses": [String: Any]()]], nil, [:])
    check(legacyUpdate.status == 200 && code(legacyUpdate.body) == -32601, "a 2025 tasks/update: 200 -32601 (got \(legacyUpdate.status) \(code(legacyUpdate.body) ?? 0))")

    let badArguments = result(await callTool("edit_image_look", ["history_step": 999_999]).body)
    check(
      badArguments["resultType"] as? String == "complete" && badArguments["isError"] as? Bool == true && badArguments["taskId"] == nil,
      "tasks: a declaring call with bad arguments is answered inline with isError")
    let notJob = result(await callTool("list_skills", [:]).body)
    check(notJob["resultType"] as? String == "complete" && notJob["taskId"] == nil, "tasks: a tool that isn't a job answers inline")
  }
}
#endif
