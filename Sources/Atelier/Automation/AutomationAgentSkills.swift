#if os(macOS)
import Foundation

extension Automation {
  /// The MCP server's skills, as PASS/FAIL lines, from a server of its own (settings and token
  /// in memory, a spare port) over a skills store of its own: temporary folders for yours and
  /// Atelier's, holding the extension spec's pdf-processing skill, a skill with a binary file and
  /// a word that isn't a tool, one that's invalid (no description) and one of yours overriding
  /// one of Atelier's. Every skills assertion runs twice, as a 2025 client (no headers or
  /// `_meta`, results without caching fields) and as a 2026-07-28 one (headers and `_meta`;
  /// results with resultType, ttlMs and cacheScope): skills/list's entries, and each digest
  /// against the SHA-256 of what resources/read returns; skills/get for a skill and for an
  /// unknown one (-32602); resources/directory/read of a skill's top and a subfolder, and of a
  /// file (-32602); list_skills and read_skill. Then, in both eras: a file edited on disk shows a
  /// new digest; a skill turned off isn't served (-32602); this Mac's local network address with
  /// the token gets skills and no paths; a draft saved through the editor shows its new digest.
  /// The modern resources/read without Mcp-Name is refused (-32020), and the invalid skill is
  /// listed in the store with its problem but not served.
  ///
  /// Then the Skills screen, on the app's own store (which in this run reads these fixtures:
  /// `SkillStore.makeForApp`): selecting a skill there makes its draft; the selection, tab and
  /// filter survive leaving the screen and coming back and aren't written to the user's
  /// settings; an unsaved edit stays in its draft when another skill is selected and the quit
  /// warning names it. `--snapshot-dir DIR` saves skills-list.png, skills-instructions.png,
  /// skills-files.png, skills-agent.png and skills-builtin.png (Atelier's own skill, with its
  /// banner). Needs no model and never touches the user's skills, settings or Keychain.
  ///
  ///   Atelier --agent-skills-check [--snapshot-dir DIR] [--quit]
  static func agentSkillsCheck(_ model: CreateModel, presets: PresetStore, navigation: Navigation) {
    let args = CommandLine.arguments
    let snapshotDir = args.firstIndex(of: "--snapshot-dir").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      // The app's store, so the Skills screen shows the fixtures; its folders are temporary in a
      // scripted run, Atelier's own included for this check.
      guard let store = Automation.skills, let builtIn = store.builtInDirectory, builtIn != SkillStore.bundledDirectory else {
        print("FAIL the app's skills store reads a temporary folder for Atelier's skills")
        if args.contains("--quit") { AppLifecycle.quit() }
        return
      }
      let user = store.userDirectory
      let root = user.deletingLastPathComponent()
      var server: AgentServer?
      @MainActor func finish() {
        server?.isEnabled = false
        try? FileManager.default.removeItem(at: root)
        print(failures == 0 ? "agent skills check: all passed" : "agent skills check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      guard let defaults = MemoryDefaults(suiteName: nil) else {
        check(false, "scratch settings")
        return finish()
      }

      // The fixtures.
      func write(_ folder: URL, _ name: String, _ files: [String: Data]) {
        for (path, data) in files {
          let url = folder.appending(path: "\(name)/\(path)")
          try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          try? data.write(to: url)
        }
      }
      func skillFile(_ name: String, _ description: String, _ body: String = "Body.\n") -> Data {
        Data("---\nname: \(name)\ndescription: \(description)\n---\n\(body)".utf8)
      }
      let pdfSkill = Data(
        "---\nname: pdf-processing\ndescription: Extract, fill, and assemble PDF documents\n---\n\n# PDF processing\n\nChoose the matching template from `templates/`.\n".utf8)
      write(
        user, "pdf-processing",
        [
          "SKILL.md": pdfSkill, "templates/invoice.md": Data("# Invoice\n\nCustomer:\nAmount:\n".utf8),
          "templates/purchase-order.md": Data("# Purchase order\n\nSupplier:\nItems:\n".utf8),
        ])
      let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0xFE])
      write(user, "image-kit", ["SKILL.md": skillFile("image-kit", "Makes images.", "Call `generate`, then `fake_tool_name`.\n"), "assets/logo.png": png])
      write(user, "broken", ["SKILL.md": Data("---\nname: broken\n---\nNo description.\n".utf8)])
      write(user, "shared", ["SKILL.md": skillFile("shared", "Mine")])
      write(builtIn, "shared", ["SKILL.md": skillFile("shared", "Atelier's")])
      write(builtIn, "git-workflow", ["SKILL.md": skillFile("git-workflow", "Follow this team's Git conventions")])
      check(SkillFrontmatter.validate(["name": "a"], directoryName: "a").contains { $0.field == "description" }, "the broken fixture is invalid by the rules")

      await store.reload()
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
      let started = AgentServer(create: model, presets: presets, skills: store, defaults: defaults, secrets: MemorySecretStore(), commandLine: false)
      server = started
      let deadline = Date().addingTimeInterval(10)
      while !started.isListening, started.listenError == nil, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      check(started.isListening, "listens at port \(port)\(started.listenError.map { ": \($0)" } ?? "")")
      guard started.isListening, let token = started.token else { return finish() }

      let session = URLSession(configuration: .ephemeral)
      enum Era: String { case legacy, modern }
      struct Reply {
        var status: Int
        var body: [String: Any]
        var raw: String
        var result: [String: Any]? { body["result"] as? [String: Any] }
        var errorCode: Int? { (body["error"] as? [String: Any])?["code"] as? Int }
      }
      var nextID = 100
      /// One request as `era` speaks it; `name` is what goes in Mcp-Name (nil leaves it out).
      func rpc(
        _ era: Era, _ method: String, _ params: [String: Any] = [:], name: String? = nil, host: String = "127.0.0.1", token: String? = nil
      ) async -> Reply {
        nextID += 1
        var params = params
        var request = URLRequest(url: URL(string: AgentAuth.endpoint(host: host, port: port))!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if era == .modern {
          params["_meta"] = [
            AgentProtocol.versionKey: "2026-07-28", AgentProtocol.clientCapabilitiesKey: [String: Any](),
            "io.modelcontextprotocol/clientInfo": ["name": "agent-skills-check", "version": "1"],
          ]
          request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
          request.setValue(method, forHTTPHeaderField: "Mcp-Method")
          if let name { request.setValue(name, forHTTPHeaderField: "Mcp-Name") }
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
          return Reply(status: 0, body: [:], raw: "")
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Reply(status: http.statusCode, body: body, raw: String(decoding: data, as: UTF8.self))
      }
      /// Whether a result carries its era's fields: resultType, ttlMs and cacheScope on 2026-07-28
      /// (ttlMs only for a cacheable one), none of them on 2025.
      func shaped(_ reply: Reply, _ era: Era, cacheable: Bool = true) -> Bool {
        guard let result = reply.result else { return false }
        switch era {
        case .legacy: return result["resultType"] == nil && result["ttlMs"] == nil && result["cacheScope"] == nil
        case .modern:
          return result["resultType"] as? String == "complete"
            && (cacheable ? result["ttlMs"] as? Int == 60_000 && result["cacheScope"] as? String == "private" : result["ttlMs"] == nil)
        }
      }
      func text(_ reply: Reply) -> String {
        ((reply.result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
      }
      /// A file's bytes from resources/read.
      func bytes(_ reply: Reply) -> Data? {
        guard let content = (reply.result?["contents"] as? [[String: Any]])?.first else { return nil }
        if let text = content["text"] as? String { return Data(text.utf8) }
        return (content["blob"] as? String).flatMap { Data(base64Encoded: $0) }
      }
      func entries(_ reply: Reply) -> [[String: Any]] { reply.result?["skills"] as? [[String: Any]] ?? [] }
      func digest(of file: String, in skill: [String: Any]?) -> String? {
        (skill?["resources"] as? [[String: Any]])?.first { $0["uri"] as? String == file }?["digest"] as? String
      }

      for era in [Era.legacy, .modern] {
        let e = era.rawValue
        let list = await rpc(era, "skills/list")
        let uris = entries(list).compactMap { $0["uri"] as? String }
        check(
          list.status == 200 && uris == ["skill://git-workflow/SKILL.md", "skill://image-kit/SKILL.md", "skill://pdf-processing/SKILL.md", "skill://shared/SKILL.md"],
          "\(e) skills/list: the valid skills, yours over Atelier's (got \(list.status) \(uris))")
        check(shaped(list, era), "\(e) skills/list carries \(era == .modern ? "resultType, ttlMs and cacheScope" : "no caching fields")")
        let shared = entries(list).first { $0["uri"] as? String == "skill://shared/SKILL.md" }
        check((shared?["frontmatter"] as? [String: Any])?["description"] as? String == "Mine", "\(e) the user's shared overrides Atelier's")
        var verified = 0
        var mismatched: [String] = []
        for entry in entries(list) {
          for resource in entry["resources"] as? [[String: Any]] ?? [] {
            guard let uri = resource["uri"] as? String else { continue }
            let read = await rpc(era, "resources/read", ["uri": uri], name: uri)
            if let data = bytes(read), SkillScanner.digest(data) == resource["digest"] as? String, data.count == resource["size"] as? Int, shaped(read, era) {
              verified += 1
            } else {
              mismatched.append(uri)
            }
          }
        }
        check(mismatched.isEmpty && verified == 7, "\(e) every listed digest and size matches resources/read (\(verified) files\(mismatched.isEmpty ? "" : ", not \(mismatched)"))")
        let logo = await rpc(era, "resources/read", ["uri": "skill://image-kit/assets/logo.png"], name: "skill://image-kit/assets/logo.png")
        let logoContent = (logo.result?["contents"] as? [[String: Any]])?.first
        check(logoContent?["blob"] != nil && logoContent?["mimeType"] as? String == "image/png", "\(e) a binary file comes as a base64 blob")
        let get = await rpc(era, "skills/get", ["uri": "skill://pdf-processing/SKILL.md"])
        check(
          (get.result?["skill"] as? [String: Any])?["uri"] as? String == "skill://pdf-processing/SKILL.md" && shaped(get, era),
          "\(e) skills/get pdf-processing")
        let unknown = await rpc(era, "skills/get", ["uri": "skill://broken/SKILL.md"])
        check(unknown.errorCode == -32602, "\(e) skills/get of a skill not served: -32602 (got \(unknown.errorCode.map(String.init) ?? "\(unknown.status)"))")
        let top = await rpc(era, "resources/directory/read", ["uri": "skill://pdf-processing"])
        let topURIs = Set((top.result?["resources"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String })
        check(topURIs == ["skill://pdf-processing/SKILL.md", "skill://pdf-processing/templates"] && shaped(top, era), "\(e) directory read of the skill's top: \(topURIs.sorted())")
        let sub = await rpc(era, "resources/directory/read", ["uri": "skill://pdf-processing/templates"])
        check((sub.result?["resources"] as? [[String: Any]])?.count == 2, "\(e) directory read of templates: two files")
        let notFolder = await rpc(era, "resources/directory/read", ["uri": "skill://pdf-processing/SKILL.md"])
        check(notFolder.errorCode == -32602, "\(e) directory read of a file: -32602")
        let listTool = await rpc(era, "tools/call", ["name": "list_skills", "arguments": [String: Any]()], name: "list_skills")
        check(text(listTool).contains("\"pdf-processing\"") && !text(listTool).contains("broken") && shaped(listTool, era, cacheable: false), "\(e) list_skills")
        let readTool = await rpc(era, "tools/call", ["name": "read_skill", "arguments": ["name": "pdf-processing"]], name: "read_skill")
        check(text(readTool) == String(decoding: pdfSkill, as: UTF8.self), "\(e) read_skill gives SKILL.md")
        let binaryTool = await rpc(era, "tools/call", ["name": "read_skill", "arguments": ["name": "image-kit", "path": "assets/logo.png"]], name: "read_skill")
        check(text(binaryTool).contains("isn't text"), "\(e) read_skill describes a binary file (\(text(binaryTool)))")
        let discover = await rpc(era, era == .modern ? "server/discover" : "initialize", era == .modern ? [:] : ["protocolVersion": "2025-11-25"])
        let capabilities = discover.result?["capabilities"] as? [String: Any]
        check(
          ((capabilities?["extensions"] as? [String: Any])?[AgentProtocol.skillsExtension] as? [String: Any])?["directoryRead"] as? Bool == true
            && capabilities?["resources"] != nil,
          "\(e) \(era == .modern ? "server/discover" : "initialize") declares resources and the skills extension with directoryRead")
      }
      let noName = await rpc(.modern, "resources/read", ["uri": "skill://pdf-processing/SKILL.md"])
      check(noName.status == 400 && noName.errorCode == -32020, "modern resources/read without Mcp-Name: 400 -32020 (got \(noName.status) \(noName.errorCode ?? 0))")

      // A file edited on disk.
      let before = digest(of: "skill://pdf-processing/templates/invoice.md", in: (await rpc(.legacy, "skills/get", ["uri": "skill://pdf-processing/SKILL.md"])).result?["skill"] as? [String: Any])
      let edited = Data("# Invoice\n\nCustomer:\nAmount:\nDue:\n".utf8)
      try? edited.write(to: user.appending(path: "pdf-processing/templates/invoice.md"))
      for era in [Era.legacy, .modern] {
        let after = digest(of: "skill://pdf-processing/templates/invoice.md", in: (await rpc(era, "skills/get", ["uri": "skill://pdf-processing/SKILL.md"])).result?["skill"] as? [String: Any])
        check(after != before && after == SkillScanner.digest(edited), "\(era.rawValue) an edit on disk shows its new digest")
      }

      // Turned off.
      if let imageKit = store.skills.first(where: { $0.name == "image-kit" }) {
        store.setEnabled(imageKit, false)
        for era in [Era.legacy, .modern] {
          let off = await rpc(era, "skills/get", ["uri": "skill://image-kit/SKILL.md"])
          let listed = entries(await rpc(era, "skills/list")).contains { $0["uri"] as? String == "skill://image-kit/SKILL.md" }
          check(off.errorCode == -32602 && !listed, "\(era.rawValue) a skill turned off isn't served")
        }
        store.setEnabled(imageKit, true)
      } else {
        check(false, "found image-kit in the store")
      }

      // Another device.
      let home = NSHomeDirectory()
      for era in [Era.legacy, .modern] {
        let missing = await rpc(era, "skills/list", host: lan)
        check(missing.status == 401, "\(era.rawValue) \(lan) without the token: 401 (got \(missing.status))")
        let remote = await rpc(era, "skills/list", host: lan, token: token)
        let read = await rpc(era, "resources/read", ["uri": "skill://pdf-processing/SKILL.md"], name: "skill://pdf-processing/SKILL.md", host: lan, token: token)
        let tool = await rpc(era, "tools/call", ["name": "list_skills", "arguments": [String: Any]()], name: "list_skills", host: lan, token: token)
        let leaks = [remote, read, tool].filter { $0.raw.contains(home) || $0.raw.contains(root.path) || $0.raw.contains("/Users/") }
        check(remote.status == 200 && entries(remote).count == 4 && bytes(read) == pdfSkill && leaks.isEmpty, "\(era.rawValue) \(lan) with the token gets skills and no paths")
      }

      // A draft saved from the editor.
      if let pdf = store.skills.first(where: { $0.name == "pdf-processing" }) {
        let draft = store.draft(for: pdf)
        draft.body += "\nSaved from the editor.\n"
        do {
          try await draft.save()
          let expected = SkillScanner.digest(draft.skillFileData)
          for era in [Era.legacy, .modern] {
            let saved = digest(of: "skill://pdf-processing/SKILL.md", in: (await rpc(era, "skills/get", ["uri": "skill://pdf-processing/SKILL.md"])).result?["skill"] as? [String: Any])
            check(saved == expected, "\(era.rawValue) a draft saved through the editor shows its new digest")
          }
        } catch {
          check(false, "saved the draft: \(error.localizedDescription)")
        }
      }

      let broken = store.skills.first { $0.name == "broken" }
      check(broken != nil && broken?.isServed == false && broken?.issues.contains { $0.contains("description") } == true, "the invalid skill is listed with its problem: \(broken?.issues ?? [])")
      check(
        store.skills.first { $0.id == "builtIn/shared" }?.overridden == true && store.served.allSatisfy { $0.id != "builtIn/shared" },
        "Atelier's shared is overridden by yours")
      let known = SkillToolCheck.knownNames(AgentTools.definitions)
      let imageKitText = String(decoding: skillFile("image-kit", "Makes images.", "Call `generate`, then `fake_tool_name`.\n"), as: UTF8.self)
      check(SkillToolCheck.scan([imageKitText], known: known).unknown == ["fake_tool_name"], "the tool-name check flags fake_tool_name only")

      await skillsScreenCheck(store, navigation: navigation, snapshotDir: snapshotDir, check: check)
      finish()
    }
  }

  /// The Skills screen part of `--agent-skills-check`, on the app's store.
  @MainActor
  private static func skillsScreenCheck(_ store: SkillStore, navigation: Navigation, snapshotDir: URL?, check: (Bool, String) -> Void) async {
    func settle() async { try? await Task.sleep(for: .milliseconds(800)) }
    func shot(_ name: String) {
      guard let snapshotDir else { return }
      snapshot(to: snapshotDir.appending(path: name))
      check(FileManager.default.fileExists(atPath: snapshotDir.appending(path: name).path), "saved \(name)")
    }
    let savedSelection = UserDefaults.standard.object(forKey: "skillsSelection") as? String
    let savedTab = UserDefaults.standard.object(forKey: "skillsTab") as? String
    let wasSection = navigation.section
    store.screenSelection = nil
    store.screenSearch = ""
    store.screenTab = SkillDetailView.Tab.instructions.rawValue
    navigation.section = .skills
    await settle()
    shot("skills-list.png")

    let pdfID = "user/pdf-processing"
    store.drafts[pdfID] = nil
    store.screenSelection = pdfID
    await settle()
    check(store.drafts[pdfID] != nil, "selecting a skill on the screen makes its draft")
    shot("skills-instructions.png")
    store.screenTab = SkillDetailView.Tab.files.rawValue
    await settle()
    shot("skills-files.png")
    store.screenTab = SkillDetailView.Tab.agent.rawValue
    await settle()
    shot("skills-agent.png")

    // Leaving the screen and coming back.
    store.screenTab = SkillDetailView.Tab.files.rawValue
    store.screenSearch = "pdf"
    navigation.section = .create
    await settle()
    navigation.section = .skills
    await settle()
    check(
      store.screenSelection == pdfID && store.screenTab == "files" && store.screenSearch == "pdf",
      "selection, tab and filter survive leaving the screen (\(store.screenSelection ?? "none"), \(store.screenTab), \(store.screenSearch))")
    check(
      UserDefaults.standard.object(forKey: "skillsSelection") as? String == savedSelection && UserDefaults.standard.object(forKey: "skillsTab") as? String == savedTab,
      "a scripted run doesn't write the screen's state to the user's settings")

    // An unsaved edit, kept while another skill is shown, and named by the quit warning.
    store.screenSearch = ""
    if let imageKit = store.skills.first(where: { $0.id == "user/image-kit" }) {
      let draft = store.draft(for: imageKit)
      draft.description += " Edited."
      store.screenSelection = pdfID
      await settle()
      check(store.drafts[imageKit.id]?.isDirty == true, "an unsaved edit stays in its draft while another skill is shown")
      let warning = AppLifecycle.unsavedEdits?() ?? ""
      check(warning.contains("image-kit"), "the quit warning names the skill with unsaved edits: \(warning)")
      draft.revert()
      check(AppLifecycle.unsavedEdits?() == nil, "after Revert the quit warning has nothing to name")
    } else {
      check(false, "found image-kit on the screen")
    }

    // Atelier's own skill: read-only, with its banner.
    store.screenSelection = "builtIn/git-workflow"
    store.screenTab = SkillDetailView.Tab.instructions.rawValue
    await settle()
    check(store.drafts["builtIn/git-workflow"]?.isBuiltIn == true, "Atelier's skill opens read-only")
    shot("skills-builtin.png")
    navigation.section = wasSection
  }
}
#endif
