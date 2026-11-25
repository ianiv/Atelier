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
}
