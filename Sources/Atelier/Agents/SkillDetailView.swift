#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// The Skills screen's inspector: one skill's draft in three tabs. Instructions edits SKILL.md as
/// its parts, Files the folder's other files, and Agent shows what agents get of the saved skill.
/// Every edit goes into the skill's `SkillEditorModel`, which only Save writes; Atelier's own
/// skills show everything disabled, with Duplicate to Edit.
struct SkillDetailView: View {
  enum Tab: String, CaseIterable, Identifiable {
    case instructions, files, agent
    var id: String { rawValue }
    var title: String {
      switch self {
      case .instructions: "Instructions"
      case .files: "Files"
      case .agent: "Agent"
      }
    }
  }

  let skill: Skill
  @Bindable var draft: SkillEditorModel
  @Environment(SkillStore.self) private var skills
  /// File texts read from disk, kept so each keystroke doesn't read the file again
  /// (`SkillEditorModel.text(of:)` reads unedited files every call).
  @State private var cache = SkillTextCache()
  @State private var changedOnDisk = false
  /// Why Duplicate to Edit failed. A Save's failure is kept on the draft instead
  /// (`SkillEditorModel.saveError`, shown by `SkillsView`), since the user may switch skills
  /// while it runs.
  @State private var failure: String?
  /// Between Save being clicked and the draft's own save starting (the disk check).
  @State private var preparingSave = false

  private var saving: Bool { preparingSave || draft.isSaving }

  private var tab: Binding<Tab> {
    Binding(get: { Tab(rawValue: skills.screenTab) ?? .instructions }, set: { skills.screenTab = $0.rawValue })
  }

  var body: some View {
    // Once per redraw, for the header and the tabs.
    let issues = draft.issues
    VStack(spacing: 0) {
      header(issues)
      if draft.isBuiltIn { builtInBanner }
      Picker("Tab", selection: tab) {
        ForEach(Tab.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      Divider()
      Group {
        switch tab.wrappedValue {
        case .instructions: SkillInstructionsTab(draft: draft, issues: issues)
        case .files: SkillFilesTab(draft: draft, cache: cache, issues: issues) { tab.wrappedValue = .instructions }
        case .agent: SkillAgentTab(skill: skill, draft: draft)
        }
      }
      // A Save reloads the draft from what it wrote, so nothing typed meanwhile would last.
      .disabled(saving)
      .frame(maxHeight: .infinity, alignment: .top)
      Divider()
      saveBar
    }
    .task { await checkDisk() }
    .onChange(of: skills.activations) { Task { await checkDisk() } }
    .alert("“\(draft.skill.name)” changed on disk", isPresented: $changedOnDisk) {
      Button("Keep Mine") {
        draft.keepMine()
        cache.clear()
      }
      Button("Reload", role: .destructive) {
        draft.reloadFromDisk()
        cache.clear()
      }
    } message: {
      Text("Its folder was changed outside Atelier while you were editing it. Keep Mine keeps your edits, and your next Save overwrites the changes on disk; Reload drops your edits and shows the skill as it is now.")
    }
    .alert("Couldn't duplicate “\(draft.skill.name)”", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
      Button("OK") { failure = nil }
    } message: {
      Text(failure ?? "")
    }
  }

  // MARK: - Header

  private func header(_ issues: [String]) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(draft.skill.name).font(.title2.weight(.semibold)).lineLimit(1).textSelection(.enabled)
      SkillBadge(skill: skill)
      Spacer()
      if issues.isEmpty {
        Label("Valid", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .help("Follows the Agent Skills rules and fits the limits")
      } else {
        Label(issues.count == 1 ? "1 problem" : "\(issues.count) problems", systemImage: "exclamationmark.circle.fill")
          .foregroundStyle(.red)
          .help(issues.joined(separator: "\n"))
      }
    }
    .font(.callout)
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }

  private var builtInBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.fill").foregroundStyle(.secondary)
      Text(skill.overridden ? "Built-in skills can't be changed. Agents get yours of this name instead." : "Built-in skills can't be changed.")
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Show Mine") { skills.screenSelection = "user/\(skill.name)" }
        .disabled(!skill.overridden)
        .help(skill.overridden ? "Show your skill of this name, which agents get instead" : "You have no skill of this name")
      Button("Duplicate to Edit") { duplicate() }
    }
    .font(.callout)
    .padding(10)
    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    .padding(.horizontal, 16)
    .padding(.vertical, 4)
  }

  private func duplicate() {
    Task {
      do {
        let copy = try await skills.duplicate(skill)
        skills.screenSelection = copy.id
        skills.screenTab = Tab.instructions.rawValue
      } catch {
        failure = error.localizedDescription
      }
    }
  }

  // MARK: - Saving

  private var saveBar: some View {
    HStack {
      Text(draft.isDirty ? "Edited" : "Saved")
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Revert") {
        draft.revert()
        cache.clear()
      }
      .disabled(draft.isBuiltIn || !draft.isDirty || saving)
      .help("Drop your edits to this skill")
      Button("Save") { save() }
        .keyboardShortcut("s", modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(draft.isBuiltIn || !draft.isDirty || saving)
        .help("Write the skill's folder; agents get it from now on")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  /// Looks for changes made to the folder outside Atelier: with no edits the skill is simply
  /// read again; with edits, the user picks.
  private func checkDisk() async {
    await skills.reload()
    guard !saving, await draft.diskChangedInBackground() else { return }
    if draft.isDirty {
      changedOnDisk = true
    } else {
      draft.reloadFromDisk()
      cache.clear()
    }
  }

  /// Runs on if the user switches skills meanwhile: the draft keeps the outcome.
  private func save() {
    preparingSave = true
    let draft = draft
    let skills = skills
    let cache = cache
    Task {
      await skills.reload()
      let changed = await draft.diskChangedInBackground()
      preparingSave = false
      if changed {
        changedOnDisk = true
        return
      }
      do {
        try await draft.save()
        cache.clear()
      } catch {
        draft.saveError = error.localizedDescription
      }
    }
  }
}

/// Texts of unedited files as read from disk, by where they come from (the file in the skill or
/// the file to copy in), read off the main actor. Edited files' text is the draft's own and is
/// never kept here. Not observed: the Files tab redraws when a read finishes.
@MainActor
final class SkillTextCache {
  enum Lookup: Equatable {
    case text(String)
    /// Too large, not UTF-8, or not there.
    case notText
    /// Not read yet: call `load`.
    case loading
  }

  /// nil for a file that isn't editable text.
  private var texts: [String: String?] = [:]
  /// Bumped by `clear`, so a read for an older generation can tell.
  private(set) var generation = 0
  var count: Int { texts.count }

  /// Where the path's text comes from, or nil when it isn't read from a file.
  func key(_ path: String, in draft: SkillEditorModel) -> String? {
    switch draft.entries[path] {
    case .original(let original): "skill:\(original)"
    case .copy(let url): "copy:\(url.path)"
    case .text, nil: nil
    }
  }

  func lookup(_ path: String, in draft: SkillEditorModel) -> Lookup {
    if case .text(let text) = draft.entries[path] { return .text(text) }
    guard let key = key(path, in: draft) else { return .notText }
    guard let cached = texts[key] else { return .loading }
    return cached.map(Lookup.text) ?? .notText
  }

  /// Reads the path's file, if it isn't known yet.
  func load(_ path: String, in draft: SkillEditorModel) async {
    guard let key = key(path, in: draft), texts[key] == nil else { return }
    let url: URL
    switch draft.entries[path] {
    case .original(let original): url = draft.skill.directory.appending(path: original)
    case .copy(let copy): url = copy
    default: return
    }
    let generation = generation
    let text: String? =
      draft.size(of: path) > SkillEditorModel.maxEditableText
      ? nil
      : await Task.detached(priority: .userInitiated) { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }.value
    guard generation == self.generation else { return }
    texts[key] = .some(text)
  }

  func clear() {
    texts = [:]
    generation += 1
  }
}

// MARK: - Instructions

private struct SkillInstructionsTab: View {
  @Bindable var draft: SkillEditorModel
  let issues: [String]
  @Environment(SkillStore.self) private var skills

  private var readOnly: Bool { draft.isBuiltIn }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        section("Name") {
          TextField("Name", text: $draft.name)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .disabled(readOnly || draft.frontmatterIsRaw)
          nameStatus
        }
        section("Description") {
          SkillTextEditor(text: $draft.description, monospaced: false)
            .frame(height: 72)
            .disabled(readOnly || draft.frontmatterIsRaw)
          HStack {
            Text("What the skill does and when an agent should use it: agents decide from this alone.")
              .foregroundStyle(.secondary)
            Spacer()
            let count = draft.description.count
            Text("\(count)/\(SkillFrontmatter.maxDescriptionLength)")
              .monospacedDigit()
              .foregroundStyle(count > SkillFrontmatter.maxDescriptionLength || count == 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
          }
          .font(.caption)
        }
        if draft.frontmatterIsRaw {
          Label(
            "SKILL.md's frontmatter doesn't read as fields with a text name and description, so it's edited as it is below, and Save writes it unchanged apart from your edits. Fix it there to edit Name and Description here.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }
        section(draft.frontmatterIsRaw ? "Frontmatter (YAML)" : "Other fields (YAML)") {
          SkillTextEditor(text: $draft.otherYAML, monospaced: true)
            .frame(height: 96)
            .disabled(readOnly)
          if let error = draft.otherYAMLError {
            Label("Line \(error.line): \(error.message)", systemImage: "exclamationmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.red)
          } else {
            Text("Optional: license, compatibility, metadata, allowed-tools and any other fields.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        section("Body") {
          SkillTextEditor(text: $draft.body, monospaced: true)
            .frame(minHeight: 280)
            .disabled(readOnly)
        }
        if !issues.isEmpty {
          section("Problems") {
            ForEach(issues, id: \.self) { issue in
              Label(issue, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("A skill with problems can be saved, but agents don't get it until they're fixed.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(16)
    }
  }

  private var nameStatus: some View {
    Group {
      if draft.frontmatterIsRaw {
        Text("Edited in the frontmatter below.").foregroundStyle(.secondary)
      } else if let problem = SkillFrontmatter.nameProblem(draft.name) {
        Label(problem, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
      } else if draft.name != draft.skill.name, skills.skills.contains(where: { $0.origin == .user && $0.name == draft.name }) {
        Label("You already have a skill named “\(draft.name)”.", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
      } else if draft.name != draft.skill.name {
        Label("Save renames the folder to “\(draft.name)”.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      } else {
        Label("Lowercase letters, digits and hyphens; the folder's name.", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
      }
    }
    .font(.caption)
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.headline)
      content()
    }
  }
}

/// A text editor with a visible edge, for the inspector's fields.
private struct SkillTextEditor: View {
  @Binding var text: String
  let monospaced: Bool

  var body: some View {
    TextEditor(text: $text)
      .font(monospaced ? .system(.body, design: .monospaced) : .body)
      .autocorrectionDisabled()
      .scrollContentBackground(.hidden)
      .padding(4)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
  }
}

// MARK: - Files

private struct SkillFileNode: Identifiable, Hashable {
  let path: String
  let isFolder: Bool
  var children: [SkillFileNode]?
  var id: String { path }
  var name: String { (path as NSString).lastPathComponent }

  static func parent(of path: String) -> String { (path as NSString).deletingLastPathComponent }

  /// The draft's visible files and folders as a tree: SKILL.md first, then folders, then files.
  static func tree(files: [String], folders: [String], under parent: String = "") -> [SkillFileNode] {
    let subfolders = folders.filter { Self.parent(of: $0) == parent }.sorted()
    let inside = files.filter { Self.parent(of: $0) == parent }.sorted()
    let skillFile = inside.filter { $0 == SkillScanner.skillFileName }
    return skillFile.map { SkillFileNode(path: $0, isFolder: false) }
      + subfolders.map { SkillFileNode(path: $0, isFolder: true, children: tree(files: files, folders: folders, under: $0)) }
      + inside.filter { $0 != SkillScanner.skillFileName }.map { SkillFileNode(path: $0, isFolder: false) }
  }
}

private struct SkillFilesTab: View {
  @Bindable var draft: SkillEditorModel
  let cache: SkillTextCache
  let issues: [String]
  let goToInstructions: () -> Void
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var selection: String?
  @State private var renaming: String?
  @State private var renameText = ""
  @State private var failure: String?
  /// Bumped when a file's text has been read, to redraw (the cache isn't observed).
  @State private var reads = 0
  @FocusState private var renameFocused: Bool

  private var readOnly: Bool { draft.isBuiltIn }
  private var nodes: [SkillFileNode] { SkillFileNode.tree(files: draft.filePaths, folders: draft.folderPaths) }
  private var selectedIsFolder: Bool { selection.map { draft.folderPaths.contains($0) } ?? false }
  private var canChangeSelection: Bool { !readOnly && selection != nil && selection != SkillScanner.skillFileName }

  /// The folder new items go in: the selected folder, or the selected file's.
  private var targetFolder: String {
    guard let selection else { return "" }
    return selectedIsFolder ? selection : SkillFileNode.parent(of: selection)
  }

  /// Every folder's total size and file count, in one pass over the files.
  private func folderTotals() -> [String: (bytes: Int, files: Int)] {
    var totals: [String: (bytes: Int, files: Int)] = [:]
    for path in draft.filePaths where path != SkillScanner.skillFileName {
      let size = draft.size(of: path)
      var parent = SkillFileNode.parent(of: path)
      while !parent.isEmpty {
        totals[parent, default: (0, 0)].bytes += size
        totals[parent, default: (0, 0)].files += 1
        parent = SkillFileNode.parent(of: parent)
      }
    }
    return totals
  }

  var body: some View {
    let folders = folderTotals()
    VStack(alignment: .leading, spacing: 8) {
      buttons
      List(selection: $selection) {
        OutlineGroup(nodes, children: \.children) { node in row(node, folders: folders).tag(node.path) }
      }
      .listStyle(.bordered)
      .alternatingRowBackgrounds()
      .frame(minHeight: 150, idealHeight: 200, maxHeight: 260)
      selectedDetail(folders: folders)
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: selection.map { "\($0)|\(cache.key($0, in: draft) ?? "")|\(cache.generation)" }) {
          guard let selection, cache.lookup(selection, in: draft) == .loading else { return }
          await cache.load(selection, in: draft)
          reads += 1
        }
      limits
      problems
    }
    .padding(16)
    .alert("Couldn't change the files", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
      Button("OK") { failure = nil }
    } message: {
      Text(failure ?? "")
    }
  }

  // MARK: Buttons

  private var buttons: some View {
    HStack(spacing: 6) {
      // Atelier's own skills can't change, so these are disabled there; Reveal still works.
      Group {
        Button("New File", systemImage: "doc.badge.plus") { newItem(folder: false) }
          .help("Add a Markdown file to the selected folder")
        Button("New Folder", systemImage: "folder.badge.plus") { newItem(folder: true) }
          .help("Add a folder")
        Button("Add Files…", systemImage: "plus") { chooseFiles() }
          .help("Copy files or folders into the skill when you save")
      }
      .disabled(readOnly)
      Spacer()
      Button("Rename", systemImage: "pencil") { startRename() }
        .labelStyle(.iconOnly)
        .disabled(!canChangeSelection)
        .help("Rename the selected file or folder (SKILL.md keeps its name)")
      Button("Move to Trash", systemImage: "trash") { removeSelection() }
        .labelStyle(.iconOnly)
        .disabled(!canChangeSelection)
        .help("Take the selected file or folder out of the skill; Save moves the old version of the skill's folder to the Trash")
      Button(Finder.revealTitle, systemImage: "folder") { reveal(selection) }
        .labelStyle(.iconOnly)
        .help("Show the selected file, or the skill's folder, in Finder")
    }
    .controlSize(.small)
    .buttonStyle(.bordered)
  }

  private func row(_ node: SkillFileNode, folders: [String: (bytes: Int, files: Int)]) -> some View {
    HStack(spacing: 6) {
      Image(systemName: node.isFolder ? "folder" : node.path == SkillScanner.skillFileName ? "doc.richtext" : "doc")
        .foregroundStyle(.secondary)
      if renaming == node.path {
        TextField("Name", text: $renameText)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .focused($renameFocused)
          .onSubmit { commitRename() }
          // Escape cancels; clicking elsewhere keeps the name, as in Finder.
          .onExitCommand { renaming = nil }
          .onChange(of: renameFocused) { if !renameFocused, renaming == node.path { commitRename() } }
      } else {
        Text(node.name).lineLimit(1)
      }
      Spacer()
      Text(ByteCountFormatter.string(fromByteCount: Int64(node.isFolder ? folders[node.path]?.bytes ?? 0 : draft.size(of: node.path)), countStyle: .file))
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Text(typeDescription(node))
        .foregroundStyle(.secondary)
        .frame(width: 110, alignment: .leading)
        .lineLimit(1)
    }
    .font(.callout)
  }

  private func typeDescription(_ node: SkillFileNode) -> String {
    if node.isFolder { return "Folder" }
    let ext = (node.path as NSString).pathExtension
    return UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? "Document" : "\(ext.uppercased()) file")
  }

  // MARK: Selected file

  @ViewBuilder private func selectedDetail(folders: [String: (bytes: Int, files: Int)]) -> some View {
    let _ = reads
    if let path = selection, draft.filePaths.contains(path) || draft.folderPaths.contains(path) {
      if path == SkillScanner.skillFileName {
        HStack {
          Text("SKILL.md is edited in Instructions, as its name, description, other fields and body.")
            .foregroundStyle(.secondary)
          Button("Go to Instructions") { goToInstructions() }
        }
        .font(.callout)
      } else if draft.folderPaths.contains(path) {
        let count = folders[path]?.files ?? 0
        Text("Folder · \(count == 1 ? "1 file" : "\(count) files")").font(.callout).foregroundStyle(.secondary)
      } else if cache.lookup(path, in: draft) == .loading {
        ProgressView().controlSize(.small)
      } else if case .text = cache.lookup(path, in: draft) {
        VStack(alignment: .leading, spacing: 4) {
          Text(path).font(.callout.weight(.medium))
          SkillTextEditor(
            text: Binding(
              get: {
                if case .text(let text) = cache.lookup(path, in: draft) { return text }
                return ""
              },
              set: { draft.setText($0, for: path) }),
            monospaced: true
          )
          .disabled(readOnly)
          .frame(minHeight: 140)
        }
      } else {
        let size = ByteCountFormatter.string(fromByteCount: Int64(draft.size(of: path)), countStyle: .file)
        let kind = UTType(filenameExtension: (path as NSString).pathExtension)?.localizedDescription ?? "File"
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(kind) · \(size)").font(.callout.weight(.medium))
            Text(draft.size(of: path) > SkillEditorModel.maxEditableText ? "Larger than 1 MiB, so it isn't edited here." : "Not text, so it isn't edited here.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(Finder.revealTitle) { reveal(path) }
        }
      }
    } else {
      Text("Select a file to edit it here. Text files up to 1 MiB are edited with the skill and written when you save.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Limits and problems

  private var limits: some View {
    let (count, bytes) = draft.totals
    let overFiles = count > SkillScanner.maxFiles
    let overBytes = bytes > SkillScanner.maxBytes
    return HStack(spacing: 16) {
      ProgressView(value: min(Double(count) / Double(SkillScanner.maxFiles), 1)) {
        Text("\(count) of \(SkillScanner.maxFiles) files").foregroundStyle(overFiles ? .red : .secondary)
      }
      .tint(overFiles ? .red : .accentColor)
      ProgressView(value: min(Double(bytes) / Double(SkillScanner.maxBytes), 1)) {
        Text("\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of 16 MiB").foregroundStyle(overBytes ? .red : .secondary)
      }
      .tint(overBytes ? .red : .accentColor)
    }
    .font(.caption)
    .help("The most a skill may hold, as the Skills extension sets: agents don't get a skill past either")
  }

  /// What's wrong with the folder: links on disk, and from the draft's problems (worked out once
  /// per redraw) the limits as it would save and files to copy in that are gone or links.
  private var folderProblems: [String] {
    SkillScanner.structuralIssues(draft.skill.fingerprint).filter { $0.contains("link") }
      + issues.filter { $0.hasSuffix("is a link or missing.") || $0.contains("a skill can have at most") || $0.contains("a skill can hold at most") }
  }

  private var problems: some View {
    ForEach(folderProblems, id: \.self) { problem in
      Label(problem, systemImage: "exclamationmark.circle.fill")
        .font(.callout)
        .foregroundStyle(.red)
    }
  }

  // MARK: Actions

  private func uniquePath(_ base: String, ext: String) -> String {
    let folder = targetFolder
    func path(_ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }
    var number = 1
    while true {
      let name = (number == 1 ? base : "\(base)-\(number)") + ext
      let candidate = path(name)
      if !draft.filePaths.contains(candidate), !draft.folderPaths.contains(candidate), draft.entries[candidate] == nil { return candidate }
      number += 1
    }
  }

  private func newItem(folder: Bool) {
    let path = folder ? uniquePath("folder", ext: "") : uniquePath("untitled", ext: ".md")
    do {
      if folder { try draft.addFolder(at: path) } else { try draft.addTextFile(at: path) }
      selection = path
      startRename()
    } catch {
      failure = error.localizedDescription
    }
  }

  private func chooseFiles() {
    let folder = targetFolder
    fileDialogs.open = FileDialogs.Open(
      types: [.item, .folder], multiple: true, confirmation: "Add",
      message: "Choose files or folders to copy into “\(draft.skill.name)”\(folder.isEmpty ? "" : " ▸ \(folder)") when you save"
    ) { urls in
      do { try draft.addFiles(urls, into: folder) } catch { failure = error.localizedDescription }
    }
  }

  private func startRename() {
    guard let selection, canChangeSelection else { return }
    renameText = (selection as NSString).lastPathComponent
    renaming = selection
    // Once the field is there to take it.
    Task { renameFocused = true }
  }

  private func commitRename() {
    guard let path = renaming else { return }
    renaming = nil
    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != (path as NSString).lastPathComponent else { return }
    guard !name.contains("/") else {
      failure = "A name can't contain “/”."
      return
    }
    let parent = SkillFileNode.parent(of: path)
    let newPath = parent.isEmpty ? name : parent + "/" + name
    do {
      try draft.rename(path, to: newPath)
      selection = newPath
    } catch {
      failure = error.localizedDescription
    }
  }

  private func removeSelection() {
    guard let selection, canChangeSelection else { return }
    do {
      try draft.remove(selection)
      self.selection = nil
    } catch {
      failure = error.localizedDescription
    }
  }

  /// The file on disk the path came from, or the skill's folder for anything not saved yet.
  private func reveal(_ path: String?) {
    let directory = draft.skill.directory
    guard let path else { return Finder.reveal([directory]) }
    switch draft.entries[path] {
    case .original(let original): Finder.reveal([directory.appending(path: original)])
    case .copy(let url): Finder.reveal([url])
    default:
      let url = directory.appending(path: path)
      Finder.reveal([FileManager.default.fileExists(atPath: url.path) ? url : directory])
    }
  }
}

// MARK: - Agent

private struct SkillAgentTab: View {
  let skill: Skill
  let draft: SkillEditorModel
  @State private var toolCheck: (found: [String], unknown: [String], ignored: Set<String>)?

  private var statusText: String {
    if skill.overridden { return "Agents don't get this skill: yours of the same name replaces it." }
    if !skill.isValid { return "Agents don't get this skill until its problems are fixed and it's saved." }
    if !skill.isEnabled { return "Agents don't get this skill: it's turned off in the list." }
    return "Agents get this skill whenever the MCP server is on."
  }

  private static func json(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private var prompt: String { "Use Atelier's \(skill.name) skill (\(skill.uri))" }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Label(statusText, systemImage: skill.isServed ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(skill.isServed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
          Text(draft.isDirty ? "This is the saved version; agents get your edits once you save them." : "This is what agents get, as saved.")
            .font(.caption)
            .foregroundStyle(draft.isDirty ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .font(.callout)
        section("URI") {
          Text(skill.uri).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
        section("Frontmatter") {
          Text(Self.json(skill.frontmatter ?? [:]))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
        section("Files") { files }
        HStack {
          Button("Copy Entry", systemImage: "doc.on.doc") { Clipboard.copy(Self.json(SkillsRPC.entry(skill))) }
            .help("Copy the skill's skills/list entry as JSON")
          Button("Copy Prompt", systemImage: "text.bubble") { Clipboard.copy(prompt) }
            .help("Copy “\(prompt)”, to ask an agent to use it")
        }
        .buttonStyle(.bordered)
        section("Tool names") { tools }
      }
      .padding(16)
    }
    .task(id: Self.version(of: skill)) { toolCheck = await Self.checkTools(skill) }
  }

  @ViewBuilder private var files: some View {
    if skill.files.isEmpty {
      Text("None: agents only get the files of a skill that's valid.").font(.callout).foregroundStyle(.secondary)
    } else {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
        GridRow {
          Text("URI")
          Text("Size")
          Text("Digest")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        ForEach(skill.files, id: \.relPath) { file in
          GridRow {
            Text(SkillURI.make(skill: skill.name, path: file.relPath))
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
              .font(.caption)
              .monospacedDigit()
            Text(String(file.digest.dropFirst("sha256:".count).prefix(12)))
              .font(.system(.caption, design: .monospaced))
              .help(file.digest)
              .contextMenu { Button("Copy Digest") { Clipboard.copy(file.digest) } }
          }
        }
      }
      Text("Right-click a digest to copy it in full.").font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var tools: some View {
    if let toolCheck {
      if toolCheck.found.isEmpty {
        Text("No words in the skill's text look like tool names.").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(toolCheck.found, id: \.self) { name in
        let unknown = toolCheck.unknown.contains(name)
        let ignored = toolCheck.ignored.contains(name)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: ignored ? "minus.circle" : unknown ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundStyle(ignored ? AnyShapeStyle(.secondary) : unknown ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
          Text(name).font(.system(.callout, design: .monospaced))
          Text(
            ignored
              ? "listed in \(SkillToolCheck.ignoreKey)"
              : unknown ? "doesn't look like one of Atelier's tools. Ignore this if it isn't a tool name." : "one of Atelier's tools or their arguments"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(
        "Words written like tool calls (in backticks, before a parenthesis, or after “call”, “use” or “with”) are checked against Atelier's tools. List words that aren't tools in the frontmatter as metadata: { \(SkillToolCheck.ignoreKey): \"a_b c_d\" }."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } else {
      ProgressView().controlSize(.small)
    }
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.headline)
      content()
    }
  }

  /// Changes whenever the saved folder does.
  private static func version(of skill: Skill) -> String {
    skill.id + skill.fingerprint.map { "\($0.relPath):\($0.size):\($0.modified.tv_sec).\($0.modified.tv_nsec)" }.joined(separator: "|")
  }

  /// The tool check on the saved skill's text files (up to 1 MiB each), read off the main actor.
  private static func checkTools(_ skill: Skill) async -> (found: [String], unknown: [String], ignored: Set<String>) {
    let directory = skill.directory
    let paths = skill.fingerprint.filter { !$0.isDirectory && !$0.isSymlink && $0.size <= Int64(SkillEditorModel.maxEditableText) }.map(\.relPath)
    let texts = await Task.detached {
      paths.compactMap { path -> String? in
        guard SkillScanner.isTextual(SkillScanner.mimeType(for: path)), let data = try? Data(contentsOf: directory.appending(path: path)) else { return nil }
        return String(data: data, encoding: .utf8)
      }
    }.value
    let ignored = SkillToolCheck.ignored(frontmatter: skill.frontmatter)
    let result = SkillToolCheck.scan(texts, known: SkillToolCheck.knownNames(AgentTools.definitions), ignored: ignored)
    return (result.found, result.unknown, ignored)
  }
}
#endif
