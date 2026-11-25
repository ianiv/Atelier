#if os(macOS)
import Foundation

/// The Skills screen's check that a skill's text names tools Atelier has: a skill that tells an
/// agent to call `generte` would fail only when an agent tries it. A heuristic, so it only
/// informs: it looks at words written like tool calls (`snake_case` in backticks, before a
/// parenthesis, or after "call", "use" or "with"), skips fenced code, and knows every tool name
/// and every argument name in their schemas. A skill lists words that look like tools but
/// aren't in its frontmatter: `metadata: { atelier-ignore-tools: "a_b c_d" }`.
nonisolated enum SkillToolCheck {
  static let ignoreKey = "atelier-ignore-tools"

  /// The tool-like words in `texts` (sorted, once each), and those of them Atelier doesn't know.
  static func scan(_ texts: [String], known: Set<String>, ignored: Set<String> = []) -> (found: [String], unknown: [String]) {
    var found = Set<String>()
    for text in texts {
      var fence: String?
      for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let open = fence {
          if trimmed.hasPrefix(open) { fence = nil }
          continue
        }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
          fence = String(trimmed.prefix(3))
          continue
        }
        found.formUnion(candidates(in: line))
      }
    }
    let sorted = found.sorted()
    return (sorted, sorted.filter { !known.contains($0) && !ignored.contains($0) })
  }

  private static let callWords: Set<String> = ["call", "calls", "calling", "use", "uses", "using", "with"]

  /// The words of one line written like a tool's name.
  static func candidates(in line: String) -> Set<String> {
    var result = Set<String>()
    // `name` or `name(...)` in backticks.
    for span in line.split(separator: "`", omittingEmptySubsequences: false).enumerated() where span.offset % 2 == 1 {
      let word = span.element.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      let rest = span.element.dropFirst(word.count)
      if rest.isEmpty || rest.hasPrefix("(") { result.formUnion(tool(String(word))) }
    }
    // Words, with what comes right after each.
    var words: [(word: String, next: Character?)] = []
    var current = ""
    for character in line {
      if character.isLetter || character.isNumber || character == "_" {
        current.append(character)
      } else {
        if !current.isEmpty { words.append((current, character)) }
        current = ""
      }
    }
    if !current.isEmpty { words.append((current, nil)) }
    for (index, entry) in words.enumerated() {
      let afterCallWord = index > 0 && callWords.contains(words[index - 1].word.lowercased())
      if entry.next == "(" || afterCallWord { result.formUnion(tool(entry.word)) }
    }
    return result
  }

  private static func tool(_ word: String) -> Set<String> {
    word.wholeMatch(of: /[a-z][a-z0-9]*(_[a-z0-9]+)+/) != nil ? [word] : []
  }

  /// Atelier's tool names and every property name in their input schemas, at any depth.
  static func knownNames(_ definitions: [[String: Any]]) -> Set<String> {
    var names = Set<String>()
    func properties(of schema: Any?) {
      guard let schema = schema as? [String: Any] else { return }
      if let props = schema["properties"] as? [String: Any] {
        for (key, value) in props {
          names.insert(key)
          properties(of: value)
        }
      }
      properties(of: schema["items"])
    }
    for definition in definitions {
      if let name = definition["name"] as? String { names.insert(name) }
      properties(of: definition["inputSchema"])
    }
    return names
  }

  /// The words a skill's frontmatter says aren't tools: `metadata.atelier-ignore-tools`, separated
  /// by spaces or commas.
  static func ignored(frontmatter: [String: Any]?) -> Set<String> {
    guard let value = (frontmatter?["metadata"] as? [String: Any])?[ignoreKey] as? String else { return [] }
    return Set(value.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).map(String.init))
  }
}
#endif
