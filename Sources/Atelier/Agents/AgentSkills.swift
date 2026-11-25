#if os(macOS)
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers
import ZIPFoundation

/// One file of a skill as agents get it (Skills: Skill Entries, `SkillResource`): its path in
/// the skill's folder, its size and the SHA-256 of its bytes.
nonisolated struct SkillFile: Sendable, Equatable {
  var relPath: String
  var size: Int
  /// `sha256:` and 64 lowercase hex digits.
  var digest: String
  var mimeType: String
}

/// What a skill's folder looked like when it was read: every file and folder's path, size,
/// modification time and inode, taken with `lstat`. Each request compares the folder with it
/// instead of watching the disk, and reads it again only when something differs.
nonisolated struct SkillFingerprint: Sendable, Equatable {
  var relPath: String
  var size: Int64
  var modified: timespec
  var inode: UInt64
  var isDirectory: Bool
  var isSymlink: Bool

  static func == (a: Self, b: Self) -> Bool {
    a.relPath == b.relPath && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
      && a.inode == b.inode && a.isDirectory == b.isDirectory && a.isSymlink == b.isSymlink
  }
}

/// A skill folder: Atelier's own (in the app, read-only) or the user's. Only a valid one that's
/// turned on, and not overridden by the user's of the same name, is served.
nonisolated struct Skill: @unchecked Sendable, Identifiable {
  enum Origin: String, Sendable {
    case builtIn, user
  }

  /// The folder's name, which a valid skill's frontmatter `name` matches.
  let name: String
  let origin: Origin
  let directory: URL
  /// SKILL.md's frontmatter as JSON values, when it could be read. Never changed after the scan
  /// (hence `@unchecked Sendable`).
  let frontmatter: [String: Any]?
  /// Every file with its digest; empty unless the skill is valid (only served skills are hashed).
  let files: [SkillFile]
  /// Every folder inside the skill, for `resources/directory/read`.
  let directories: [String]
  /// Why it isn't served: Agent Skills rules, YAML errors, the extension's limits, links.
  let issues: [String]
  let fingerprint: [SkillFingerprint]
  /// A built-in skill the user has one of the same name for.
  var overridden = false
  var isEnabled = true

  var id: String { "\(origin.rawValue)/\(name)" }
  var uri: String { SkillURI.make(skill: name, path: SkillScanner.skillFileName) }
  var isValid: Bool { issues.isEmpty }
  var isServed: Bool { isValid && isEnabled && !overridden }
  var summary: String? { frontmatter?["description"] as? String }
  var totalSize: Int { fingerprint.filter { !$0.isDirectory }.reduce(0) { $0 + Int($1.size) } }

  func file(_ relPath: String) -> SkillFile? { files.first { $0.relPath == relPath } }
}

/// Reads skill folders. Pure and off the main actor: the store runs it detached.
nonisolated enum SkillScanner {
  static let skillFileName = "SKILL.md"
  /// The extension's per-skill limits (Skills: Limits): servers should not serve past them.
  static let maxFiles = 512
  static let maxBytes = 16 * 1024 * 1024

  /// Every skill folder in `root`, reusing a previous scan's skill (`previous`, by name) whose
  /// fingerprint hasn't changed.
  static func scan(root: URL, origin: Skill.Origin, previous: [String: Skill] = [:]) -> [Skill] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
    var skills: [Skill] = []
    for name in names.sorted() where !name.hasPrefix(".") {
      let directory = root.appending(path: name, directoryHint: .isDirectory)
      guard let info = stat(directory) else { continue }
      if info.isSymlink {
        skills.append(
          Skill(
            name: name, origin: origin, directory: directory, frontmatter: nil, files: [], directories: [],
            issues: ["The skill's folder is a link; skills can't be links."], fingerprint: []))
        continue
      }
      guard info.isDirectory else { continue }
      let print = fingerprint(directory)
      if let old = previous[name], old.fingerprint == print, old.directory == directory {
        skills.append(old)
      } else {
        skills.append(scanSkill(directory, origin: origin, fingerprint: print))
      }
    }
    return skills
  }

  /// `lstat` of one item: links are never followed.
  static func stat(_ url: URL) -> SkillFingerprint? {
    var info = Darwin.stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    let type = info.st_mode & S_IFMT
    return SkillFingerprint(
      relPath: "", size: Int64(info.st_size), modified: info.st_mtimespec, inode: UInt64(info.st_ino), isDirectory: type == S_IFDIR,
      isSymlink: type == S_IFLNK)
  }

  /// The folder's items below `directory`, in path order. For serving, hidden ones are left out
  /// and the walk stops once there are more files than a skill may have, which is enough to say
  /// it's too big. The editor sees everything (`includesHidden`, no `limit`), so a Save can
  /// carry every item over.
  static func fingerprint(_ directory: URL, includesHidden: Bool = false, limit: Int = maxFiles) -> [SkillFingerprint] {
    var prints: [SkillFingerprint] = []
    var files = 0
    func walk(_ folder: URL, prefix: String) {
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
      for name in names.sorted() where includesHidden || !name.hasPrefix(".") {
        guard files <= limit else { return }
        let url = folder.appending(path: name)
        guard var print = stat(url) else { continue }
        // A name from the directory listing has no slash, so the path stays inside the skill.
        print.relPath = prefix + name
        prints.append(print)
        if print.isDirectory {
          walk(url, prefix: print.relPath + "/")
        } else {
          files += 1
        }
      }
    }
    walk(directory, prefix: "")
    return prints
  }

  /// A skill's folder read in full: SKILL.md parsed and checked, and, if nothing's wrong, every
  /// file hashed.
  static func scanSkill(_ directory: URL, origin: Skill.Origin, fingerprint print: [SkillFingerprint]) -> Skill {
    let name = directory.lastPathComponent
    var issues = structuralIssues(print)
    var frontmatter: [String: Any]?
    let hasSkillFile = print.contains { $0.relPath == skillFileName && !$0.isDirectory && !$0.isSymlink }
    if !hasSkillFile {
      issues.append("There's no SKILL.md in the folder.")
    } else if let data = try? Data(contentsOf: directory.appending(path: skillFileName)) {
      do {
        let parsed = try SkillFrontmatter.parse(skillFile: data)
        frontmatter = parsed
        issues += SkillFrontmatter.validate(parsed, directoryName: name).map(\.message)
      } catch {
        issues.append(error.localizedDescription)
      }
    } else {
      issues.append("SKILL.md can't be read.")
    }
    var files: [SkillFile] = []
    if issues.isEmpty {
      for item in print where !item.isDirectory {
        let url = directory.appending(path: item.relPath)
        guard let data = try? Data(contentsOf: url) else {
          issues.append("\(item.relPath) can't be read.")
          continue
        }
        files.append(SkillFile(relPath: item.relPath, size: data.count, digest: digest(data), mimeType: mimeType(for: item.relPath)))
      }
      if !issues.isEmpty { files = [] }
    }
    return Skill(
      name: name, origin: origin, directory: directory, frontmatter: frontmatter, files: files,
      directories: print.filter(\.isDirectory).map(\.relPath), issues: issues, fingerprint: print)
  }

  /// Links (never followed, so refused) and the extension's limits.
  static func structuralIssues(_ print: [SkillFingerprint]) -> [String] {
    var issues: [String] = []
    let links = print.filter(\.isSymlink).map(\.relPath)
    if let first = links.first {
      issues.append(links.count == 1 ? "\(first) is a link; skills can't hold links." : "\(first) and \(links.count - 1) more are links; skills can't hold links.")
    }
    let files = print.filter { !$0.isDirectory }
    if files.count > maxFiles {
      issues.append("More than \(maxFiles) files; a skill can have at most \(maxFiles).")
    }
    let bytes = files.reduce(Int64(0)) { $0 + $1.size }
    if bytes > Int64(maxBytes) {
      issues.append("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) in all; a skill can hold at most 16 MiB.")
    }
    return issues
  }

  static func digest(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// `text/markdown` for Markdown, as the extension asks of SKILL.md; otherwise what the type
  /// system knows the extension as.
  static func mimeType(for relPath: String) -> String {
    let ext = (relPath as NSString).pathExtension.lowercased()
    if ext == "md" || ext == "markdown" { return "text/markdown" }
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType else { return "application/octet-stream" }
    return mime
  }

  /// A file's bytes as `text`, when they're text and the text's UTF-8 is exactly those bytes:
  /// decoding drops a byte-order mark, and a client checking the digest and size must get back
  /// what was hashed, so such a file goes as a base64 blob.
  static func text(_ data: Data, mimeType: String) -> String? {
    guard isTextual(mimeType), let text = String(data: data, encoding: .utf8), Data(text.utf8) == data else { return nil }
    return text
  }

  /// Whether bytes of this type are text to hand over as `text` rather than base64.
  static func isTextual(_ mimeType: String) -> Bool {
    if mimeType.hasPrefix("text/") { return true }
    if ["application/json", "application/xml", "application/x-yaml", "application/yaml", "application/javascript", "application/x-sh"].contains(mimeType) { return true }
    return UTType(mimeType: mimeType)?.conforms(to: .text) ?? false
  }
}

/// `skill://<name>/<path>` (Skills: Resource Mapping). Atelier's skills sit side by side, so the
/// skill path is the one segment of its name; each segment is percent-encoded.
nonisolated enum SkillURI {
  static let prefix = "skill://"

  /// `path` is relative to the skill's folder; empty for the folder itself (no trailing slash).
  static func make(skill: String, path: String) -> String {
    let segments = [skill] + (path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    return prefix + segments.map(encode).joined(separator: "/")
  }

  private static let segmentAllowed: CharacterSet = {
    var set = CharacterSet.urlPathAllowed
    set.remove(charactersIn: "/;?#%")
    return set
  }()

  private static func encode(_ segment: String) -> String {
    segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
  }

  /// The skill's name and the path in it, or nil for anything that isn't a plain `skill://` URI:
  /// another scheme, a query or fragment, an empty segment or trailing slash, or a `.` or `..`
  /// segment, percent-encoded or not.
  static func parse(_ uri: String) -> (skill: String, path: String)? {
    guard uri.hasPrefix(prefix) else { return nil }
    let rest = uri.dropFirst(prefix.count)
    guard !rest.isEmpty, !rest.contains("?"), !rest.contains("#") else { return nil }
    var segments: [String] = []
    for raw in rest.split(separator: "/", omittingEmptySubsequences: false) {
      guard !raw.isEmpty, let decoded = raw.removingPercentEncoding, !decoded.isEmpty,
        decoded != ".", decoded != "..", !decoded.contains("/"), !decoded.contains("\0")
      else { return nil }
      segments.append(decoded)
    }
    return (segments[0], segments.dropFirst().joined(separator: "/"))
  }
}

/// Zip archives of skills: import (with every entry checked, since a .zip or .skill comes from
/// anywhere) and export.
nonisolated enum SkillArchive {
  struct Failure: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  /// Unpacks `zip` into `destination` (an empty folder). Refused outright: absolute paths, `..`,
  /// backslashes, links, more files than a skill may have (or more than twice that many entries,
  /// folders included: folders don't count toward the extension's limit, but an archive of
  /// endless empty folders must still be refused), or more bytes. Hidden files and
  /// macOS's `__MACOSX` folder are skipped. The byte limit is counted on what's actually
  /// unpacked, not only on what the archive claims.
  static func extract(_ zip: URL, to destination: URL) throws {
    guard let archive = Archive(url: zip, accessMode: .read) else { throw Failure("The file isn't a zip archive.") }
    let root = destination.standardizedFileURL.path
    var entries = 0
    var files = 0
    var claimed: UInt64 = 0
    var written = 0
    for entry in archive {
      let path = entry.path
      if path.hasPrefix("/") || path.contains("\\") || path.contains("\0") {
        throw Failure("The archive has an entry with an unsafe path (\(path)).")
      }
      let components = path.split(separator: "/", omittingEmptySubsequences: true)
      if components.contains(where: { $0 == ".." || $0 == "." }) {
        throw Failure("The archive has an entry with an unsafe path (\(path)).")
      }
      if components.isEmpty || components.first == "__MACOSX" || components.contains(where: { $0.hasPrefix(".") }) { continue }
      guard entry.type != .symlink else { throw Failure("The archive holds a link (\(path)); skills can't hold links.") }
      let target = destination.appending(path: components.joined(separator: "/"))
      guard target.standardizedFileURL.path.hasPrefix(root + "/") else { throw Failure("The archive has an entry with an unsafe path (\(path)).") }
      entries += 1
      guard entries <= 2 * SkillScanner.maxFiles else { throw Failure("The archive has more than \(2 * SkillScanner.maxFiles) entries.") }
      if entry.type == .directory {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        continue
      }
      files += 1
      guard files <= SkillScanner.maxFiles else { throw Failure("The archive has more than \(SkillScanner.maxFiles) files; a skill can have at most \(SkillScanner.maxFiles).") }
      claimed += entry.uncompressedSize
      guard claimed <= UInt64(SkillScanner.maxBytes) else { throw Failure("The archive unpacks to more than 16 MiB; a skill can hold at most 16 MiB.") }
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw Failure("Couldn't unpack \(path).") }
      let handle = try FileHandle(forWritingTo: target)
      defer { try? handle.close() }
      _ = try archive.extract(entry) { chunk in
        written += chunk.count
        guard written <= SkillScanner.maxBytes else { throw Failure("The archive unpacks to more than 16 MiB; a skill can hold at most 16 MiB.") }
        try handle.write(contentsOf: chunk)
      }
    }
  }

  /// A zip of the skill's files under a folder of its name, as `importItem` reads back.
  static func create(_ zip: URL, folder: URL, name: String) throws {
    try? FileManager.default.removeItem(at: zip)
    guard let archive = Archive(url: zip, accessMode: .create) else { throw Failure("Couldn't make the archive.") }
    let print = SkillScanner.fingerprint(folder)
    if let link = print.first(where: \.isSymlink) { throw Failure("\(link.relPath) is a link; skills can't hold links.") }
    for item in print {
      if item.isDirectory {
        try archive.addEntry(with: "\(name)/\(item.relPath)/", type: .directory, uncompressedSize: Int64(0), provider: { (_: Int64, _: Int) in Data() })
      } else {
        try archive.addEntry(with: "\(name)/\(item.relPath)", fileURL: folder.appending(path: item.relPath), compressionMethod: .deflate)
      }
    }
  }
}

/// One Save's disk work (`SkillStore.write`), off the main actor.
nonisolated struct SkillWriteJob: @unchecked Sendable {
  let plan: SkillStore.WritePlan
  let userDirectory: URL
  let destination: URL
  let usesTrash: Bool

  func run() throws {
    let manager = FileManager.default
    let old = plan.skill.directory
    let token = UUID().uuidString
    let staging = userDirectory.appending(path: ".save-\(token)", directoryHint: .isDirectory)
    let held = userDirectory.appending(path: ".held-\(token)", directoryHint: .isDirectory)
    defer {
      try? manager.removeItem(at: staging)
      try? manager.removeItem(at: held)
    }
    try manager.copyItem(at: old, to: staging)
    // The files the draft knew are moved aside, then put back where it says (or not at all).
    for path in plan.originals {
      let from = staging.appending(path: path)
      guard SkillScanner.stat(from) != nil else { continue }
      let to = held.appending(path: path)
      try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
      try manager.moveItem(at: from, to: to)
    }
    // Folders the draft removed go, with what's left in them; deepest first.
    for folder in plan.originalFolders.sorted(by: { $0.count > $1.count }) where !plan.folders.contains(folder) {
      let url = staging.appending(path: folder, directoryHint: .isDirectory)
      if SkillScanner.stat(url) != nil { try manager.removeItem(at: url) }
    }
    for folder in plan.folders.sorted() {
      try manager.createDirectory(at: staging.appending(path: folder, directoryHint: .isDirectory), withIntermediateDirectories: true)
    }
    for (path, source) in plan.files {
      let target = staging.appending(path: path)
      try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      if SkillScanner.stat(target) != nil { try manager.removeItem(at: target) }
      switch source {
      case .original(let original):
        try manager.moveItem(at: held.appending(path: original), to: target)
      case .file(let url):
        if SkillScanner.stat(url)?.isSymlink != false { throw SkillStore.Failure("\(path) is a link or missing; skills can't hold links.") }
        try manager.copyItem(at: url, to: target)
      case .data(let data):
        try data.write(to: target)
      }
    }
    try plan.skillFile.write(to: staging.appending(path: SkillScanner.skillFileName))
    try swap(staging, replacing: old)
  }

  /// Puts the finished folder at `destination` and the old one in the Trash. If the last move
  /// fails, the old folder comes back from the Trash.
  private func swap(_ staging: URL, replacing old: URL) throws {
    let manager = FileManager.default
    let renamed = destination.standardizedFileURL.path != old.standardizedFileURL.path
    if renamed, SkillScanner.stat(destination) != nil { throw SkillStore.Failure("You already have a skill named “\(destination.lastPathComponent)”.") }
    var removed: NSURL?
    if usesTrash {
      try manager.trashItem(at: old, resultingItemURL: &removed)
    } else {
      let aside = userDirectory.appending(path: ".old-\(UUID().uuidString)", directoryHint: .isDirectory)
      try manager.moveItem(at: old, to: aside)
      removed = aside as NSURL
    }
    do {
      try manager.moveItem(at: staging, to: destination)
    } catch {
      if let removed = removed as URL? { try? manager.moveItem(at: removed, to: old) }
      throw error
    }
    if !usesTrash, let removed = removed as URL? { try? manager.removeItem(at: removed) }
  }
}

/// The skills agents get: Atelier's own, read in place from the app (`Contents/Resources/Skills`,
/// never written), and the user's in Application Support/Atelier/Skills (a temporary folder in
/// scripted runs and tests). Also the Skills screen's state: each skill's unsaved draft and what
/// the screen showed last.
@MainActor
@Observable
final class SkillStore {
  nonisolated struct Failure: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  /// What one Save writes (`SkillEditorModel.save`): the folder's new contents, all at once.
  nonisolated struct WritePlan {
    enum Source {
      /// A file of the old folder, by its path as read.
      case original(String)
      /// A file from elsewhere, copied in.
      case file(URL)
      case data(Data)
    }

    var skill: Skill
    var name: String
    var skillFile: Data
    /// Every file but SKILL.md, by its path in the saved folder, hidden ones included.
    var files: [String: Source]
    var folders: Set<String>
    /// The files and folders of the old folder the draft knew (paths as read): the ones the
    /// draft doesn't keep are removed, and the others moved to where `files` puts them.
    var originals: [String] = []
    var originalFolders: [String] = []
  }

  static let disabledKey = "agentServer.disabledSkills"
  private static let selectionKey = "skillsSelection"
  private static let tabKey = "skillsTab"
  private static let searchKey = "skillsSearch"

  let userDirectory: URL
  let builtInDirectory: URL?
  private let defaults: UserDefaults
  private let persistsScreenState: Bool
  /// Deleted skills and files go to the Trash, except in a scripted run's temporary folder.
  private let usesTrash: Bool

  /// Every skill found, the user's before Atelier's for the same name, then by name.
  private(set) var skills: [Skill] = []
  /// Names turned off in the Skills screen: `agentServer.disabledSkills`.
  private(set) var disabled: Set<String>
  /// The Skills screen's unsaved edits, by skill id; they live as long as the app does.
  var drafts: [String: SkillEditorModel] = [:]

  /// The Skills screen's selected skill id, tab and filter, remembered when the session is.
  var screenSelection: String? {
    didSet { if persistsScreenState { defaults.set(screenSelection, forKey: Self.selectionKey) } }
  }
  var screenTab: String {
    didSet { if persistsScreenState { defaults.set(screenTab, forKey: Self.tabKey) } }
  }
  var screenSearch: String {
    didSet { if persistsScreenState { defaults.set(screenSearch, forKey: Self.searchKey) } }
  }

  static var defaultUserDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Atelier/Skills", directoryHint: .isDirectory)
  }

  static var bundledDirectory: URL? { Bundle.main.resourceURL?.appending(path: "Skills", directoryHint: .isDirectory) }

  /// The app's store: the user's folder, or in a scripted run a temporary one (the app's own
  /// skills are read either way, since nothing writes them).
  static func makeForApp() -> SkillStore {
    if Automation.isRequested {
      let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
      return SkillStore(userDirectory: folder, persistsScreenState: false, usesTrash: false)
    }
    return SkillStore()
  }

  init(
    userDirectory: URL = SkillStore.defaultUserDirectory, builtInDirectory: URL? = SkillStore.bundledDirectory, defaults: UserDefaults = .standard,
    persistsScreenState: Bool = SessionState.isEnabled, usesTrash: Bool = true, loads: Bool = true
  ) {
    self.userDirectory = userDirectory
    self.builtInDirectory = builtInDirectory
    self.defaults = defaults
    self.persistsScreenState = persistsScreenState
    self.usesTrash = usesTrash
    disabled = Set(defaults.object(forKey: Self.disabledKey) as? [String] ?? [])
    screenSelection = persistsScreenState ? defaults.string(forKey: Self.selectionKey) : nil
    screenTab = (persistsScreenState ? defaults.string(forKey: Self.tabKey) : nil) ?? "instructions"
    screenSearch = (persistsScreenState ? defaults.string(forKey: Self.searchKey) : nil) ?? ""
    if loads { Task { await reload() } }
  }

  /// What agents get: valid, on, and not overridden.
  var served: [Skill] { skills.filter(\.isServed) }

  /// Whether any skill has edits not saved yet, for the quit warning.
  var hasUnsavedEdits: Bool { drafts.values.contains { $0.isDirty } }
  var unsavedSkillNames: [String] { drafts.values.filter(\.isDirty).map(\.skill.name).sorted() }

  // MARK: - Reading

  /// Reads both folders again, off the main actor; skills whose folders haven't changed are kept
  /// as they were, digests and all.
  func reload() async {
    let previous = skills
    let user = userDirectory
    let builtIn = builtInDirectory
    let found = await Task.detached(priority: .userInitiated) {
      let userPrevious = Dictionary(previous.filter { $0.origin == .user }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
      let builtInPrevious = Dictionary(previous.filter { $0.origin == .builtIn }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
      let mine = SkillScanner.scan(root: user, origin: .user, previous: userPrevious)
      let ours = builtIn.map { SkillScanner.scan(root: $0, origin: .builtIn, previous: builtInPrevious) } ?? []
      return (mine, ours)
    }.value
    skills = decorate(user: found.0, builtIn: found.1)
  }

  private func decorate(user: [Skill], builtIn: [Skill]) -> [Skill] {
    let mine = Set(user.map(\.name))
    let all = user + builtIn.map { skill in
      var skill = skill
      skill.overridden = mine.contains(skill.name)
      return skill
    }
    return all.map { skill in
      var skill = skill
      skill.isEnabled = !disabled.contains(skill.name)
      return skill
    }.sorted { $0.name == $1.name ? $0.origin == .user : $0.name < $1.name }
  }

  /// The skills served now: the folders are checked against their fingerprints first, so a file
  /// changed on disk is seen by the next request.
  func current() async -> [Skill] {
    await reload()
    return served
  }

  /// The served skill a URI names, and the file in it (nil for a folder or anything unknown).
  func served(uri: String) -> (skill: Skill, path: String)? {
    guard let (name, path) = SkillURI.parse(uri), let skill = served.first(where: { $0.name == name }) else { return nil }
    return (skill, path)
  }

  /// A served skill's file on disk, for this Mac's own use (the Skills screen); never sent to
  /// clients.
  func fileURL(for uri: String) -> URL? {
    guard let (skill, path) = served(uri: uri), skill.file(path) != nil else { return nil }
    return skill.directory.appending(path: path)
  }

  /// A served file's bytes, checked against the listing's digest: bytes that no longer match
  /// mean the folder changed since it was read, so it's read again (twice at most) before
  /// answering, and bytes that still don't match what the fresh listing says are an error rather
  /// than content a client would fail to verify. `reader` is for tests.
  func read(
    uri: String, reader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
  ) async throws -> (file: SkillFile, data: Data)? {
    _ = await current()
    for attempt in 0..<3 {
      if attempt > 0 { await reload() }
      guard let (skill, path) = served(uri: uri), let file = skill.file(path) else { return nil }
      let url = skill.directory.appending(path: path)
      let data = try await Task.detached { try reader(url) }.value
      if data.count == file.size, SkillScanner.digest(data) == file.digest { return (file, data) }
    }
    throw Failure("The file kept changing while it was read; try again.")
  }

  // MARK: - Turning on and off

  func setEnabled(_ skill: Skill, _ isEnabled: Bool) {
    if isEnabled { disabled.remove(skill.name) } else { disabled.insert(skill.name) }
    defaults.set(disabled.sorted(), forKey: Self.disabledKey)
    skills = decorate(user: skills.filter { $0.origin == .user }, builtIn: skills.filter { $0.origin == .builtIn })
  }

  // MARK: - Making and removing skills

  /// Whether `name` would do as a folder name for a skill, even one the Agent Skills rules call
  /// invalid: saving an invalid skill is allowed, writing outside the folder isn't.
  static func folderNameProblem(_ name: String) -> String? {
    if name.isEmpty || name == "." || name == ".." || name.hasPrefix(".") || name.contains("/") || name.contains(":") || name.contains("\0") {
      return "“\(name)” can't be a folder name."
    }
    return nil
  }

  private func userSkillExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: userDirectory.appending(path: name).path)
  }

  private func takenMessage(_ name: String) -> String { "You already have a skill named “\(name)”." }

  /// A new skill of yours with a SKILL.md to fill in.
  @discardableResult func create(name: String) async throws -> Skill {
    if let problem = SkillFrontmatter.nameProblem(name) { throw Failure(problem) }
    guard !userSkillExists(name) else { throw Failure(takenMessage(name)) }
    let folder = userDirectory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = SkillFrontmatter.serialize(
      name: name, description: "What this skill does and when an agent should use it.", otherYAML: "",
      body: "\n# \(name)\n\nSteps for the agent to follow, and which of Atelier's tools to call.\n")
    try data.write(to: folder.appending(path: SkillScanner.skillFileName), options: .atomic)
    return try await reloaded(name)
  }

  private func reloaded(_ name: String) async throws -> Skill {
    await reload()
    guard let skill = skills.first(where: { $0.origin == .user && $0.name == name }) else { throw Failure("The skill “\(name)” wasn't found after writing it.") }
    return skill
  }

  /// A skill folder, .zip or .skill (a zip) as a skill of yours, named by its frontmatter (or
  /// its folder). A zip with one folder at the top is that folder. Refused when the name is
  /// taken, or the skill holds links or is past the limits; anything else wrong with it is
  /// imported and shown.
  @discardableResult func importItem(at url: URL) async throws -> Skill {
    try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
    let staging = userDirectory.appending(path: ".import-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: staging) }
    let payload = staging.appending(path: "payload", directoryHint: .isDirectory)
    let root = try await Task.detached { () throws -> URL in
      try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
      var isFolder: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw Failure("The file isn't there.") }
      if isFolder.boolValue {
        let copy = payload.appending(path: url.lastPathComponent, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
      }
      try SkillArchive.extract(url, to: payload)
      let top = ((try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
      if !top.contains(SkillScanner.skillFileName), top.count == 1 {
        let only = payload.appending(path: top[0], directoryHint: .isDirectory)
        if SkillScanner.stat(only)?.isDirectory == true { return only }
      }
      return payload
    }.value
    let skillFile = root.appending(path: SkillScanner.skillFileName)
    guard let data = try? Data(contentsOf: skillFile) else { throw Failure("There's no SKILL.md in it.") }
    let declared = (try? SkillFrontmatter.parse(skillFile: data))?["name"] as? String
    let fallback = url.hasDirectoryPath || root != payload ? root.lastPathComponent : url.deletingPathExtension().lastPathComponent
    guard let name = [declared, fallback].compactMap(\.self).first(where: { SkillFrontmatter.nameProblem($0) == nil }) else {
      throw Failure("The skill needs a name of lowercase letters, digits and hyphens in its SKILL.md.")
    }
    let structural = SkillScanner.structuralIssues(SkillScanner.fingerprint(root))
    if let issue = structural.first { throw Failure(issue) }
    guard !userSkillExists(name) else { throw Failure(takenMessage(name)) }
    try FileManager.default.moveItem(at: root, to: userDirectory.appending(path: name, directoryHint: .isDirectory))
    return try await reloaded(name)
  }

  /// A copy of yours to edit, of any skill (Atelier's included): `name-copy`, or with a number.
  @discardableResult func duplicate(_ skill: Skill) async throws -> Skill {
    // The name shortened to leave room for the suffix, so a long one still makes a valid name.
    func candidate(_ suffix: String) -> String {
      let room = SkillFrontmatter.maxNameLength - suffix.count
      let base = String(skill.name.prefix(room)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
      return base + suffix
    }
    var name = candidate("-copy")
    var number = 2
    while userSkillExists(name) {
      name = candidate("-copy-\(number)")
      number += 1
    }
    try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
    let staging = userDirectory.appending(path: ".copy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.copyItem(at: skill.directory, to: staging)
    let skillFile = staging.appending(path: SkillScanner.skillFileName)
    if let data = try? Data(contentsOf: skillFile), let (yaml, body) = try? SkillFrontmatter.split(data) {
      let description = (try? SkillFrontmatter.parse(yaml))?["description"] as? String ?? ""
      let renamed = SkillFrontmatter.serialize(name: name, description: description, otherYAML: SkillFrontmatter.extractOther(yaml: yaml), body: body)
      try renamed.write(to: skillFile, options: .atomic)
    }
    try FileManager.default.moveItem(at: staging, to: userDirectory.appending(path: name, directoryHint: .isDirectory))
    return try await reloaded(name)
  }

  /// One of your skills, to the Trash (deleted outright in a scripted run's folder).
  func delete(_ skill: Skill) async throws {
    guard skill.origin == .user else { throw Failure("Atelier's own skills can't be deleted.") }
    try remove(skill.directory)
    drafts[skill.id] = nil
    if screenSelection == skill.id { screenSelection = nil }
    await reload()
  }

  private func remove(_ url: URL) throws {
    if usesTrash {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    } else {
      try FileManager.default.removeItem(at: url)
    }
  }

  /// The skill as a zip at `destination`, a folder of its name inside.
  func export(_ skill: Skill, to destination: URL) async throws {
    let folder = skill.directory
    let name = skill.name
    try await Task.detached {
      let temporary = FileManager.default.temporaryDirectory.appending(path: "atelier-skill-export-\(UUID().uuidString).zip")
      defer { try? FileManager.default.removeItem(at: temporary) }
      try SkillArchive.create(temporary, folder: folder, name: name)
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
    }.value
  }

  // MARK: - Files in a skill

  /// A path inside a skill that's safe to write: relative, no `.`/`..` or hidden parts.
  static func safeRelativePath(_ path: String) -> String? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\0") && !$0.contains(":") }) else { return nil }
    return path
  }

  /// The file a folder operation touches, refused if anything on the way to it (the skill's
  /// folder included) is a link, which would lead outside the skill.
  private func editable(_ skill: Skill, _ path: String, allowsSkillFile: Bool = true) throws -> URL {
    guard skill.origin == .user else { throw Failure("Built-in skills can't be changed.") }
    guard let path = Self.safeRelativePath(path) else { throw Failure("“\(path)” isn't a path inside the skill.") }
    if !allowsSkillFile, path == SkillScanner.skillFileName { throw Failure("SKILL.md can't be renamed or removed.") }
    var url = skill.directory
    if SkillScanner.stat(url)?.isSymlink != false { throw Failure("The skill's folder is a link or missing.") }
    for component in path.split(separator: "/") {
      url = url.appending(path: String(component))
      if SkillScanner.stat(url)?.isSymlink == true { throw Failure("“\(path)” goes through a link; skills can't hold links.") }
    }
    return url
  }

  func newFile(_ skill: Skill, at path: String, contents: Data = Data()) async throws {
    let url = try editable(skill, path)
    guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure("“\(path)” is already there.") }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, options: .withoutOverwriting)
    await reload()
  }

  func newFolder(_ skill: Skill, at path: String) async throws {
    let url = try editable(skill, path)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    await reload()
  }

  /// Copies files or folders from elsewhere into the skill's `folder` ("" for its top). Links
  /// are refused.
  func addFiles(_ urls: [URL], to skill: Skill, folder: String = "") async throws {
    for url in urls {
      if let link = ([SkillScanner.stat(url)].compactMap(\.self) + SkillScanner.fingerprint(url)).first(where: \.isSymlink) {
        throw Failure("\(link.relPath.isEmpty ? url.lastPathComponent : link.relPath) is a link; skills can't hold links.")
      }
      let path = folder.isEmpty ? url.lastPathComponent : folder + "/" + url.lastPathComponent
      let target = try editable(skill, path)
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: url, to: target)
    }
    await reload()
  }

  func renameFile(_ skill: Skill, at path: String, to newPath: String) async throws {
    let from = try editable(skill, path, allowsSkillFile: false)
    let to = try editable(skill, newPath, allowsSkillFile: false)
    guard !FileManager.default.fileExists(atPath: to.path) else { throw Failure("“\(newPath)” is already there.") }
    try FileManager.default.moveItem(at: from, to: to)
    await reload()
  }

  func trashFile(_ skill: Skill, at path: String) async throws {
    try remove(try editable(skill, path, allowsSkillFile: false))
    await reload()
  }

  /// Writes a Save. The new folder starts as a copy of the old one, so whatever the draft didn't
  /// track (links, anything new on disk since Keep Mine) comes along; the draft's files are then
  /// moved, removed and written on that copy, which is swapped in only once it's complete. The
  /// old folder goes to the Trash (deleted in a scripted run's folder). Anything that fails
  /// before the swap leaves the skill as it was. A new name moves it to a folder of that name,
  /// refused (with nothing written) if you have one already. The copying runs off the main actor.
  @discardableResult func write(_ plan: WritePlan) async throws -> Skill {
    let skill = plan.skill
    guard skill.origin == .user else { throw Failure("Built-in skills can't be changed.") }
    if let problem = Self.folderNameProblem(plan.name) { throw Failure(problem) }
    let renamed = plan.name != skill.name
    if renamed, userSkillExists(plan.name) { throw Failure(takenMessage(plan.name)) }
    for path in Array(plan.files.keys) + Array(plan.folders) + plan.originals where !Self.isInside(path) || path == SkillScanner.skillFileName {
      throw Failure("“\(path)” isn't a path inside the skill.")
    }
    let job = SkillWriteJob(
      plan: plan, userDirectory: userDirectory, destination: userDirectory.appending(path: plan.name, directoryHint: .isDirectory),
      usesTrash: usesTrash)
    try await Task.detached { try job.run() }.value
    if renamed {
      let newID = "user/\(plan.name)"
      if let draft = drafts.removeValue(forKey: skill.id) { drafts[newID] = draft }
      if screenSelection == skill.id { screenSelection = newID }
      if disabled.remove(skill.name) != nil {
        disabled.insert(plan.name)
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)
      }
    }
    return try await reloaded(plan.name)
  }

  /// A relative path that stays inside a folder: no empty, `.` or `..` parts. Hidden parts are
  /// allowed, since a Save carries hidden files along.
  nonisolated static func isInside(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
  }

  // MARK: - Drafts

  /// The skill's draft, made from the disk the first time.
  func draft(for skill: Skill) -> SkillEditorModel {
    if let draft = drafts[skill.id] { return draft }
    let draft = SkillEditorModel(skill: skill, store: self)
    drafts[skill.id] = draft
    return draft
  }
}
#endif
