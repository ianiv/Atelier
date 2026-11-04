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
        subcategory = style.subcategory
        if !style.subcategory.isEmpty { out += "\n## \(style.subcategory)\n" }
      }
      out += "\n### \(style.name)\nTEMPLATE:\n\(style.template)\n"
      if !style.negative.isEmpty { out += "NEGATIVE:\n\(style.negative)\n" }
      if !style.notes.isEmpty { out += "NOTES:\n\(style.notes)\n" }
    }
    return out
  }

  private static func heading(_ line: String) -> (level: Int, title: String)? {
    let hashes = line.prefix { $0 == "#" }.count
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

/// The user's styles, kept in one JSON file in Application Support.
@MainActor
@Observable
final class StyleStore {
  private(set) var styles: [Style] = []
  /// Thumbnails read so far, by style (StyleThumbnails.swift); nil marks one with none.
  var thumbnails: [UUID: CGImage?] = [:]
  /// What each tag takes when making thumbnails, by tag (`SUBJECT` included).
  var thumbnailValues = UserDefaults.standard.dictionary(forKey: "styleThumbnailValues") as? [String: String]
    ?? [Style.subject: "A woman with a red umbrella walking down a rainy city street"]
  {
    didSet { if persists { UserDefaults.standard.set(thumbnailValues, forKey: "styleThumbnailValues") } }
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
    if persists { UserDefaults.standard.set(value, forKey: key) }
  }

  /// The thumbnails being made: how many are done (and failed) of how many, and the style running.
  var thumbnailRun: (done: Int, total: Int, failed: Int, current: String)?
  @ObservationIgnored var thumbnailTask: Task<Void, Never>?
  /// The style whose thumbnail is shown full size (`ThumbnailViewer`), from the list or the editor.
  var viewingThumbnail: UUID?
  /// Off for scripted runs: they read the user's styles but don't change them.
  @ObservationIgnored let persists: Bool

  static var file: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier/Styles.json")
  }

  init(persists: Bool = true) {
    self.persists = persists
    guard let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([Style].self, from: data) else { return }
    styles = saved
    // Only with styles read: a file that didn't decode says nothing about which thumbnails are used.
    if persists, !saved.isEmpty {
      Self.removeOrphanedThumbnails(in: Self.thumbnailsDirectory, keeping: Set(saved.map(\.id)))
    }
  }

  func style(id: UUID?) -> Style? {
    id.flatMap { id in styles.first { $0.id == id } }
  }

  /// Categories in the order their first style appears.
  var categories: [String] {
    var seen = Set<String>()
    return styles.map(\.category).filter { seen.insert($0).inserted }
  }

  /// Adds a style, or replaces the one with its id.
  func save(_ style: Style) {
    if let index = styles.firstIndex(where: { $0.id == style.id }) {
      styles[index] = style
    } else {
      // After the last style of its category, so categories stay together.
      let index = styles.lastIndex { $0.category == style.category && $0.subcategory == style.subcategory }
        ?? styles.lastIndex { $0.category == style.category }
      styles.insert(style, at: index.map { $0 + 1 } ?? styles.count)
    }
    write()
  }

  func delete(_ ids: Set<UUID>) {
    styles.removeAll { ids.contains($0.id) }
    for id in ids { setThumbnail(nil, for: id) }
    write()
  }

  /// Adds the styles in a style file. One with the same category and name as a style already
  /// here replaces it, keeping its id (and so the selection on Create). Returns each imported
  /// style's id here, in order.
  @discardableResult
  func importStyles(_ imported: [Style]) -> (added: Int, replaced: Int, ids: [UUID]) {
    var added = 0
    var replaced = 0
    var ids: [UUID] = []
    for var style in imported {
      if let existing = styles.first(where: {
        $0.category.caseInsensitiveCompare(style.category) == .orderedSame
          && $0.name.caseInsensitiveCompare(style.name) == .orderedSame
      }) {
        style.id = existing.id
        replaced += 1
      } else {
        added += 1
      }
      ids.append(style.id)
      if let index = styles.firstIndex(where: { $0.id == style.id }) {
        styles[index] = style
      } else {
        styles.append(style)
      }
    }
    write()
    return (added, replaced, ids)
  }

  private func write() {
    guard persists else { return }
    do {
      try FileManager.default.createDirectory(
        at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(styles).write(to: Self.file, options: .atomic)
    } catch {
      print("Couldn't save styles: \(error)")
    }
  }
}
