#if os(macOS)
import Foundation
import Observation

/// One skill's unsaved edits on the Skills screen: SKILL.md as its four parts (name, description,
/// the other frontmatter fields as written, the body) and the folder's other files as a tree of
/// paths, each still the file on disk, new text, or a file to copy in. Nothing touches the disk
/// until Save, which writes the whole folder at once (`SkillStore.write`).
///
/// It remembers what the folder looked like when it was read, so a change made elsewhere is
/// noticed (`diskChanged`) and Save doesn't silently overwrite it: Keep Mine says to, Reload
/// starts again from the disk.
@MainActor
@Observable
final class SkillEditorModel {
  nonisolated struct Failure: LocalizedError, Equatable {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
    static let changedOnDisk = Failure("The skill changed on disk since it was opened.")
  }

  /// Where a file of the draft comes from.
  enum Entry: Equatable {
    /// The file at this path in the skill as read.
    case original(String)
    case text(String)
    /// A file from elsewhere (Add Files…), copied in on Save.
    case copy(URL)
  }

  /// Files larger than this aren't edited as text.
  static let maxEditableText = 1 << 20

  /// The skill as last read from disk.
  private(set) var skill: Skill
  @ObservationIgnored private weak var store: SkillStore?

  var name = ""
  var description = ""
  /// The frontmatter's other fields, as YAML written by hand.
  var otherYAML = ""
  var body = ""
  /// Every file but SKILL.md, by its path in the draft.
  private(set) var entries: [String: Entry] = [:]
  /// Every folder in the draft (including those that hold files).
  private(set) var folders: Set<String> = []

  private struct Snapshot: Equatable {
    var name = "", description = "", otherYAML = "", body = ""
    var entries: [String: Entry] = [:]
    var folders: Set<String> = []
  }

  @ObservationIgnored private var base = Snapshot()
  /// The disk as read, and as the user agreed to overwrite it (Keep Mine).
  @ObservationIgnored private var acceptedFingerprint: [SkillFingerprint] = []
  @ObservationIgnored private var originalSizes: [String: Int] = [:]

  init(skill: Skill, store: SkillStore?) {
    self.skill = skill
    self.store = store
    load(skill)
  }

  var isBuiltIn: Bool { skill.origin == .builtIn }

  private var current: Snapshot {
    Snapshot(name: name, description: description, otherYAML: otherYAML, body: body, entries: entries, folders: folders)
  }

  var isDirty: Bool { current != base }

  /// Every file path the Files tab shows, SKILL.md first. Hidden files (a part of the path
  /// starting with `.`) are in the draft, so Save keeps them and renaming or removing a folder
  /// takes them along, but they aren't listed, counted or served.
  var filePaths: [String] { [SkillScanner.skillFileName] + entries.keys.filter { !Self.isHidden($0) }.sorted() }
  var folderPaths: [String] { folders.filter { !Self.isHidden($0) }.sorted() }

  static func isHidden(_ path: String) -> Bool { path.split(separator: "/").contains { $0.hasPrefix(".") } }

  /// SKILL.md's frontmatter didn't parse, or its name or description isn't text: the whole
  /// frontmatter is then `otherYAML`, written back as it is (name and description aren't edited
  /// separately), so saving the body never loses what the YAML said.
  private(set) var frontmatterIsRaw = false
  /// The name SKILL.md gave when it was read, when that isn't its folder's.
  private(set) var mismatchedName: String?
  @ObservationIgnored private var originalFiles: [String] = []
  @ObservationIgnored private var originalFolders: [String] = []

  // MARK: - Loading

  /// Reads the skill's folder into the draft, dropping any edits.
  private func load(_ skill: Skill) {
    self.skill = skill
    let print = Self.walk(skill.directory)
    acceptedFingerprint = print
    var snapshot = Snapshot()
    originalSizes = [:]
    frontmatterIsRaw = false
    mismatchedName = nil
    for item in print where !item.isSymlink {
      if item.isDirectory {
        snapshot.folders.insert(item.relPath)
      } else if item.relPath != SkillScanner.skillFileName {
        snapshot.entries[item.relPath] = .original(item.relPath)
        originalSizes[item.relPath] = Int(item.size)
      }
    }
    originalFiles = Array(snapshot.entries.keys)
    originalFolders = Array(snapshot.folders)
    // The folder names the skill; a different name in SKILL.md is shown as a problem, and Save
    // writes the folder's.
    snapshot.name = skill.name
    if let data = try? Data(contentsOf: skill.directory.appending(path: SkillScanner.skillFileName)) {
      let text = String(decoding: data, as: UTF8.self)
      if let (yaml, body) = try? SkillFrontmatter.split(data) {
        snapshot.body = body
        if let parsed = try? SkillFrontmatter.parse(yaml), let name = parsed["name"] as? String, let description = parsed["description"] as? String {
          snapshot.otherYAML = SkillFrontmatter.extractOther(yaml: yaml)
          snapshot.description = description
          if name != skill.name { mismatchedName = name }
        } else {
          frontmatterIsRaw = true
          snapshot.otherYAML = yaml
        }
      } else {
        snapshot.body = text
      }
    }
    base = snapshot
    apply(snapshot)
  }

  private func apply(_ snapshot: Snapshot) {
    name = snapshot.name
    description = snapshot.description
    otherYAML = snapshot.otherYAML
    body = snapshot.body
    entries = snapshot.entries
    folders = snapshot.folders
  }

  /// Back to the skill as it was read.
  func revert() { apply(base) }

  /// Everything in the folder, hidden items included and with no limit, so the draft knows every
  /// file a Save must carry over.
  private static func walk(_ directory: URL) -> [SkillFingerprint] {
    SkillScanner.fingerprint(directory, includesHidden: true, limit: .max)
  }

  /// Whether the folder changed on disk since it was read (or since Keep Mine).
  func diskChanged() -> Bool { Self.walk(skill.directory) != acceptedFingerprint }

  /// Keeps the draft over a change on disk: the next Save overwrites it.
  func keepMine() { acceptedFingerprint = Self.walk(skill.directory) }

  /// Drops the draft and reads the skill again (from the store's newest scan when there is one).
  func reloadFromDisk() {
    let fresh = store?.skills.first { $0.origin == skill.origin && $0.name == skill.name } ?? skill
    load(fresh)
  }

  // MARK: - SKILL.md

  /// SKILL.md as Save writes it.
  var skillFileData: Data {
    if frontmatterIsRaw {
      return Data(("---\n" + otherYAML + (otherYAML.isEmpty || otherYAML.hasSuffix("\n") ? "" : "\n") + "---\n" + body).utf8)
    }
    return SkillFrontmatter.serialize(name: name, description: description, otherYAML: otherYAML, body: body)
  }
  var preview: String { String(decoding: skillFileData, as: UTF8.self) }

  /// The frontmatter Save would write, or why it wouldn't parse.
  var previewFrontmatter: Result<[String: Any], SkillFrontmatter.ParseError> {
    do {
      return .success(try SkillFrontmatter.parse(skillFile: skillFileData))
    } catch let error as SkillFrontmatter.ParseError {
      return .failure(error)
    } catch {
      return .failure(SkillFrontmatter.ParseError(line: 1, message: error.localizedDescription))
    }
  }

  /// A YAML error in the other fields, with its line in them (1-based), for the editor.
  var otherYAMLError: SkillFrontmatter.ParseError? {
    guard case .failure(let error) = previewFrontmatter else { return nil }
    // SKILL.md's line 1 is ---, then (unless the frontmatter is raw) name and description; the
    // other fields start after them.
    return SkillFrontmatter.ParseError(line: max(error.line - (frontmatterIsRaw ? 1 : 3), 1), message: error.message)
  }

  /// What would be wrong with the skill as saved: YAML, the Agent Skills rules (its folder being
  /// renamed to the name), the limits, and a name already taken.
  var issues: [String] {
    var issues: [String] = []
    switch previewFrontmatter {
    case .success(let frontmatter):
      issues += SkillFrontmatter.validate(frontmatter, directoryName: name).map(\.message)
    case .failure(let error):
      issues.append(error.localizedDescription)
    }
    if let problem = SkillStore.folderNameProblem(name), SkillFrontmatter.nameProblem(name) == nil { issues.append(problem) }
    if let mismatchedName, name == skill.name, !frontmatterIsRaw {
      issues.append("SKILL.md names the skill “\(mismatchedName)”, but its folder is “\(skill.name)”; Save writes “\(skill.name)”.")
    }
    if name != skill.name, let store, store.skills.contains(where: { $0.origin == .user && $0.name == name }) {
      issues.append("You already have a skill named “\(name)”.")
    }
    let (count, bytes) = totals
    if count > SkillScanner.maxFiles { issues.append("\(count) files; a skill can have at most \(SkillScanner.maxFiles).") }
    if bytes > SkillScanner.maxBytes {
      issues.append("\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) in all; a skill can hold at most 16 MiB.")
    }
    for (path, entry) in entries {
      if case .copy(let url) = entry, SkillScanner.stat(url)?.isSymlink != false { issues.append("\(path) is a link or missing.") }
    }
    return issues
  }

  /// Files and bytes the saved skill would have, SKILL.md included.
  var totals: (files: Int, bytes: Int) {
    let visible = entries.keys.filter { !Self.isHidden($0) }
    return (visible.count + 1, visible.reduce(skillFileData.count) { $0 + size(of: $1) })
  }

  func size(of path: String) -> Int {
    if path == SkillScanner.skillFileName { return skillFileData.count }
    switch entries[path] {
    case .original(let original): return originalSizes[original] ?? 0
    case .text(let text): return text.utf8.count
    case .copy(let url): return Int(SkillScanner.stat(url)?.size ?? 0)
    case nil: return 0
    }
  }

  // MARK: - Other files

  /// A file's text for editing, or nil when it's too large, not UTF-8 or SKILL.md (edited as its
  /// parts).
  func text(of path: String) -> String? {
    switch entries[path] {
    case .text(let text): return text
    case .original(let original):
      guard (originalSizes[original] ?? 0) <= Self.maxEditableText,
        let data = try? Data(contentsOf: skill.directory.appending(path: original))
      else { return nil }
      return String(data: data, encoding: .utf8)
    case .copy(let url):
      guard Int(SkillScanner.stat(url)?.size ?? 0) <= Self.maxEditableText, let data = try? Data(contentsOf: url) else { return nil }
      return String(data: data, encoding: .utf8)
    case nil: return nil
    }
  }

  func setText(_ text: String, for path: String) {
    guard entries[path] != nil else { return }
    if case .original(let original) = entries[path], self.text(of: path) == text, original == path { return }
    entries[path] = .text(text)
  }

  private func checkWritable() throws {
    if isBuiltIn { throw Failure("Built-in skills can't be changed. Duplicate it to edit a copy.") }
  }

  private func checkNew(_ path: String) throws {
    guard SkillStore.safeRelativePath(path) != nil, path != SkillScanner.skillFileName else { throw Failure("“\(path)” isn't a path inside the skill.") }
    guard entries[path] == nil, !folders.contains(path) else { throw Failure("“\(path)” is already there.") }
    let parent = (path as NSString).deletingLastPathComponent
    if !parent.isEmpty, entries[parent] != nil { throw Failure("“\(parent)” is a file.") }
  }

  /// Adds the folders a path sits in.
  private func addParents(of path: String) {
    var parent = (path as NSString).deletingLastPathComponent
    while !parent.isEmpty {
      folders.insert(parent)
      parent = (parent as NSString).deletingLastPathComponent
    }
  }

  func addTextFile(at path: String, text: String = "") throws {
    try checkWritable()
    try checkNew(path)
    addParents(of: path)
    entries[path] = .text(text)
  }

  func addFolder(at path: String) throws {
    try checkWritable()
    try checkNew(path)
    addParents(of: path)
    folders.insert(path)
  }

  /// Files or folders from elsewhere, into `folder` ("" for the top), copied on Save. A folder
  /// comes with everything in it but hidden files; links are refused.
  func addFiles(_ urls: [URL], into folder: String = "") throws {
    try checkWritable()
    for url in urls {
      guard let info = SkillScanner.stat(url), !info.isSymlink else { throw Failure("\(url.lastPathComponent) is a link; skills can't hold links.") }
      let path = folder.isEmpty ? url.lastPathComponent : folder + "/" + url.lastPathComponent
      try checkNew(path)
      addParents(of: path)
      if info.isDirectory {
        let inside = SkillScanner.fingerprint(url)
        if let link = inside.first(where: \.isSymlink) { throw Failure("\(link.relPath) is a link; skills can't hold links.") }
        folders.insert(path)
        for item in inside {
          if item.isDirectory {
            folders.insert(path + "/" + item.relPath)
          } else {
            entries[path + "/" + item.relPath] = .copy(url.appending(path: item.relPath))
          }
        }
      } else {
        entries[path] = .copy(url)
      }
    }
  }

  /// Renames a file or folder (moving it if the new path is elsewhere). SKILL.md can't be.
  func rename(_ path: String, to newPath: String) throws {
    try checkWritable()
    guard path != SkillScanner.skillFileName else { throw Failure("SKILL.md can't be renamed.") }
    guard path != newPath else { return }
    guard entries[path] != nil || folders.contains(path) else { throw Failure("“\(path)” isn't in the skill.") }
    guard !newPath.hasPrefix(path + "/") else { throw Failure("A folder can't go inside itself.") }
    try checkNew(newPath)
    addParents(of: newPath)
    if let entry = entries.removeValue(forKey: path) {
      entries[newPath] = entry
      return
    }
    folders.remove(path)
    folders.insert(newPath)
    for folder in folders where folder.hasPrefix(path + "/") {
      folders.remove(folder)
      folders.insert(newPath + folder.dropFirst(path.count))
    }
    for (key, entry) in entries where key.hasPrefix(path + "/") {
      entries[key] = nil
      entries[newPath + key.dropFirst(path.count)] = entry
    }
  }

  /// Takes a file or folder (with what's in it) out of the draft. SKILL.md can't be.
  func remove(_ path: String) throws {
    try checkWritable()
    guard path != SkillScanner.skillFileName else { throw Failure("SKILL.md can't be removed.") }
    entries[path] = nil
    folders.remove(path)
    for key in entries.keys where key.hasPrefix(path + "/") { entries[key] = nil }
    for folder in folders where folder.hasPrefix(path + "/") { folders.remove(folder) }
  }

  // MARK: - Saving

  /// Writes the draft as the skill's folder (renamed to the name if that changed), then reads it
  /// back as the new base. Refused for Atelier's skills, for a name you already have (nothing is
  /// written), and when the disk changed since it was read, until Keep Mine. A skill the rules
  /// call invalid can be saved: it's shown with its problems and isn't served.
  func save() async throws {
    try checkWritable()
    guard let store else { throw Failure("The skill can't be saved here.") }
    if diskChanged() { throw Failure.changedOnDisk }
    var files: [String: SkillStore.WritePlan.Source] = [:]
    for (path, entry) in entries {
      switch entry {
      case .original(let original): files[path] = .original(original)
      case .text(let text): files[path] = .data(Data(text.utf8))
      case .copy(let url): files[path] = .file(url)
      }
    }
    let saved = try await store.write(
      SkillStore.WritePlan(
        skill: skill, name: name, skillFile: skillFileData, files: files, folders: folders, originals: originalFiles, originalFolders: originalFolders))
    load(saved)
  }
}
#endif
