import Foundation
import Observation

/// A prompt style: a template the prompt is written into at Generate. `{{SUBJECT}}` takes the
/// prompt and `{{SETTING}}` the Setting field beside the style picker; the format is in
/// docs/styles.md.
struct Style: Codable, Identifiable, Hashable {
  var id = UUID()
  var name: String
  var category = ""
  var subcategory = ""
  var template: String
  /// Added to the negative prompt.
  var negative = ""
  var notes = ""

  static let subject = "{{SUBJECT}}"
  static let setting = "{{SETTING}}"

  var takesSetting: Bool { template.contains(Self.setting) }

  /// The prompt and negative prompt a run sends: the prompt in the `{{SUBJECT}}` slot (before the
  /// template when it has none), the setting in `{{SETTING}}`. An empty slot is dropped, and any
  /// other `{{…}}` placeholder is removed.
  func apply(prompt: String, negativePrompt: String, setting: String) -> (prompt: String, negativePrompt: String) {
    let subject = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    var text = template
    if !text.contains(Self.subject) { text = Self.subject + " " + text }
    text = text.replacingOccurrences(of: Self.subject, with: subject)
    text = text.replacingOccurrences(of: Self.setting, with: setting.trimmingCharacters(in: .whitespacesAndNewlines))
    text = text.replacingOccurrences(of: #"\{\{[A-Za-z_]+\}\}"#, with: "", options: .regularExpression)
    // Close the gap an empty slot leaves, without touching line breaks.
    text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    let negatives = [negativePrompt, negative]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return (text.trimmingCharacters(in: .whitespacesAndNewlines), negatives.joined(separator: ", "))
  }

  /// The reverse of `apply`: the subject, setting and the user's own negative prompt of a prompt
  /// this style wrote, or nil when it didn't write it. Lets a reused image bring its style back
  /// instead of the style wrapping its already-styled prompt again.
  func match(prompt: String, negativePrompt: String) -> (prompt: String, negativePrompt: String, setting: String)? {
    var template = template
    if !template.contains(Self.subject) { template = Self.subject + " " + template }
    // Literal text with any run of spaces matching any run (an empty slot closes a gap), and the
    // slots as groups.
    var pattern = "^\\s*"
    var slots: [String] = []
    let placeholder = try! NSRegularExpression(pattern: #"\{\{[A-Za-z_]+\}\}"#)
    let ns = template as NSString
    var location = 0
    func literal(_ text: String) -> String {
      text.split(omittingEmptySubsequences: false) { $0 == " " || $0 == "\t" }
        .map { NSRegularExpression.escapedPattern(for: String($0)) }
        .joined(separator: "[ \\t]*")
    }
    for found in placeholder.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
      pattern += literal(ns.substring(with: NSRange(location: location, length: found.range.location - location)))
      let slot = ns.substring(with: found.range)
      if slot == Self.subject || slot == Self.setting {
        slots.append(slot)
        pattern += "(.*?)"
      } else {
        pattern += "[ \\t]*"
      }
      location = found.range.location + found.range.length
    }
    pattern += literal(ns.substring(from: location)) + "\\s*$"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
          let found = regex.firstMatch(in: prompt, range: NSRange(location: 0, length: (prompt as NSString).length))
    else { return nil }
    var subject = ""
    var setting = ""
    for (index, slot) in slots.enumerated() {
      let value = (prompt as NSString).substring(with: found.range(at: index + 1))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if slot == Self.subject { subject = value } else { setting = value }
    }
    guard !subject.isEmpty else { return nil }
    var userNegative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let styleNegative = negative.trimmingCharacters(in: .whitespacesAndNewlines)
    if !styleNegative.isEmpty {
      if userNegative == styleNegative {
        userNegative = ""
      } else if userNegative.hasSuffix(", " + styleNegative) {
        userNegative = String(userNegative.dropLast(styleNegative.count + 2))
      }
    }
    return (subject, userNegative, setting)
  }
}

/// Reads and writes style files: Markdown with a `#` heading per category, `##` per subcategory
/// and `###` per style, whose `TEMPLATE:`, `NEGATIVE:` and `NOTES:` sections follow (docs/styles.md).
enum StyleFile {
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
  /// Off for scripted runs: they read the user's styles but don't change them.
  @ObservationIgnored private let persists: Bool

  static var file: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier/Styles.json")
  }

  init(persists: Bool = true) {
    self.persists = persists
    guard let data = try? Data(contentsOf: Self.file) else { return }
    styles = (try? JSONDecoder().decode([Style].self, from: data)) ?? []
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
    write()
  }

  /// Adds the styles in a style file. One with the same category and name as a style already
  /// here replaces it, keeping its id (and so the selection on Create).
  func importStyles(_ imported: [Style]) -> (added: Int, replaced: Int) {
    var added = 0
    var replaced = 0
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
      if let index = styles.firstIndex(where: { $0.id == style.id }) {
        styles[index] = style
      } else {
        styles.append(style)
      }
    }
    write()
    return (added, replaced)
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
