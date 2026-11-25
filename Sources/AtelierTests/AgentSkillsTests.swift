@testable import Atelier
import Foundation
import Testing
import ZIPFoundation

/// A scratch skills folder pair (yours and Atelier's) for one test, removed afterwards.
@MainActor
final class SkillFixture {
  let root: URL
  let user: URL
  let builtIn: URL
  let defaults: MemoryDefaults

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "atelier-skills-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    user = root.appending(path: "user", directoryHint: .isDirectory)
    builtIn = root.appending(path: "builtin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
    defaults = MemoryDefaults(suiteName: nil)!
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func store() -> SkillStore {
    SkillStore(userDirectory: user, builtInDirectory: builtIn, defaults: defaults, persistsScreenState: false, usesTrash: false, loads: false)
  }

  /// Writes `files` (path → text) as a skill folder named `name` in `folder`.
  @discardableResult func write(_ name: String, in folder: URL? = nil, _ files: [String: String]) throws -> URL {
    let directory = (folder ?? user).appending(path: name, directoryHint: .isDirectory)
    for (path, text) in files {
      let url = directory.appending(path: path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    return directory
  }

  /// The spec's pdf-processing skill (Skills: Example Message Flow).
  @discardableResult func writePDFSkill(in folder: URL? = nil) throws -> URL {
    try write(
      "pdf-processing", in: folder,
      [
        "SKILL.md": SkillFrontmatterTests.pdfSkill,
        "templates/invoice.md": "# Invoice\n\nCustomer:\nAmount:\n",
        "templates/purchase-order.md": "# Purchase order\n\nSupplier:\nItems:\n",
      ])
  }

  static func skillFile(_ name: String, description: String = "A test skill.", body: String = "Body.\n") -> String {
    "---\nname: \(name)\ndescription: \(description)\n---\n\(body)"
  }
}

@Suite(.serialized)
@MainActor
struct AgentSkillsTests {
  @Test func specDigests() async throws {
    let fixture = try SkillFixture()
    try fixture.writePDFSkill()
    let store = fixture.store()
    await store.reload()
    let skill = try #require(store.served.first)
    #expect(skill.uri == "skill://pdf-processing/SKILL.md")
    #expect(skill.file("SKILL.md") == SkillFile(relPath: "SKILL.md", size: 151, digest: "sha256:99b737495721155ece826d57521e2d66141ebdc1344a400487481ea2642ab19e", mimeType: "text/markdown"))
    #expect(skill.file("templates/invoice.md")?.digest == "sha256:61f4ea6d2c75fde1b4977219e7e3107d491c3c26aefb6686e84d6281c088d9ee")
    #expect(skill.file("templates/invoice.md")?.size == 29)
    #expect(skill.file("templates/purchase-order.md")?.digest == "sha256:f2ff774b1737ff3dec81c47946f9976f18a1a9f69dda0a81f22eabd95173c158")
    #expect(skill.directories == ["templates"])
  }

  @Test func limits() async throws {
    let fixture = try SkillFixture()
    var files = ["SKILL.md": SkillFixture.skillFile("many")]
    for index in 0..<512 { files["f\(index).txt"] = "x" }
    try fixture.write("many", files)
    let big = try fixture.write("big", ["SKILL.md": SkillFixture.skillFile("big")])
    // Sparse: 17 MiB on paper, nothing on disk.
    let handle = try FileHandle(forWritingTo: { let url = big.appending(path: "huge.bin"); FileManager.default.createFile(atPath: url.path, contents: nil); return url }())
    try handle.truncate(atOffset: UInt64(17 << 20))
    try handle.close()
    var fine = ["SKILL.md": SkillFixture.skillFile("fine")]
    for index in 0..<511 { fine["f\(index).txt"] = "x" }
    try fixture.write("fine", fine)
    let store = fixture.store()
    await store.reload()
    let many = try #require(store.skills.first { $0.name == "many" })
    #expect(!many.isValid && many.issues.contains { $0.contains("512") }, "513 files")
    #expect(many.files.isEmpty, "an invalid skill isn't hashed")
    let tooBig = try #require(store.skills.first { $0.name == "big" })
    #expect(!tooBig.isValid && tooBig.issues.contains { $0.contains("16 MiB") })
    #expect(store.served.map(\.name) == ["fine"], "512 files is the limit, not past it")
  }

  @Test func linksAndHiddenFiles() async throws {
    let fixture = try SkillFixture()
    let linked = try fixture.write("linked", ["SKILL.md": SkillFixture.skillFile("linked")])
    try FileManager.default.createSymbolicLink(atPath: linked.appending(path: "escape").path, withDestinationPath: "/etc")
    let hidden = try fixture.write("hidden", ["SKILL.md": SkillFixture.skillFile("hidden"), ".secret": "x", ".git/config": "y"])
    _ = hidden
    try FileManager.default.createSymbolicLink(atPath: fixture.user.appending(path: "folder-link").path, withDestinationPath: linked.path)
    try fixture.write(".hidden-skill", ["SKILL.md": SkillFixture.skillFile("hidden-skill")])
    let store = fixture.store()
    await store.reload()
    #expect(store.skills.first { $0.name == "linked" }?.issues.contains { $0.contains("link") } == true)
    #expect(store.skills.first { $0.name == "folder-link" }?.isValid == false)
    #expect(store.served.map(\.name) == ["hidden"])
    #expect(store.served.first?.files.map(\.relPath) == ["SKILL.md"], "hidden files aren't part of the skill")
  }

  @Test func overrideAndDisable() async throws {
    let fixture = try SkillFixture()
    try fixture.write("shared", in: fixture.builtIn, ["SKILL.md": SkillFixture.skillFile("shared", description: "Atelier's")])
    try fixture.write("ours", in: fixture.builtIn, ["SKILL.md": SkillFixture.skillFile("ours")])
    try fixture.write("shared", ["SKILL.md": SkillFixture.skillFile("shared", description: "Mine")])
    let store = fixture.store()
    await store.reload()
    #expect(store.skills.map(\.id) == ["builtIn/ours", "user/shared", "builtIn/shared"])
    #expect(store.skills.first { $0.id == "builtIn/shared" }?.overridden == true)
    #expect(store.served.map(\.id) == ["builtIn/ours", "user/shared"])
    #expect(store.served(uri: "skill://shared/SKILL.md")?.skill.summary == "Mine")
    let ours = try #require(store.skills.first { $0.name == "ours" })
    store.setEnabled(ours, false)
    #expect(store.served.map(\.name) == ["shared"])
    #expect(fixture.defaults.object(forKey: SkillStore.disabledKey) as? [String] == ["ours"])
    await store.reload()
    #expect(store.served.map(\.name) == ["shared"], "stays off after a rescan")
    store.setEnabled(ours, true)
    #expect(store.served.count == 2)
  }

  @Test func editOnDiskChangesDigest() async throws {
    let fixture = try SkillFixture()
    let folder = try fixture.writePDFSkill()
    let store = fixture.store()
    let before = await store.current().first?.file("templates/invoice.md")?.digest
    try Data("# Invoice\n\nChanged\n".utf8).write(to: folder.appending(path: "templates/invoice.md"))
    let after = await store.current().first?.file("templates/invoice.md")
    #expect(before != nil && after?.digest != before)
    #expect(after?.digest == SkillScanner.digest(Data("# Invoice\n\nChanged\n".utf8)))
    // A read of bytes the listing doesn't describe rescans first.
    try Data("# Invoice v3\n".utf8).write(to: folder.appending(path: "templates/invoice.md"))
    let read = try await store.read(uri: "skill://pdf-processing/templates/invoice.md")
    #expect(read?.data == Data("# Invoice v3\n".utf8))
    #expect(read?.file.digest == SkillScanner.digest(Data("# Invoice v3\n".utf8)))
  }

  private func zip(_ entries: [(path: String, data: Data?)], symlink: String? = nil) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "atelier-skill-\(UUID().uuidString).zip")
    let archive = try #require(Archive(url: url, accessMode: .create))
    for (path, data) in entries {
      if let data {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { (position: Int64, size: Int) in data.subdata(in: Int(position)..<Int(position) + size) })
      } else {
        try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0), provider: { (_: Int64, _: Int) in Data() })
      }
    }
    if let symlink {
      let target = Data("/etc/passwd".utf8)
      try archive.addEntry(with: symlink, type: .symlink, uncompressedSize: Int64(target.count), provider: { (position: Int64, size: Int) in target.subdata(in: Int(position)..<Int(position) + size) })
    }
    return url
  }

  @Test func zipImport() async throws {
    let fixture = try SkillFixture()
    let store = fixture.store()
    let wrapped = try zip([
      ("zipped/", nil), ("zipped/SKILL.md", Data(SkillFixture.skillFile("zipped").utf8)), ("zipped/notes/a.md", Data("a".utf8)),
      ("__MACOSX/zipped/._SKILL.md", Data("junk".utf8)), ("zipped/.DS_Store", Data("x".utf8)),
    ])
    defer { try? FileManager.default.removeItem(at: wrapped) }
    let imported = try await store.importItem(at: wrapped)
    #expect(imported.name == "zipped" && imported.isValid, "a single top folder is unwrapped")
    #expect(imported.files.map(\.relPath) == ["SKILL.md", "notes/a.md"])
    await #expect(throws: SkillStore.Failure.self, "the name is taken") { try await store.importItem(at: wrapped) }

    let slip = try zip([("SKILL.md", Data(SkillFixture.skillFile("slip").utf8)), ("../escape.md", Data("x".utf8))])
    defer { try? FileManager.default.removeItem(at: slip) }
    await #expect(throws: (any Error).self) { try await store.importItem(at: slip) }
    #expect(!FileManager.default.fileExists(atPath: fixture.user.deletingLastPathComponent().appending(path: "escape.md").path))

    let absolute = try zip([("SKILL.md", Data(SkillFixture.skillFile("absolute").utf8)), ("/tmp/atelier-zip-slip.md", Data("x".utf8))])
    defer { try? FileManager.default.removeItem(at: absolute) }
    await #expect(throws: (any Error).self) { try await store.importItem(at: absolute) }

    let link = try zip([("SKILL.md", Data(SkillFixture.skillFile("linky").utf8))], symlink: "passwd")
    defer { try? FileManager.default.removeItem(at: link) }
    await #expect(throws: (any Error).self) { try await store.importItem(at: link) }
    await store.reload()
    #expect(store.skills.map(\.name) == ["zipped"], "nothing refused was left behind")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.user.path).filter { $0.hasPrefix(".") }
    #expect(leftovers.isEmpty, "staging folders are cleaned up")
  }

  @Test func folderImportDuplicateExportDelete() async throws {
    let fixture = try SkillFixture()
    let source = try fixture.writePDFSkill(in: fixture.root)
    let store = fixture.store()
    let imported = try await store.importItem(at: source)
    #expect(imported.files.count == 3)
    let copy = try await store.duplicate(imported)
    #expect(copy.name == "pdf-processing-copy" && copy.isValid, "the copy's frontmatter name follows its folder: \(copy.issues)")
    #expect(copy.frontmatter?["description"] as? String == "Extract, fill, and assemble PDF documents")
    let zipURL = fixture.root.appending(path: "export.zip")
    try await store.export(copy, to: zipURL)
    try await store.delete(copy)
    #expect(!store.skills.contains { $0.name == copy.name })
    let back = try await store.importItem(at: zipURL)
    #expect(back.name == "pdf-processing-copy" && back.files.map(\.digest) == copy.files.map(\.digest), "export round trip")
    let created = try await store.create(name: "fresh")
    #expect(created.isValid, "\(created.issues)")
    await #expect(throws: SkillStore.Failure.self) { try await store.create(name: "fresh") }
    await #expect(throws: SkillStore.Failure.self) { try await store.create(name: "Bad Name") }
  }

  @Test func uriParsing() {
    #expect(SkillURI.parse("skill://pdf-processing/SKILL.md").map { [$0.skill, $0.path] } == ["pdf-processing", "SKILL.md"])
    #expect(SkillURI.parse("skill://pdf-processing/templates/invoice.md").map { [$0.skill, $0.path] } == ["pdf-processing", "templates/invoice.md"])
    #expect(SkillURI.parse("skill://pdf-processing").map { [$0.skill, $0.path] } == ["pdf-processing", ""])
    #expect(SkillURI.parse("skill://a/my%20file.md").map { [$0.skill, $0.path] } == ["a", "my file.md"])
    for bad in [
      "file:///etc/passwd", "skill:/a/SKILL.md", "Skill://a/SKILL.md", "skill://", "skill://a/", "skill://a//b", "skill://a/../b",
      "skill://a/%2e%2e/b", "skill://a/%2E%2E", "skill://a/./b", "skill://a/b?x=1", "skill://a/b#f", "skill://a/%2fetc", "skill://%2e%2e/x",
    ] {
      #expect(SkillURI.parse(bad) == nil, "\(bad) refused")
    }
    #expect(SkillURI.make(skill: "a", path: "my file.md") == "skill://a/my%20file.md")
    #expect(SkillURI.make(skill: "a", path: "") == "skill://a")
  }

  @Test func rpcShapesAndErrors() async throws {
    let fixture = try SkillFixture()
    try fixture.writePDFSkill()
    try fixture.write("binary", ["SKILL.md": SkillFixture.skillFile("binary"), "logo.png": "\u{89}PNG"])
    let store = fixture.store()
    let rpc = SkillsRPC(store: store)
    func result(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
      if case .success(let value) = await rpc.handle(method, params: params, isRemote: false) { return value }
      return nil
    }
    func code(_ method: String, _ params: [String: Any] = [:]) async -> Int? {
      if case .failure(let error) = await rpc.handle(method, params: params, isRemote: false) { return error.code }
      return nil
    }
    let skills = try #require(await result("skills/list")?["skills"] as? [[String: Any]])
    #expect(skills.count == 2)
    let pdf = try #require(skills.first { $0["uri"] as? String == "skill://pdf-processing/SKILL.md" })
    #expect((pdf["frontmatter"] as? [String: Any])?["name"] as? String == "pdf-processing")
    #expect((pdf["resources"] as? [[String: Any]])?.count == 3)
    let got = try #require(await result("skills/get", ["uri": "skill://pdf-processing/SKILL.md"])?["skill"] as? [String: Any])
    #expect(got["uri"] as? String == "skill://pdf-processing/SKILL.md")
    #expect(await code("skills/get", ["uri": "skill://pdf-processing/templates/invoice.md"]) == -32602, "not a SKILL.md")
    #expect(await code("skills/get", ["uri": "skill://nope/SKILL.md"]) == -32602)
    #expect(await code("skills/get") == -32602)
    let read = try #require((await result("resources/read", ["uri": "skill://pdf-processing/SKILL.md"])?["contents"] as? [[String: Any]])?.first)
    #expect(read["text"] as? String == SkillFrontmatterTests.pdfSkill && read["mimeType"] as? String == "text/markdown")
    let png = try #require((await result("resources/read", ["uri": "skill://binary/logo.png"])?["contents"] as? [[String: Any]])?.first)
    #expect(png["blob"] as? String == Data("\u{89}PNG".utf8).base64EncodedString() && png["text"] == nil && png["mimeType"] as? String == "image/png")
    #expect(await code("resources/read", ["uri": "skill://pdf-processing/missing.md"]) == -32602)
    #expect(await code("resources/read", ["uri": "skill://pdf-processing/../binary/SKILL.md"]) == -32602)
    let root = try #require(await result("resources/directory/read", ["uri": "skill://pdf-processing"])?["resources"] as? [[String: Any]])
    #expect(Set(root.compactMap { $0["uri"] as? String }) == ["skill://pdf-processing/SKILL.md", "skill://pdf-processing/templates"])
    #expect(root.first { $0["uri"] as? String == "skill://pdf-processing/templates" }?["mimeType"] as? String == "inode/directory")
    let templates = try #require(await result("resources/directory/read", ["uri": "skill://pdf-processing/templates"])?["resources"] as? [[String: Any]])
    #expect(templates.compactMap { $0["name"] as? String }.sorted() == ["invoice.md", "purchase-order.md"])
    #expect(await code("resources/directory/read", ["uri": "skill://pdf-processing/SKILL.md"]) == -32602)
    #expect(await code("resources/directory/read", ["uri": "skill://pdf-processing/nothing"]) == -32602)
    let listed = try #require(await result("resources/list")?["resources"] as? [[String: Any]])
    #expect(listed.count == 5)
    let skillResource = try #require(listed.first { $0["uri"] as? String == "skill://pdf-processing/SKILL.md" })
    #expect(skillResource["name"] as? String == "pdf-processing" && skillResource["description"] as? String == "Extract, fill, and assemble PDF documents")
    #expect((await result("resources/templates/list")?["resourceTemplates"] as? [Any])?.isEmpty == true)
    #expect(await code("skills/unknown") == -32601)
  }

  @Test func byteOrderMarkGoesAsBlob() async throws {
    let fixture = try SkillFixture()
    let bom = Data([0xEF, 0xBB, 0xBF]) + Data("# Notes\n".utf8)
    let folder = try fixture.write("bom", ["SKILL.md": SkillFixture.skillFile("bom")])
    try bom.write(to: folder.appending(path: "notes.md"))
    let store = fixture.store()
    let rpc = SkillsRPC(store: store)
    guard case .success(let result) = await rpc.handle("resources/read", params: ["uri": "skill://bom/notes.md"], isRemote: false) else {
      Issue.record("read failed")
      return
    }
    let content = try #require((result["contents"] as? [[String: Any]])?.first)
    #expect(content["text"] == nil)
    let blob = try #require((content["blob"] as? String).flatMap { Data(base64Encoded: $0) })
    #expect(SkillScanner.digest(blob) == store.served.first?.file("notes.md")?.digest, "what's served is what was hashed")
  }

  @Test func readThatKeepsChangingIsAnError() async throws {
    let fixture = try SkillFixture()
    try fixture.writePDFSkill()
    let store = fixture.store()
    await store.reload()
    let changing: @Sendable (URL) throws -> Data = { _ in Data(UUID().uuidString.utf8) }
    await #expect(throws: SkillStore.Failure.self) { try await store.read(uri: "skill://pdf-processing/SKILL.md", reader: changing) }
  }

  @Test func duplicateOfALongName() async throws {
    let fixture = try SkillFixture()
    let long = String(repeating: "a", count: 62) + "-b"
    try fixture.write(long, ["SKILL.md": SkillFixture.skillFile(long)])
    let store = fixture.store()
    await store.reload()
    let original = try #require(store.skills.first)
    let first = try await store.duplicate(original)
    let second = try await store.duplicate(original)
    #expect(first.name.count <= 64 && second.name.count <= 64)
    #expect(first.name.hasSuffix("-copy") && second.name.hasSuffix("-copy-2"))
    #expect(first.isValid && second.isValid, "\(first.issues) \(second.issues)")
  }

  @Test func folderOperationsRefuseLinks() async throws {
    let fixture = try SkillFixture()
    let folder = try fixture.write("linked-ops", ["SKILL.md": SkillFixture.skillFile("linked-ops")])
    let outside = fixture.root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "escape").path, withDestinationPath: outside.path)
    let store = fixture.store()
    await store.reload()
    let skill = try #require(store.skills.first)
    await #expect(throws: SkillStore.Failure.self) { try await store.newFile(skill, at: "escape/planted.md") }
    #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "planted.md").path))
  }

  @Test func zipFolderEntriesCount() async throws {
    let fixture = try SkillFixture()
    let store = fixture.store()
    var entries: [(path: String, data: Data?)] = [("SKILL.md", Data(SkillFixture.skillFile("folders").utf8))]
    for index in 0..<1100 { entries.append(("d\(index)/", nil)) }
    let url = try zip(entries)
    defer { try? FileManager.default.removeItem(at: url) }
    await #expect(throws: (any Error).self) { try await store.importItem(at: url) }
  }
}
