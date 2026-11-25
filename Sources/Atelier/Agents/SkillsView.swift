#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// The Skills screen (Mac only, like the MCP server): the skills agents get, yours and Atelier's,
/// with a toggle each; the selected one is edited in the inspector (`SkillDetailView`). Laid out
/// as the Styles screen is. Edits are drafts kept in the store (`SkillStore.drafts`), so leaving
/// a skill or the screen never asks to save: the row shows ● and quitting warns (MCP.md#skills).
struct SkillsView: View {
  @Environment(SkillStore.self) private var skills
  @Environment(AgentServer.self) private var agents
  @Environment(FileDialogs.self) private var fileDialogs
  @Environment(Navigation.self) private var navigation
  @Environment(\.openSettings) private var openSettings
  @State private var creating = false
  @State private var newName = ""
  @State private var message: Message?
  @State private var pendingTrash: Skill?
  @State private var importing = false

  struct Message: Identifiable {
    var title: String
    var text: String
    var id: String { title + text }
  }

  private var filtered: [Skill] {
    let query = skills.screenSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return skills.skills }
    return skills.skills.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.summary ?? "").localizedCaseInsensitiveContains(query) }
  }

  private var selected: Skill? { skills.skills.first { $0.id == skills.screenSelection } }

  var body: some View {
    @Bindable var skills = skills
    List(selection: $skills.screenSelection) {
      ForEach(filtered) { skill in
        SkillRow(skill: skill, isDirty: skills.drafts[skill.id]?.isDirty == true)
          .tag(skill.id)
          .contextMenu { contextMenu(for: skill) }
      }
    }
    .overlay {
      if skills.skills.isEmpty {
        ContentUnavailableView(
          "No skills yet", systemImage: ContentView.Section.skills.symbol,
          description: Text("A skill is a folder of instructions an agent reads before it works with Atelier. Make one with New Skill, or import a skill folder or .zip."))
      } else if filtered.isEmpty {
        ContentUnavailableView.search(text: skills.screenSearch)
      }
    }
    .safeAreaBar(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        serverBar
        // Not modal: the list stays as last read meanwhile.
        if let error = skills.listingError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
        }
      }
    }
    .toolbar {
      ToolbarItem {
        Button("New Skill", systemImage: "plus") {
          newName = ""
          creating = true
        }
        .help("Make a skill of your own")
      }
      ToolbarItem {
        Button("Import…", systemImage: "square.and.arrow.down") { chooseImport() }
          .disabled(importing)
          .help("Import a skill folder, or a .zip or .skill file")
      }
      HelpToolbarItem(section: .skills)
    }
    .searchable(text: $skills.screenSearch, placement: .toolbar, prompt: "Filter skills")
    .detailInspector(selection: skills.screenSelection, isEmpty: selected == nil, clearSelection: { skills.screenSelection = nil }) {
      Group {
        if let selected, let draft = skills.drafts[selected.id] {
          SkillDetailView(skill: selected, draft: draft)
            .id(selected.id)
        } else {
          ContentUnavailableView(
            "No selection", systemImage: ContentView.Section.skills.symbol,
            description: Text("Select a skill to edit it or see what agents get."))
        }
      }
      .inspectorColumnWidth(min: 420, ideal: 540, max: 900)
    }
    .task { await skills.reload() }
    .sheet(isPresented: $creating) { newSkillSheet }
    .debugPresents("newSkill", $creating)
    .confirmationDialog(
      "Move “\(pendingTrash?.name ?? "")” to the Trash?", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })
    ) {
      Button("Move to Trash", role: .destructive) {
        guard let skill = pendingTrash else { return }
        pendingTrash = nil
        Task {
          do { try await skills.delete(skill) } catch { message = Message(title: "Couldn't move the skill to the Trash", text: error.localizedDescription) }
        }
      }
      Button("Cancel", role: .cancel) { pendingTrash = nil }
    } message: {
      Text(
        skills.drafts[pendingTrash?.id ?? ""]?.isDirty == true
          ? "Agents stop getting it, and your unsaved edits to it are lost." : "Agents stop getting it. You can put it back from the Trash.")
    }
    .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
      Button("OK") { message = nil }
    } message: {
      Text(message?.text ?? "")
    }
    // A Save that failed, from whichever skill: kept on its draft, so it's shown even when the
    // user moved on to another skill while it ran.
    .alert(
      "Couldn't save “\(failedSave?.skill.name ?? "")”",
      isPresented: Binding(get: { failedSave != nil }, set: { if !$0 { failedSave?.saveError = nil } })
    ) {
      Button("OK") { failedSave?.saveError = nil }
    } message: {
      Text(failedSave?.saveError ?? "")
    }
  }

  private var failedSave: SkillEditorModel? { skills.drafts.values.first { $0.saveError != nil } }

  // MARK: - Server bar

  /// Always there, so it's clear whether agents get the skills at all.
  private var serverBar: some View {
    HStack(spacing: 10) {
      Image(systemName: agents.isListening ? "checkmark.circle.fill" : "exclamationmark.circle")
        .foregroundStyle(agents.isListening ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
      Group {
        if agents.isListening {
          Text("Served at \(agents.endpoint)").textSelection(.enabled)
        } else if agents.isEnabled, let error = agents.listenError {
          Text("The MCP server isn't running: \(error)")
        } else {
          Text("Agents get these skills while the MCP server is on.")
        }
      }
      .lineLimit(2)
      Spacer()
      Button("Open Settings ▸ Agents") {
        navigation.settingsTab = "Agents"
        openSettings()
      }
      .help("Turn the MCP server on or off and see how agents connect")
    }
    .font(.callout)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }

  // MARK: - Rows' menu

  @ViewBuilder private func contextMenu(for skill: Skill) -> some View {
    Button("Duplicate to Edit", systemImage: "plus.square.on.square") { duplicate(skill) }
      .disabled(skill.origin != .builtIn)
    // A missing skill has no folder to show or export, nor to trash: Discard Edits is in its detail.
    Button(Finder.revealTitle, systemImage: "folder") { Finder.reveal([skill.directory]) }
      .disabled(skill.isMissing)
    // The saved skill, which the title says when there are edits not in it.
    Button(skills.drafts[skill.id]?.isDirty == true ? "Export Saved Version as .zip…" : "Export as .zip…", systemImage: "square.and.arrow.up") { export(skill) }
      .help("Exports the skill as last saved; edits you haven't saved aren't in it")
      .disabled(skill.isMissing)
    Divider()
    Button("Move to Trash", systemImage: "trash", role: .destructive) { pendingTrash = skill }
      .disabled(skill.origin != .user || skill.isMissing)
  }

  private func duplicate(_ skill: Skill) {
    Task {
      do {
        let copy = try await skills.duplicate(skill)
        skills.screenSelection = copy.id
        skills.screenTab = SkillDetailView.Tab.instructions.rawValue
      } catch {
        message = Message(title: "Couldn't duplicate the skill", text: error.localizedDescription)
      }
    }
  }

  /// The saved skill (not a draft) as a zip with a folder of its name inside, which Import reads
  /// back.
  private func export(_ skill: Skill) {
    let store = skills
    fileDialogs.save = FileDialogs.Save(
      file: ExportedFile(type: .zip) {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "atelier-skill-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await store.export(skill, to: temporary)
        return try Data(contentsOf: temporary)
      },
      name: skill.name + ".zip"
    ) { result in
      if case .failure(let error) = result { message = Message(title: "Couldn't export the skill", text: error.localizedDescription) }
    }
  }

  // MARK: - Import

  private static let skillFileType = UTType(filenameExtension: "skill") ?? .zip

  private func chooseImport() {
    fileDialogs.open = FileDialogs.Open(
      types: [.folder, .zip, Self.skillFileType], multiple: true,
      directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
      message: "Choose skill folders, or .zip or .skill files"
    ) { urls in importItems(urls) }
  }

  private func importItems(_ urls: [URL]) {
    importing = true
    Task {
      defer { importing = false }
      var imported: [Skill] = []
      var failures: [String] = []
      for url in urls {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
          imported.append(try await skills.importItem(at: url))
        } catch {
          failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
        }
      }
      if let last = imported.last {
        skills.screenSearch = ""
        skills.screenSelection = last.id
      }
      if !failures.isEmpty {
        message = Message(
          title: imported.isEmpty ? "Couldn't import" : "Imported \(imported.count) of \(urls.count)",
          text: failures.joined(separator: "\n"))
      } else if let invalid = imported.first(where: { !$0.isValid }) {
        message = Message(
          title: "Imported “\(invalid.name)” with problems",
          text: "Agents don't get it until they're fixed: \(invalid.issues.joined(separator: " "))")
      }
    }
  }

  // MARK: - New Skill

  /// Why the name typed can't be used, or nil when it can.
  private var newNameProblem: String? {
    if let problem = SkillFrontmatter.nameProblem(newName) { return newName.isEmpty ? nil : problem }
    if skills.skills.contains(where: { $0.origin == .user && $0.name == newName }) { return "You already have a skill named “\(newName)”." }
    return nil
  }

  private var newSkillSheet: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Skill").font(.headline)
      TextField("Name", text: $newName, prompt: Text("my-skill"))
        .onSubmit { if canCreate { create() } }
      Group {
        if let problem = newNameProblem {
          Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else {
          Text("Lowercase letters, digits and hyphens, up to \(SkillFrontmatter.maxNameLength). It's also the folder's name.")
            .foregroundStyle(.secondary)
        }
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
      if skills.skills.contains(where: { $0.origin == .builtIn && $0.name == newName }) {
        Text("Yours will be used in place of Atelier's skill of that name.").font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { creating = false }
          .keyboardShortcut(.cancelAction)
        Button("Create") { create() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate)
      }
    }
    .padding(20)
    .frame(width: 380)
  }

  private var canCreate: Bool { !newName.isEmpty && newNameProblem == nil }

  private func create() {
    let name = newName
    creating = false
    Task {
      do {
        let skill = try await skills.create(name: name)
        skills.screenSearch = ""
        skills.screenSelection = skill.id
        skills.screenTab = SkillDetailView.Tab.instructions.rawValue
      } catch {
        message = Message(title: "Couldn't make the skill", text: error.localizedDescription)
      }
    }
  }
}

/// One skill in the list: on/off, name and description, where it's from, and whether it has a
/// problem or unsaved edits.
private struct SkillRow: View {
  let skill: Skill
  let isDirty: Bool
  @Environment(SkillStore.self) private var skills

  private var toggleHelp: String {
    if skill.isMissing { return "Its folder was removed outside Atelier; save it again to share it" }
    if skill.overridden { return "Agents get your skill of this name instead" }
    if !skill.isValid { return "Agents can't get a skill with problems; fix them first" }
    return skill.isEnabled ? "Agents get this skill; turn it off to keep it from them" : "Agents don't get this skill; turn it on to share it"
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Toggle("Serve \(skill.name)", isOn: Binding(get: { skill.isEnabled }, set: { skills.setEnabled(skill, $0) }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(!skill.isValid || skill.overridden || skill.isMissing)
        .help(toggleHelp)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(skill.name).fontWeight(.medium)
          SkillBadge(skill: skill)
          Spacer()
          // Always laid out so the row doesn't shift.
          Text("●")
            .foregroundStyle(.secondary)
            .opacity(isDirty ? 1 : 0)
            .help("Edited, not saved")
            .accessibilityLabel("Unsaved edits")
            .accessibilityHidden(!isDirty)
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
            .opacity(skill.isValid ? 0 : 1)
            .help(skill.issues.joined(separator: "\n"))
            .accessibilityLabel("Has problems")
            .accessibilityHidden(skill.isValid)
        }
        Text(skill.summary ?? "No description")
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 2)
  }
}

/// Built-in, Yours, Overridden, or Missing (yours, with unsaved edits, whose folder was removed).
struct SkillBadge: View {
  let skill: Skill

  var body: some View {
    let title = skill.isMissing ? "Missing" : skill.origin == .user ? "Yours" : skill.overridden ? "Overridden" : "Built-in"
    Text(title)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .foregroundStyle(skill.isMissing ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      .overlay(Capsule().strokeBorder(skill.isMissing ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary.opacity(0.5))))
      .help(
        skill.isMissing
          ? "Removed outside Atelier; your unsaved edits are kept until you save or discard them"
          : skill.origin == .user
          ? "Your skill, in Atelier's Skills folder" : skill.overridden ? "Atelier's skill, replaced by yours of the same name" : "Comes with Atelier; can't be changed")
  }
}
#endif
