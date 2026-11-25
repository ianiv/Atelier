@testable import Atelier
import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct SkillEditorModelTests {
  private func setUp(_ text: String = "---\nname: editing\ndescription: Before.\nlicense: MIT\nmetadata:\n  team: art\n---\nOld body.\n") async throws -> (SkillFixture, SkillStore, SkillEditorModel) {
    let fixture = try SkillFixture()
    try fixture.write("editing", ["SKILL.md": text, "notes/a.md": "note a\n", "logo.png": "\u{89}PNG"])
    let store = fixture.store()
    await store.reload()
    let skill = try #require(store.skills.first { $0.name == "editing" })
    return (fixture, store, store.draft(for: skill))
  }

  private func skillFile(_ fixture: SkillFixture, _ name: String = "editing") throws -> String {
    try String(contentsOf: fixture.user.appending(path: "\(name)/SKILL.md"), encoding: .utf8)
  }

  @Test func editAndSave() async throws {
    let (fixture, store, draft) = try await setUp()
    #expect(!draft.isDirty && draft.name == "editing" && draft.description == "Before." && draft.body == "Old body.\n")
    #expect(draft.otherYAML == "license: MIT\nmetadata:\n  team: art\n")
    draft.description = "After: with a colon."
    draft.body = "New body.\n"
    #expect(draft.isDirty && store.hasUnsavedEdits && store.unsavedSkillNames == ["editing"])
    #expect(draft.issues.isEmpty, "\(draft.issues)")
    try await draft.save()
    #expect(!draft.isDirty && !store.hasUnsavedEdits)
    #expect(try skillFile(fixture) == "---\nname: editing\ndescription: \"After: with a colon.\"\nlicense: MIT\nmetadata:\n  team: art\n---\nNew body.\n")
    let saved = try #require(store.served.first { $0.name == "editing" })
    #expect(saved.frontmatter?["description"] as? String == "After: with a colon.")
    #expect((saved.frontmatter?["metadata"] as? [String: Any])?["team"] as? String == "art", "other fields survive")
    #expect(saved.files.map(\.relPath) == ["SKILL.md", "logo.png", "notes/a.md"], "untouched files are kept")
    #expect(saved.file("logo.png")?.digest == SkillScanner.digest(Data("\u{89}PNG".utf8)))
  }

  @Test func renameMovesFolderAndURI() async throws {
    let (fixture, store, draft) = try await setUp()
    draft.name = "renamed"
    #expect(draft.issues.isEmpty, "the folder follows the name on Save: \(draft.issues)")
    try await draft.save()
    #expect(!FileManager.default.fileExists(atPath: fixture.user.appending(path: "editing").path))
    #expect(store.served.map(\.uri) == ["skill://renamed/SKILL.md"])
    #expect(store.drafts["user/renamed"] === draft && store.drafts["user/editing"] == nil)
    #expect(draft.skill.name == "renamed" && !draft.isDirty)
  }

  @Test func renameOntoTakenNameWritesNothing() async throws {
    let (fixture, store, draft) = try await setUp()
    try fixture.write("taken", ["SKILL.md": SkillFixture.skillFile("taken")])
    await store.reload()
    let before = try skillFile(fixture)
    draft.name = "taken"
    draft.body = "Changed.\n"
    #expect(draft.issues.contains { $0.contains("already have") })
    await #expect(throws: SkillStore.Failure.self) { try await draft.save() }
    #expect(try skillFile(fixture) == before)
    #expect(try skillFile(fixture, "taken") == SkillFixture.skillFile("taken"))
    #expect(draft.isDirty, "the draft is kept")
  }

  @Test func revert() async throws {
    let (_, _, draft) = try await setUp()
    draft.body = "x"
    try draft.addTextFile(at: "new.md")
    draft.revert()
    #expect(!draft.isDirty && draft.body == "Old body.\n" && draft.entries["new.md"] == nil)
  }

  @Test func externalChange() async throws {
    // The draft holds its store weakly (the store owns its drafts), so the test keeps it.
    let (fixture, store, draft) = try await setUp()
    defer { withExtendedLifetime(store) {} }
    draft.body = "Mine.\n"
    #expect(!draft.diskChanged())
    let theirs = "---\nname: editing\ndescription: Theirs.\n---\nTheirs.\n"
    try Data(theirs.utf8).write(to: fixture.user.appending(path: "editing/SKILL.md"))
    #expect(draft.diskChanged())
    await #expect(throws: SkillEditorModel.Failure.changedOnDisk) { try await draft.save() }
    #expect(try skillFile(fixture) == theirs, "nothing written")
    draft.keepMine()
    try await draft.save()
    #expect(try skillFile(fixture).hasSuffix("---\nMine.\n"), "Keep Mine, then Save, overwrites")

    try Data(theirs.utf8).write(to: fixture.user.appending(path: "editing/SKILL.md"))
    draft.body = "Discarded.\n"
    #expect(draft.diskChanged())
    draft.reloadFromDisk()
    #expect(draft.body == "Theirs.\n" && draft.description == "Theirs." && !draft.isDirty, "Reload drops the draft")
  }

  @Test func fileOperationsApplyOnSave() async throws {
    let (fixture, store, draft) = try await setUp()
    try draft.addTextFile(at: "docs/guide.md", text: "# Guide\n")
    try draft.addFolder(at: "empty")
    try draft.rename("notes", to: "references")
    try draft.remove("logo.png")
    let outside = fixture.root.appending(path: "outside.txt")
    try Data("from outside\n".utf8).write(to: outside)
    try draft.addFiles([outside], into: "references")
    draft.setText("note a, edited\n", for: "references/a.md")
    #expect(throws: SkillEditorModel.Failure.self) { try draft.rename("SKILL.md", to: "README.md") }
    #expect(throws: SkillEditorModel.Failure.self) { try draft.remove("SKILL.md") }
    #expect(throws: SkillEditorModel.Failure.self) { try draft.addTextFile(at: "../escape.md") }
    #expect(throws: SkillEditorModel.Failure.self) { try draft.addTextFile(at: "docs/guide.md") }
    #expect(FileManager.default.fileExists(atPath: fixture.user.appending(path: "editing/logo.png").path), "nothing changes before Save")
    try await draft.save()
    let saved = try #require(store.served.first { $0.name == "editing" })
    #expect(saved.files.map(\.relPath) == ["SKILL.md", "docs/guide.md", "references/a.md", "references/outside.txt"])
    #expect(saved.directories.contains("empty"))
    let edited = try String(contentsOf: fixture.user.appending(path: "editing/references/a.md"), encoding: .utf8)
    #expect(edited == "note a, edited\n")
  }

  @Test func projectedLimits() async throws {
    let (_, _, draft) = try await setUp()
    // SKILL.md, notes/a.md and logo.png are 3; 510 more makes 513.
    for index in 0..<510 { try draft.addTextFile(at: "many/f\(index).txt", text: "x") }
    #expect(draft.totals.files == 513)
    #expect(draft.issues.contains { $0.contains("512") })
    try draft.remove("many/f0.txt")
    #expect(!draft.issues.contains { $0.contains("512") })
  }

  @Test func liveIssues() async throws {
    let (_, _, draft) = try await setUp()
    draft.otherYAML = "license: MIT\nbad: &anchor x\n"
    #expect(draft.otherYAMLError?.line == 2, "the line within the other fields")
    draft.otherYAML = ""
    draft.description = ""
    #expect(draft.issues.contains { $0.contains("description") })
    draft.name = "Not Valid"
    #expect(draft.issues.contains { $0.contains("lowercase") })
  }

  @Test func builtInRefusesSave() async throws {
    let fixture = try SkillFixture()
    try fixture.write("ours", in: fixture.builtIn, ["SKILL.md": SkillFixture.skillFile("ours")])
    let store = fixture.store()
    await store.reload()
    let draft = store.draft(for: try #require(store.skills.first))
    #expect(draft.isBuiltIn)
    draft.body = "x"
    await #expect(throws: SkillEditorModel.Failure.self) { try await draft.save() }
    #expect(throws: SkillEditorModel.Failure.self) { try draft.addTextFile(at: "a.md") }
    #expect(try String(contentsOf: fixture.builtIn.appending(path: "ours/SKILL.md"), encoding: .utf8) == SkillFixture.skillFile("ours"))
  }

  @Test func hiddenFilesSurviveSaves() async throws {
    let (fixture, store, draft) = try await setUp()
    let folder = fixture.user.appending(path: "editing")
    try Data("*.tmp\n".utf8).write(to: folder.appending(path: "notes/.gitignore"))
    try FileManager.default.createDirectory(at: folder.appending(path: ".git/objects"), withIntermediateDirectories: true)
    try Data("[core]\n".utf8).write(to: folder.appending(path: ".git/config"))
    draft.reloadFromDisk()
    #expect(draft.filePaths == ["SKILL.md", "logo.png", "notes/a.md"], "hidden files aren't listed")
    #expect(draft.totals.files == 3)
    draft.body = "Edited.\n"
    try await draft.save()
    let saved = fixture.user.appending(path: "editing")
    #expect(try String(contentsOf: saved.appending(path: "notes/.gitignore"), encoding: .utf8) == "*.tmp\n")
    #expect(try String(contentsOf: saved.appending(path: ".git/config"), encoding: .utf8) == "[core]\n")
    #expect(SkillScanner.stat(saved.appending(path: ".git/objects"))?.isDirectory == true, "an empty hidden folder too")
    // A renamed folder takes its hidden files along.
    try draft.rename("notes", to: "references")
    try await draft.save()
    #expect(try String(contentsOf: saved.appending(path: "references/.gitignore"), encoding: .utf8) == "*.tmp\n")
    #expect(SkillScanner.stat(saved.appending(path: "notes")) == nil)
    #expect(store.served.first { $0.name == "editing" }?.files.map(\.relPath) == ["SKILL.md", "logo.png", "references/a.md"], "and they're not served")
  }

  @Test func overLimitSaveKeepsEveryFile() async throws {
    let fixture = try SkillFixture()
    var files = ["SKILL.md": SkillFixture.skillFile("crowded")]
    for index in 0..<600 { files["many/f\(index).txt"] = "\(index)" }
    try fixture.write("crowded", files)
    let store = fixture.store()
    await store.reload()
    let draft = store.draft(for: try #require(store.skills.first))
    #expect(draft.totals.files == 601)
    draft.body = "Edited.\n"
    try await draft.save()
    let saved = try FileManager.default.contentsOfDirectory(atPath: fixture.user.appending(path: "crowded/many").path)
    #expect(saved.count == 600, "every file past the limit is kept")
    #expect(try String(contentsOf: fixture.user.appending(path: "crowded/many/f599.txt"), encoding: .utf8) == "599")
  }

  @Test func failedSaveLeavesTheOriginal() async throws {
    let (fixture, _, draft) = try await setUp()
    let before = try skillFile(fixture)
    let outside = fixture.root.appending(path: "vanishing.txt")
    try Data("x".utf8).write(to: outside)
    try draft.addFiles([outside])
    draft.body = "Never written.\n"
    try FileManager.default.removeItem(at: outside)
    await #expect(throws: (any Error).self) { try await draft.save() }
    #expect(try skillFile(fixture) == before)
    #expect(FileManager.default.fileExists(atPath: fixture.user.appending(path: "editing/notes/a.md").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.user.path).filter { $0.hasPrefix(".") }.isEmpty, "no staging left behind")
  }

  @Test func invalidYAMLSurvivesASave() async throws {
    let yaml = "name: editing\ndescription: Keeps: this colon\nlicense: MIT\n"
    let (fixture, store, draft) = try await setUp("---\n\(yaml)---\nOld body.\n")
    defer { withExtendedLifetime(store) {} }
    #expect(draft.frontmatterIsRaw && draft.otherYAML == yaml)
    #expect(draft.otherYAMLError?.line == 2)
    draft.body = "New body.\n"
    try await draft.save()
    #expect(try skillFile(fixture) == "---\n\(yaml)---\nNew body.\n", "the frontmatter is written back byte for byte")
    let numbered = try await setUp("---\nname: editing\ndescription: 5\n---\nBody.\n")
    #expect(numbered.2.frontmatterIsRaw, "a description that isn't text is kept as written")
  }

  @Test func nameComesFromTheFolder() async throws {
    let (fixture, store, draft) = try await setUp("---\nname: other-name\ndescription: D.\n---\nBody.\n")
    #expect(draft.name == "editing")
    #expect(draft.issues.contains { $0.contains("other-name") })
    draft.body = "Changed.\n"
    try await draft.save()
    #expect(FileManager.default.fileExists(atPath: fixture.user.appending(path: "editing/SKILL.md").path), "the folder isn't renamed")
    #expect(store.served.first?.name == "editing")
  }

  // MARK: - The Skills screen's use

  @Test func diskCheckOffTheMainActor() async throws {
    let (fixture, _, draft) = try await setUp()
    #expect(await !draft.diskChangedInBackground())
    try "changed\n".write(to: fixture.user.appending(path: "editing/notes/a.md"), atomically: true, encoding: .utf8)
    #expect(await draft.diskChangedInBackground() && draft.diskChanged(), "both checks see an edit on disk")
    draft.keepMine()
    #expect(await !draft.diskChangedInBackground())
  }

  @Test func savingIsFlaggedOnlyWhileItRuns() async throws {
    let (fixture, store, draft) = try await setUp()
    draft.body = "During.\n"
    let save = Task { try await draft.save() }
    // The save runs up to its first wait (the write, off the main actor).
    await Task.yield()
    #expect(draft.isSaving, "flagged while the write runs")
    try await save.value
    #expect(!draft.isSaving && !draft.isDirty)
    _ = (fixture, store)
    draft.saveError = "kept on the draft"
    #expect(draft.saveError == "kept on the draft")
  }

  @Test func selectingMakesTheDraftAtOnce() async throws {
    let (fixture, store, _) = try await setUp()
    try fixture.write("other", ["SKILL.md": SkillFixture.skillFile("other")])
    await store.reload()
    store.screenSelection = "user/other"
    #expect(store.drafts["user/other"] != nil, "made as the selection changes, not on the next redraw")
  }

  @Test func draftsOfGoneSkillsAreDropped() async throws {
    let (fixture, store, draft) = try await setUp()
    draft.body = "Unsaved.\n"
    #expect(store.unsavedSkillNames == ["editing"])
    try FileManager.default.removeItem(at: fixture.user.appending(path: "editing"))
    await store.reload()
    #expect(store.drafts["user/editing"] == nil && store.unsavedEditsSentence == nil, "the quit warning doesn't name a skill that's gone")
  }

  @Test func textCacheKeepsOnlyFilesFromDisk() async throws {
    let (fixture, store, draft) = try await setUp()
    defer { _ = (fixture, store) }
    let cache = SkillTextCache()
    #expect(cache.lookup("notes/a.md", in: draft) == .loading)
    await cache.load("notes/a.md", in: draft)
    #expect(cache.lookup("notes/a.md", in: draft) == .text("note a\n") && cache.count == 1)
    for index in 0..<20 { draft.setText("typed \(index)\n", for: "notes/a.md") }
    #expect(cache.lookup("notes/a.md", in: draft) == .text("typed 19\n"), "an edited file's text is the draft's")
    await cache.load("notes/a.md", in: draft)
    #expect(cache.count == 1, "edits never add to the cache")
    #expect(cache.lookup("missing.md", in: draft) == .notText, "a path the draft doesn't have")
    cache.clear()
    #expect(cache.count == 0)
  }
}
