import CoreGraphics
import Foundation
import Observation

/// A prompt style: a template the prompt is written into at Generate. Each `{{TAG}}` in it is a
/// box on the Create screen in place of the prompt box; `{{SUBJECT}}` is the prompt itself.
/// `{{TAG:text}}` gives the text used when the box is left empty. The format is in docs/styles.md.
nonisolated struct Style: Codable, Identifiable, Hashable {
  var id = UUID()
  var name: String
  var category = ""
  var subcategory = ""
  var template: String
  /// Added to the negative prompt.
  var negative = ""
  var notes = ""

  /// The tag the prompt fills.
  static let subject = "SUBJECT"
  static let subjectPlaceholder = "{{SUBJECT}}"
  /// `{{TAG}}` or `{{TAG:default}}`: group 1 is the tag, group 2 its default.
  private static let placeholder = try! NSRegularExpression(pattern: #"\{\{([A-Za-z_][A-Za-z0-9_]*)(?::([^}]*))?\}\}"#)

  /// The template, with `{{SUBJECT}}` in front when it has none: the prompt goes first.
  private var fullTemplate: String {
    template.range(of: #"\{\{SUBJECT(:[^}]*)?\}\}"#, options: .regularExpression) != nil
      ? template : Self.subjectPlaceholder + " " + template
  }

  /// Each tag's default text (from its first `{{TAG:default}}`), used when its box is empty.
  var defaults: [String: String] {
    let text = fullTemplate as NSString
    var defaults: [String: String] = [:]
    for found in Self.placeholder.matches(in: fullTemplate, range: NSRange(location: 0, length: text.length))
      where found.range(at: 2).location != NSNotFound
    {
      let tag = text.substring(with: found.range(at: 1))
      let value = text.substring(with: found.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
      if defaults[tag] == nil, !value.isEmpty { defaults[tag] = value }
    }
    return defaults
  }

  /// The template's tags in the order they first appear, `SUBJECT` always among them.
  var tags: [String] {
    let text = fullTemplate as NSString
    var seen = Set<String>()
    return Self.placeholder.matches(in: fullTemplate, range: NSRange(location: 0, length: text.length))
      .map { text.substring(with: $0.range(at: 1)) }
      .filter { seen.insert($0).inserted }
  }

  /// A tag as a box's label: `CAMERA_ANGLE` is "Camera angle".
  static func label(_ tag: String) -> String {
    let words = tag.replacingOccurrences(of: "_", with: " ").lowercased()
    return words.prefix(1).uppercased() + words.dropFirst()
  }

  /// The prompt and negative prompt a run sends: each tag replaced by its value (`SUBJECT` by the
  /// prompt), or when that's empty its default. A tag left empty with no default is dropped along
  /// with the gap it leaves.
  func apply(_ values: [String: String], negativePrompt: String) -> (prompt: String, negativePrompt: String) {
    let text = fullTemplate as NSString
    let defaults = defaults
    var result = ""
    var location = 0
    for found in Self.placeholder.matches(in: fullTemplate, range: NSRange(location: 0, length: text.length)) {
      result += text.substring(with: NSRange(location: location, length: found.range.location - location))
      let tag = text.substring(with: found.range(at: 1))
      let value = (values[tag] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      result += value.isEmpty ? defaults[tag] ?? "" : value
      location = found.range.location + found.range.length
    }
    result += text.substring(from: location)
    // Close the gap an empty tag leaves, without touching line breaks.
    result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    let negatives = [negativePrompt, negative]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return (result.trimmingCharacters(in: .whitespacesAndNewlines), negatives.joined(separator: ", "))
  }

  /// The reverse of `apply`: the tag values and the user's own negative prompt of a prompt this
  /// style wrote, or nil when it didn't write it. Lets a reused image bring its style back instead
  /// of the style wrapping its already-styled prompt again.
  func match(prompt: String, negativePrompt: String) -> (values: [String: String], negativePrompt: String)? {
    // Literal text with any run of spaces matching any run (an empty tag closes a gap), and each
    // tag a group.
    let text = fullTemplate as NSString
    var pattern = "^\\s*"
    var slots: [String] = []
    var location = 0
    func literal(_ text: String) -> String {
      text.split(omittingEmptySubsequences: false) { $0 == " " || $0 == "\t" }
        .map { NSRegularExpression.escapedPattern(for: String($0)) }
        .joined(separator: "[ \\t]*")
    }
    for found in Self.placeholder.matches(in: fullTemplate, range: NSRange(location: 0, length: text.length)) {
      pattern += literal(text.substring(with: NSRange(location: location, length: found.range.location - location)))
      slots.append(text.substring(with: found.range(at: 1)))
      pattern += "(.*?)"
      location = found.range.location + found.range.length
    }
    pattern += literal(text.substring(from: location)) + "\\s*$"
    let prompt = prompt as NSString
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
          let found = regex.firstMatch(in: prompt as String, range: NSRange(location: 0, length: prompt.length))
    else { return nil }
    var values: [String: String] = [:]
    for (index, slot) in slots.enumerated() where values[slot] == nil {
      values[slot] = prompt.substring(with: found.range(at: index + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard values[Self.subject]?.isEmpty == false else { return nil }
    // A tag holding its default was left empty: its box comes back empty, showing the default.
    for (tag, value) in defaults where values[tag] == value { values[tag] = "" }
    var userNegative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let styleNegative = negative.trimmingCharacters(in: .whitespacesAndNewlines)
    if !styleNegative.isEmpty {
      if userNegative == styleNegative {
        userNegative = ""
      } else if userNegative.hasSuffix(", " + styleNegative) {
        userNegative = String(userNegative.dropLast(styleNegative.count + 2))
      }
    }
    return (values, userNegative)
  }
}

/// Reads and writes style files: Markdown with a `#` heading per category, `##` per subcategory
/// and `###` per style, whose `TEMPLATE:`, `NEGATIVE:` and `NOTES:` sections follow (docs/styles.md).
nonisolated enum StyleFile {
  enum Field: String, CaseIterable {
    case template = "TEMPLATE", negative = "NEGATIVE", notes = "NOTES"
  }

  /// The styles in `text`. Headings with no styles under them (a title, a contents list) are
  /// skipped, as is a style without a template.
  static func parse(_ text: String) -> [Style] {
    var styles: [Style] = []
    var category = ""
    var subcategory = ""
    var name: String?
    var fields: [Field: [String]] = [:]
    var field: Field?

    func finish() {
      defer {
        name = nil
        fields = [:]
        field = nil
      }
      guard let name else { return }
      func value(_ field: Field) -> String {
        (fields[field] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let template = value(.template)
      guard !name.isEmpty, !template.isEmpty else { return }
      styles.append(
        Style(
          name: name, category: category, subcategory: subcategory, template: template,
          negative: value(.negative), notes: value(.notes)))
    }

    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if let heading = heading(line) {
        finish()
        switch heading.level {
        case 1:
          category = heading.title
          subcategory = ""
        case 2: subcategory = heading.title
        default: name = heading.title
        }
        continue
      }
      // A rule ends the style above it.
      if line == "---" || line == "***" {
        finish()
        continue
      }
      guard name != nil else { continue }
      if let (label, rest) = label(line) {
        field = label
        fields[label, default: []].append(rest)
      } else if let field {
        fields[field, default: []].append(rawLine)
      }
    }
    finish()
    return styles
  }

  /// Writes `styles` in the same format, grouped by category and subcategory in the order given.
  static func write(_ styles: [Style]) -> String {
    var out = "# Atelier styles\n"
    var category: String?
    var subcategory: String?
    for style in styles {
      if style.category != category {
        category = style.category
        subcategory = nil
        out += "\n# \(style.category.isEmpty ? "Uncategorized" : style.category)\n"
      }
      if style.subcategory != subcategory {
        // A bare `##` ends the subcategory before it, for a style that has none.
        if !style.subcategory.isEmpty {
          out += "\n## \(style.subcategory)\n"
        } else if subcategory?.isEmpty == false {
          out += "\n##\n"
        }
        subcategory = style.subcategory
      }
      out += "\n### \(style.name)\nTEMPLATE:\n\(style.template)\n"
      if !style.negative.isEmpty { out += "NEGATIVE:\n\(style.negative)\n" }
      if !style.notes.isEmpty { out += "NOTES:\n\(style.notes)\n" }
    }
    return out
  }

  private static func heading(_ line: String) -> (level: Int, title: String)? {
    let hashes = line.prefix { $0 == "#" }.count
    if line == "##" { return (2, "") }
    guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
    return (hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
  }

  /// `TEMPLATE:` on its own line, or with the text after it on the same line.
  private static func label(_ line: String) -> (Field, String)? {
    for field in Field.allCases where line.hasPrefix(field.rawValue + ":") {
      return (field, String(line.dropFirst(field.rawValue.count + 1)).trimmingCharacters(in: .whitespaces))
    }
    return nil
  }
}

/// A named set of styles, called a library in the UI. (`StyleLibrary` is the exported web page.)
nonisolated struct StyleCollection: Codable, Identifiable, Hashable {
  var id = UUID()
  var name: String
  /// Kept in the library's own file; the list of libraries holds only ids and names.
  var styles: [Style] = []

  private enum CodingKeys: String, CodingKey {
    case id, name
  }

  /// Categories in the order their first style appears.
  var categories: [String] {
    var seen = Set<String>()
    return styles.map(\.category).filter { seen.insert($0).inserted }
  }
}

/// The user's styles, in one or more libraries, in Application Support:
///
///     Atelier/StyleLibraries.json                  the libraries' ids and names, in order
///     Atelier/Styles.json, StyleThumbnails/        the first library
///     Atelier/StyleLibraries/<id>/Styles.json, StyleThumbnails/   each other one
///
/// The first library stays where styles were kept before there were libraries, so nothing has to
/// move and a build from before them still reads it. Each library has its own thumbnails folder
/// because such a build removes any thumbnail in `StyleThumbnails` of a style it doesn't know.
@MainActor
@Observable
final class StyleStore {
  /// Never empty.
  private(set) var libraries: [StyleCollection] = []
  /// The library the Styles screen shows, and where new and imported styles go.
  private(set) var currentLibraryID = StyleStore.mainLibraryID {
    didSet { remember(currentLibraryID.uuidString, "stylesLibrary") }
  }
  /// Thumbnails read so far, by style (StyleThumbnails.swift); nil marks one with none.
  var thumbnails: [UUID: CGImage?] = [:]
  /// What each tag takes when making thumbnails, by tag (`SUBJECT` included).
  var thumbnailValues = UserDefaults.standard.dictionary(forKey: "styleThumbnailValues") as? [String: String]
    ?? [Style.subject: "A woman with a red umbrella walking down a rainy city street"]
  {
    didSet { remember(thumbnailValues, "styleThumbnailValues") }
  }

  /// Every tag the styles use, `SUBJECT` first, then in the order they first appear.
  var allTags: [String] {
    var seen: Set = [Style.subject]
    return [Style.subject] + styles.flatMap(\.tags).filter { seen.insert($0).inserted }
  }
  // The Styles screen's filter, category, selection, layout and scroll position, kept while you visit
  // other screens and across launches.
  var screenSearch = UserDefaults.standard.string(forKey: "stylesSearch") ?? "" {
    didSet { remember(screenSearch, "stylesSearch") }
  }
  var screenCategory = UserDefaults.standard.string(forKey: "stylesCategory") {
    didSet { remember(screenCategory, "stylesCategory") }
  }
  var screenSelection = Set((UserDefaults.standard.stringArray(forKey: "stylesSelection") ?? []).compactMap(UUID.init(uuidString:))) {
    didSet { remember(screenSelection.map(\.uuidString), "stylesSelection") }
  }
  /// Thumbnails in a grid rather than rows with the start of each template.
  var screenGrid = UserDefaults.standard.bool(forKey: "stylesGrid") {
    didSet { remember(screenGrid, "stylesGrid") }
  }
  /// The style at the top of the list.
  var screenScrolledTo = UserDefaults.standard.string(forKey: "stylesScrolledTo").flatMap(UUID.init(uuidString:)) {
    didSet { remember(screenScrolledTo?.uuidString, "stylesScrolledTo") }
  }

  private func remember(_ value: Any?, _ key: String) {
    if isUserData { UserDefaults.standard.set(value, forKey: key) }
  }

  /// The thumbnails being made: how many are done (and failed) of how many, and the style running.
  var thumbnailRun: (done: Int, total: Int, failed: Int, current: String)?
  @ObservationIgnored var thumbnailTask: Task<Void, Never>?
  /// The style whose thumbnail is shown full size (`ThumbnailViewer`), from the list or the editor.
  var viewingThumbnail: UUID?
  /// Tells the user a change wasn't saved. Set by `CreateModel`, whose status bar shows it.
  @ObservationIgnored var reportFailure: ((String) -> Void)?
  /// Off for scripted runs: they read the user's styles but don't change them.
  @ObservationIgnored let persists: Bool

  /// The folder holding the libraries.
  @ObservationIgnored let root: URL
  /// Saving to the user's own folder, not a test's: settings are remembered, and a deleted library
  /// goes to the Trash.
  @ObservationIgnored private let isUserData: Bool

  /// The library whose files are `Styles.json` and `StyleThumbnails` directly in `root`.
  nonisolated static let mainLibraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

  private var libraryListFile: URL { root.appendingPathComponent("StyleLibraries.json") }

  private func folder(ofLibrary id: UUID) -> URL {
    id == Self.mainLibraryID ? root : root.appendingPathComponent("StyleLibraries/\(id.uuidString)", isDirectory: true)
  }

  private func stylesFile(ofLibrary id: UUID) -> URL {
    folder(ofLibrary: id).appendingPathComponent("Styles.json")
  }

  func thumbnailsFolder(ofLibrary id: UUID) -> URL {
    folder(ofLibrary: id).appendingPathComponent("StyleThumbnails", isDirectory: true)
  }

  /// `root` is for tests; the default is Application Support.
  init(persists: Bool = true, root: URL? = nil) {
    self.persists = persists
    self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier", isDirectory: true)
    isUserData = persists && root == nil
    let listed = (try? Data(contentsOf: libraryListFile)).flatMap { try? JSONDecoder().decode([StyleCollection].self, from: $0) }
    var loaded = listed.flatMap { $0.isEmpty ? nil : $0 } ?? [StyleCollection(id: Self.mainLibraryID, name: "My Styles")]
    for index in loaded.indices {
      let id = loaded[index].id
      guard let data = try? Data(contentsOf: stylesFile(ofLibrary: id)), let saved = try? JSONDecoder().decode([Style].self, from: data) else { continue }
      loaded[index].styles = saved
      // Only with styles read: a file that didn't decode says nothing about which thumbnails are used.
      if persists, !saved.isEmpty {
        Self.removeOrphanedThumbnails(in: thumbnailsFolder(ofLibrary: id), keeping: Set(saved.map(\.id)))
      }
    }
    libraries = loaded
    let remembered = isUserData ? UserDefaults.standard.string(forKey: "stylesLibrary").flatMap(UUID.init(uuidString:)) : nil
    currentLibraryID = loaded.first { $0.id == remembered }?.id ?? loaded[0].id
    if persists, listed == nil { writeLibraryList() }
  }

  var currentLibrary: StyleCollection {
    libraries.first { $0.id == currentLibraryID } ?? libraries[0]
  }

  /// The current library's styles.
  var styles: [Style] { currentLibrary.styles }

  /// Every library's styles, the current library's first.
  var allStyles: [Style] {
    currentLibrary.styles + libraries.filter { $0.id != currentLibraryID }.flatMap(\.styles)
  }

  /// Looks in every library: a style stays usable on Create whichever one is on screen.
  func style(id: UUID?) -> Style? {
    guard let id else { return nil }
    for library in libraries {
      if let style = library.styles.first(where: { $0.id == id }) { return style }
    }
    return nil
  }

  func library(ofStyle id: UUID) -> StyleCollection? {
    libraries.first { $0.styles.contains { $0.id == id } }
  }

  /// The current library's categories.
  var categories: [String] { currentLibrary.categories }

  /// Shows another library on the Styles screen, which starts afresh there.
  func selectLibrary(_ id: UUID) {
    guard id != currentLibraryID, libraries.contains(where: { $0.id == id }) else { return }
    currentLibraryID = id
    // A filter left over from the last library would show this one as empty.
    screenSearch = ""
    screenSelection = []
    screenCategory = nil
    screenScrolledTo = nil
    viewingThumbnail = nil
  }

  /// `name`, numbered if another library has it.
  private func uniqueLibraryName(_ name: String, excluding id: UUID? = nil) -> String {
    let taken = libraries.filter { $0.id != id }.map { $0.name.lowercased() }
    var candidate = name
    var number = 2
    while taken.contains(candidate.lowercased()) {
      candidate = "\(name) \(number)"
      number += 1
    }
    return candidate
  }

  /// Adds an empty library at the end. Returns its id.
  @discardableResult
  func createLibrary(named name: String) -> UUID {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let library = StyleCollection(name: uniqueLibraryName(trimmed.isEmpty ? "New Library" : trimmed))
    libraries.append(library)
    writeLibraryList()
    return library.id
  }

  func renameLibrary(_ id: UUID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = libraries.firstIndex(where: { $0.id == id }) else { return }
    libraries[index].name = uniqueLibraryName(trimmed, excluding: id)
    writeLibraryList()
  }

  /// Removes a library, its styles and their thumbnails. The last one stays: there's always one.
  func deleteLibrary(_ id: UUID) {
    guard libraries.count > 1, let index = libraries.firstIndex(where: { $0.id == id }) else { return }
    if id == currentLibraryID, let next = libraries.first(where: { $0.id != id }) { selectLibrary(next.id) }
    for style in libraries[index].styles { thumbnails[style.id] = nil }
    libraries.remove(at: index)
    writeLibraryList()
    guard persists else { return }
    let fileManager = FileManager.default
    for url in [stylesFile(ofLibrary: id), thumbnailsFolder(ofLibrary: id)] where fileManager.fileExists(atPath: url.path) {
      // The Trash isn't there on every volume or on iPad.
      if isUserData, (try? fileManager.trashItem(at: url, resultingItemURL: nil)) != nil { continue }
      try? fileManager.removeItem(at: url)
    }
    if id != Self.mainLibraryID { try? fileManager.removeItem(at: folder(ofLibrary: id)) }
  }

  /// Moves styles to another library with their thumbnails. They keep their ids, so a style selected
  /// on Create stays selected.
  func move(_ ids: Set<UUID>, toLibrary target: UUID) {
    guard let targetIndex = libraries.firstIndex(where: { $0.id == target }) else { return }
    var sources: [UUID] = []
    for index in libraries.indices where index != targetIndex {
      let moving = libraries[index].styles.filter { ids.contains($0.id) }
      guard !moving.isEmpty else { continue }
      for style in moving {
        moveThumbnailFiles(style.id, from: libraries[index].id, to: target)
        insert(style, inLibraryAt: targetIndex)
      }
      libraries[index].styles.removeAll { ids.contains($0.id) }
      sources.append(libraries[index].id)
    }
    guard !sources.isEmpty else { return }
    // The target first: a failure between the two leaves a style in both, not in neither.
    write(target)
    sources.forEach(write)
  }

  /// Copies styles to another library with their thumbnails, under new ids.
  func copy(_ ids: Set<UUID>, toLibrary target: UUID) {
    guard let targetIndex = libraries.firstIndex(where: { $0.id == target }) else { return }
    for var style in allStyles where ids.contains(style.id) {
      let original = style.id
      style.id = UUID()
      copyThumbnailFiles(original, to: style.id, inLibrary: target)
      insert(style, inLibraryAt: targetIndex)
    }
    write(target)
  }

  /// After the last style of its category, so categories stay together.
  private func insert(_ style: Style, inLibraryAt library: Int) {
    let styles = libraries[library].styles
    let index = styles.lastIndex { $0.category == style.category && $0.subcategory == style.subcategory }
      ?? styles.lastIndex { $0.category == style.category }
    libraries[library].styles.insert(style, at: index.map { $0 + 1 } ?? styles.count)
  }

  /// Adds a style to the current library, or replaces the one with its id in whichever library has it.
  func save(_ style: Style) {
    for index in libraries.indices {
      if let found = libraries[index].styles.firstIndex(where: { $0.id == style.id }) {
        libraries[index].styles[found] = style
        write(libraries[index].id)
        return
      }
    }
    guard let index = libraries.firstIndex(where: { $0.id == currentLibraryID }) else { return }
    insert(style, inLibraryAt: index)
    write(currentLibraryID)
  }

  func delete(_ ids: Set<UUID>) {
    // Before the styles go: a thumbnail's folder is found from its style's library.
    for id in ids { setThumbnail(nil, for: id) }
    for index in libraries.indices where libraries[index].styles.contains(where: { ids.contains($0.id) }) {
      libraries[index].styles.removeAll { ids.contains($0.id) }
      write(libraries[index].id)
    }
  }

  /// Adds the styles in a style file to a library, by default the current one. One with the same
  /// category and name as a style already in that library replaces it, keeping its id (and so the
  /// selection on Create). Returns each imported style's id here, in order.
  @discardableResult
  func importStyles(_ imported: [Style], into library: UUID? = nil) -> (added: Int, replaced: Int, ids: [UUID]) {
    let target = library ?? currentLibraryID
    guard let index = libraries.firstIndex(where: { $0.id == target }) else { return (0, 0, []) }
    var added = 0
    var replaced = 0
    var ids: [UUID] = []
    for var style in imported {
      if let existing = libraries[index].styles.first(where: {
        $0.category.caseInsensitiveCompare(style.category) == .orderedSame
          && $0.name.caseInsensitiveCompare(style.name) == .orderedSame
      }) {
        style.id = existing.id
        replaced += 1
      } else {
        added += 1
      }
      ids.append(style.id)
      if let found = libraries[index].styles.firstIndex(where: { $0.id == style.id }) {
        libraries[index].styles[found] = style
      } else {
        libraries[index].styles.append(style)
      }
    }
    write(target)
    return (added, replaced, ids)
  }

  private func writeLibraryList() {
    guard persists else { return }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(libraries).write(to: libraryListFile, options: .atomic)
    } catch {
      Log.styles.error("Couldn't save the style libraries: \(error.localizedDescription, privacy: .public)")
      reportFailure?("Couldn't save your style libraries: \(error.localizedDescription)")
    }
  }

  private func write(_ id: UUID) {
    guard persists, let library = libraries.first(where: { $0.id == id }) else { return }
    do {
      try FileManager.default.createDirectory(at: folder(ofLibrary: id), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(library.styles).write(to: stylesFile(ofLibrary: id), options: .atomic)
    } catch {
      Log.styles.error("Couldn't save styles: \(error.localizedDescription, privacy: .public)")
      reportFailure?("Couldn't save your styles: \(error.localizedDescription)")
    }
  }
}
