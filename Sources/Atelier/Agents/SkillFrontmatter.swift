#if os(macOS)
import Foundation

/// A SKILL.md's YAML frontmatter: split from the body, parsed, checked against the Agent Skills
/// specification's rules, and written back.
///
/// The parser is Atelier's own, a strict subset of YAML 1.2 with the core schema: block mappings
/// and sequences to any depth, flow sequences of scalars, plain, single- and double-quoted
/// scalars (double-quoted with YAML's escapes), literal and folded block scalars with chomping
/// indicators, and comments. `skills/list` hands the parsed frontmatter to every client as JSON
/// "verbatim" (Skills: Frontmatter), so what isn't in the subset (anchors, aliases, tags, flow
/// mappings, complex keys, duplicate keys, tab indentation, several documents) is refused with
/// its line rather than guessed at, and non-finite numbers, which JSON can't carry, are refused
/// too.
nonisolated enum SkillFrontmatter {
  struct ParseError: LocalizedError, Equatable {
    /// 1-based, counted in the text that was parsed (SKILL.md's own lines for `parse(skillFile:)`).
    var line: Int
    var message: String
    var errorDescription: String? { "Line \(line): \(message)" }
  }

  /// A rule from the Agent Skills specification the frontmatter breaks.
  struct Issue: Equatable, CustomStringConvertible {
    var field: String
    var message: String
    var description: String { message }
  }

  static let maxNameLength = 64
  static let maxDescriptionLength = 1024
  static let maxCompatibilityLength = 500

  // MARK: - Splitting

  /// The YAML between SKILL.md's opening `---` line and the next `---` line, and everything after.
  /// `parse(skillFile:)` numbers errors by SKILL.md's lines (the YAML starts on line 2).
  static func split(_ data: Data) throws -> (yaml: String, body: String) {
    guard var text = String(data: data, encoding: .utf8) else {
      throw ParseError(line: 1, message: "SKILL.md isn't UTF-8 text.")
    }
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    return try split(text)
  }

  static func split(_ text: String) throws -> (yaml: String, body: String) {
    var lines = text.components(separatedBy: "\n")
    guard let first = lines.first, isDelimiter(first) else {
      throw ParseError(line: 1, message: "SKILL.md must start with a --- line, then the frontmatter.")
    }
    lines.removeFirst()
    guard let close = lines.firstIndex(where: isDelimiter) else {
      throw ParseError(line: lines.count + 1, message: "The frontmatter has no closing --- line.")
    }
    let yaml = lines[..<close].map { $0 + "\n" }.joined()
    let body = lines[(close + 1)...].joined(separator: "\n")
    return (yaml, body)
  }

  private static func isDelimiter(_ line: String) -> Bool {
    line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")) == "---" && line.hasPrefix("---")
  }

  /// SKILL.md's frontmatter, with errors numbered by SKILL.md's lines.
  static func parse(skillFile data: Data) throws -> [String: Any] {
    let (yaml, _) = try split(data)
    return try parse(yaml, lineOffset: 1)
  }

  // MARK: - Parsing

  /// The frontmatter as JSON-ready values: String, Bool, NSNull, Int, Double, [Any], [String: Any].
  static func parse(_ yaml: String, lineOffset: Int = 0) throws -> [String: Any] {
    var parser = Parser(text: yaml, lineOffset: lineOffset)
    return try parser.document()
  }

  private struct Parser {
    var lines: [String]
    let lineOffset: Int
    var index = 0

    init(text: String, lineOffset: Int) {
      var lines = text.components(separatedBy: "\n")
      if lines.last == "" { lines.removeLast() }
      self.lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
      self.lineOffset = lineOffset
    }

    func error(_ message: String, at line: Int? = nil) -> ParseError {
      ParseError(line: (line ?? index) + 1 + lineOffset, message: message)
    }

    /// Spaces before the first other character; a tab there is refused, as YAML does.
    func indentation(of line: String) throws -> Int {
      var count = 0
      for character in line {
        if character == " " {
          count += 1
        } else if character == "\t" {
          // A tab after the indentation, in content, is fine; in it, it isn't.
          if line.drop(while: { $0 == " " || $0 == "\t" }).isEmpty { return count }
          throw error("Tabs can't indent YAML; use spaces.")
        } else {
          break
        }
      }
      return count
    }

    static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }
    static func isComment(_ line: String) -> Bool { line.drop(while: { $0 == " " || $0 == "\t" }).first == "#" }

    /// Moves past blank and comment-only lines.
    mutating func skipEmpty() {
      while index < lines.count, Self.isBlank(lines[index]) || Self.isComment(lines[index]) { index += 1 }
    }

    mutating func document() throws -> [String: Any] {
      skipEmpty()
      guard index < lines.count else { return [:] }
      let line = lines[index]
      if line.hasPrefix("%") { throw error("YAML directives aren't supported.") }
      let start = try indentation(of: line)
      guard isMappingEntry(content(line)) else { throw error("The frontmatter must be a mapping of fields (key: value).") }
      let value = try mapping(indent: start)
      skipEmpty()
      if index < lines.count {
        let rest = lines[index]
        if rest.hasPrefix("---") || rest.hasPrefix("...") { throw error("Only one YAML document is allowed.") }
        throw error("Unexpected indentation.")
      }
      return value
    }

    func content(_ line: String) -> Substring { line.drop(while: { $0 == " " }) }

    func isSequenceEntry(_ content: Substring) -> Bool { content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t") }

    func isMappingEntry(_ content: Substring) -> Bool {
      guard !isSequenceEntry(content) else { return false }
      return (try? key(in: content)) != nil
    }

    /// A block node whose first line is the current one, at `indent`.
    mutating func node(indent: Int) throws -> Any {
      let text = content(lines[index])
      if isSequenceEntry(text) { return try sequence(indent: indent) }
      if isMappingEntry(text) { return try mapping(indent: indent) }
      // A scalar on lines of its own below its key.
      let first = index
      index += 1
      return try inlineValue(String(text), parentIndent: indent - 1, line: first)
    }

    /// `key: value` lines at exactly `indent`.
    mutating func mapping(indent: Int) throws -> [String: Any] {
      var result: [String: Any] = [:]
      while true {
        skipEmpty()
        guard index < lines.count else { break }
        let line = lines[index]
        let current = try indentation(of: line)
        if current < indent { break }
        if current > indent { throw error("Unexpected indentation.") }
        let text = content(line)
        if indent == 0, text.hasPrefix("---") || text.hasPrefix("...") { break }
        if isSequenceEntry(text) { break }
        let (key, rest) = try key(in: text)
        guard result[key] == nil else { throw error("“\(key)” appears twice.") }
        let keyLine = index
        index += 1
        let value = stripComment(rest)
        if value.isEmpty {
          result[key] = try blockValue(parentIndent: indent)
        } else {
          result[key] = try inlineValue(rest, parentIndent: indent, line: keyLine)
        }
      }
      return result
    }

    /// The value of a key (or `-`) with nothing after it on its line: a node indented further on
    /// the next lines, a sequence at the key's own indentation, or null.
    mutating func blockValue(parentIndent: Int, allowsSameIndentSequence: Bool = true) throws -> Any {
      skipEmpty()
      guard index < lines.count else { return NSNull() }
      let next = try indentation(of: lines[index])
      if next > parentIndent { return try node(indent: next) }
      if allowsSameIndentSequence, next == parentIndent, isSequenceEntry(content(lines[index])) {
        return try sequence(indent: next)
      }
      return NSNull()
    }

    /// `- item` lines at exactly `indent`.
    mutating func sequence(indent: Int) throws -> [Any] {
      var result: [Any] = []
      while true {
        skipEmpty()
        guard index < lines.count else { break }
        let line = lines[index]
        let current = try indentation(of: line)
        if current < indent { break }
        if current > indent { throw error("Unexpected indentation.") }
        let text = content(line)
        guard isSequenceEntry(text) else { break }
        let after = text.dropFirst()
        let gap = after.prefix(while: { $0 == " " }).count
        if after.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") {
          throw error("Tabs can't indent YAML; use spaces.")
        }
        let rest = after.dropFirst(gap)
        if stripComment(String(rest)).isEmpty {
          index += 1
          result.append(try blockValue(parentIndent: indent, allowsSameIndentSequence: false))
          continue
        }
        let column = indent + 1 + gap
        if isSequenceEntry(rest) || isMappingEntry(rest) {
          // "- key: value" or "- - item": the rest is a node at its own column.
          lines[index] = String(repeating: " ", count: column) + rest
          result.append(try node(indent: column))
        } else {
          let itemLine = index
          index += 1
          result.append(try inlineValue(String(rest), parentIndent: indent, line: itemLine))
        }
      }
      return result
    }

    /// A key and what follows its colon. Plain keys end at the first ": " (or a colon ending the
    /// line); quoted keys at their closing quote.
    func key(in text: Substring) throws -> (String, String) {
      guard let first = text.first else { throw error("Expected key: value.") }
      if first == "?" { throw error("Complex keys (?) aren't supported.") }
      if "&*!".contains(first) { throw error("Anchors, aliases and tags aren't supported.") }
      if "{[".contains(first) { throw error("Flow mappings and flow keys aren't supported.") }
      if first == "\"" || first == "'" {
        guard let (key, after) = try quotedKey(text) else { throw error("Expected key: value.") }
        let trimmed = after.drop(while: { $0 == " " })
        guard trimmed.first == ":" else { throw error("Expected a colon after the key.") }
        let rest = trimmed.dropFirst()
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { throw error("Expected a space after the colon.") }
        return (key, String(rest.drop(while: { $0 == " " || $0 == "\t" })))
      }
      var previous: Character = " "
      for position in text.indices {
        let character = text[position]
        if character == "#", previous == " " { break }
        if character == ":" {
          let next = text.index(after: position)
          if next == text.endIndex || text[next] == " " || text[next] == "\t" {
            let key = text[..<position].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw error("A key can't be empty.") }
            return (key, String(text[next...].drop(while: { $0 == " " || $0 == "\t" })))
          }
        }
        previous = character
      }
      throw error("Expected key: value.")
    }

    func quotedKey(_ text: Substring) throws -> (String, Substring)? {
      let quote = text.first!
      var result = ""
      var position = text.index(after: text.startIndex)
      while position < text.endIndex {
        let character = text[position]
        if character == quote {
          let next = text.index(after: position)
          if quote == "'", next < text.endIndex, text[next] == "'" {
            result.append("'")
            position = text.index(after: next)
            continue
          }
          return (result, text[next...])
        }
        if quote == "\"", character == "\\" {
          let next = text.index(after: position)
          guard next < text.endIndex else { throw error("A key can't span lines.") }
          var scalars = String(text[next...])
          let (escaped, used) = try escape(&scalars)
          result += escaped
          position = text.index(next, offsetBy: used)
          continue
        }
        result.append(character)
        position = text.index(after: position)
      }
      throw error("A key can't span lines.")
    }

    /// The text before a comment: `#` after a space, outside quotes (the caller checks quotes).
    func stripComment(_ text: String) -> String {
      var previous: Character = " "
      for position in text.indices {
        if text[position] == "#", previous == " " || previous == "\t" {
          return text[..<position].trimmingCharacters(in: .whitespaces)
        }
        previous = text[position]
      }
      return text.trimmingCharacters(in: .whitespaces)
    }

    /// A value starting on its key's (or dash's) line: block scalar, flow sequence, quoted or
    /// plain scalar. `line` is that line; the parser is already past it.
    mutating func inlineValue(_ raw: String, parentIndent: Int, line: Int) throws -> Any {
      guard let first = raw.first else { return NSNull() }
      switch first {
      case "&", "*": throw error("Anchors and aliases aren't supported.", at: line)
      case "!": throw error("Tags aren't supported.", at: line)
      case "{": throw error("Flow mappings aren't supported; use indented key: value lines.", at: line)
      case "@", "`": throw error("A plain value can't start with \(first); quote it.", at: line)
      case "|", ">": return try blockScalar(header: raw, literal: first == "|", parentIndent: parentIndent, line: line)
      case "[": return try flowSequence(raw, line: line)
      case "\"", "'": return try quotedScalar(raw, line: line)
      case "%": throw error("A plain value can't start with %; quote it.", at: line)
      case "?":
        if raw.count == 1 || raw.dropFirst().first == " " { throw error("Complex keys (?) aren't supported.", at: line) }
      default: break
      }
      return try plainScalar(raw, parentIndent: parentIndent, line: line)
    }

    // MARK: Plain scalars

    mutating func plainScalar(_ raw: String, parentIndent: Int, line: Int) throws -> Any {
      var text = stripComment(raw)
      try checkPlain(Substring(text), line: line)
      // Continuation lines, more indented than the key, fold into one line; an empty line makes
      // a line break. A comment ends the value.
      var breaks = 0
      var continued = false
      let endsInComment = text.count != raw.trimmingCharacters(in: .whitespaces).count
      while !endsInComment, index < lines.count {
        let next = lines[index]
        if Self.isBlank(next) {
          breaks += 1
          index += 1
          continue
        }
        let nextIndent = try indentation(of: next)
        guard nextIndent > parentIndent, !Self.isComment(next) else { break }
        let piece = content(next)
        let stripped = stripComment(String(piece))
        try checkPlain(Substring(stripped), line: index, continuation: true)
        text += breaks == 0 ? " " + stripped : String(repeating: "\n", count: breaks) + stripped
        breaks = 0
        continued = true
        index += 1
        if stripped.count != piece.trimmingCharacters(in: .whitespaces).count { break }
      }
      return continued ? text : try Self.resolve(text, error: { error($0, at: line) })
    }

    func checkPlain(_ text: Substring, line: Int, continuation: Bool = false) throws {
      if text.contains(": ") || text.hasSuffix(":") {
        throw error(continuation ? "A continued value can't contain “: ”; quote the value." : "A value can't contain “: ”; quote it.", at: line)
      }
      if continuation, let first = text.first, "&*!|>{[\"'%@`".contains(first) || text.hasPrefix("- ") {
        throw error("A continued value can't start with \(first); quote the value.", at: line)
      }
    }

    /// The core schema's reading of a plain scalar: null, a boolean, an integer, a float, or the
    /// text itself. Only the exact spellings count (`yes` stays a string, as in YAML 1.2).
    static func resolve(_ text: String, error: (String) -> ParseError) throws -> Any {
      switch text {
      case "", "~", "null", "Null", "NULL": return NSNull()
      case "true", "True", "TRUE": return true
      case "false", "False", "FALSE": return false
      case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF", ".nan", ".NaN", ".NAN":
        throw error("Infinite and NaN numbers can't be carried as JSON; quote the value.")
      default: break
      }
      if text.wholeMatch(of: /[-+]?[0-9]+/) != nil {
        guard let value = Int(text.hasPrefix("+") ? String(text.dropFirst()) : text) else {
          throw error("The number \(text) is out of range; quote it.")
        }
        return value
      }
      if text.wholeMatch(of: /0o[0-7]+/) != nil {
        guard let value = Int(text.dropFirst(2), radix: 8) else { throw error("The number \(text) is out of range; quote it.") }
        return value
      }
      if text.wholeMatch(of: /0x[0-9a-fA-F]+/) != nil {
        guard let value = Int(text.dropFirst(2), radix: 16) else { throw error("The number \(text) is out of range; quote it.") }
        return value
      }
      if text.wholeMatch(of: /[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?/) != nil {
        guard let value = Double(text), value.isFinite else { throw error("The number \(text) is out of range; quote it.") }
        return value
      }
      return text
    }

    // MARK: Quoted scalars

    /// A single- or double-quoted scalar, which may continue over the following lines.
    mutating func quotedScalar(_ raw: String, line: Int) throws -> String {
      let quote = raw.first!
      var source = String(raw.dropFirst())
      var result = ""
      // Where in `result` the last escaped character ends: folding trims only the plain
      // whitespace a line ends with.
      var protected = 0
      while true {
        var position = source.startIndex
        var closed: String.Index?
        var escapedBreak = false
        while position < source.endIndex {
          let character = source[position]
          if character == quote {
            let next = source.index(after: position)
            if quote == "'", next < source.endIndex, source[next] == "'" {
              result.append("'")
              protected = result.count
              position = source.index(after: next)
              continue
            }
            closed = next
            break
          }
          if quote == "\"", character == "\\" {
            let next = source.index(after: position)
            if next == source.endIndex {
              // An escaped line break: the lines join with nothing between.
              escapedBreak = true
              break
            }
            var rest = String(source[next...])
            let (escaped, used) = try escape(&rest, line: index - 1)
            result += escaped
            protected = result.count
            position = source.index(next, offsetBy: used)
            continue
          }
          result.append(character)
          position = source.index(after: position)
        }
        if let closed {
          let after = stripComment(String(source[closed...]))
          guard after.isEmpty else { throw error("Unexpected text after the closing quote.", at: index - 1) }
          return result
        }
        // The scalar goes on: fold the line break.
        if !escapedBreak {
          while result.count > protected, let last = result.last, last == " " || last == "\t" { result.removeLast() }
        }
        var breaks = 0
        while true {
          guard index < lines.count else { throw error("The quoted value isn't closed.", at: line) }
          let next = lines[index]
          index += 1
          if Self.isBlank(next) {
            breaks += 1
            continue
          }
          if !escapedBreak { result += breaks == 0 ? " " : String(repeating: "\n", count: breaks) }
          source = String(next.drop(while: { $0 == " " || $0 == "\t" }))
          break
        }
        protected = min(protected, result.count)
      }
    }

    /// One escape after a backslash in a double-quoted scalar: the text it stands for and how many
    /// characters of `rest` it used.
    func escape(_ rest: inout String, line: Int? = nil) throws -> (String, Int) {
      guard let character = rest.first else { throw error("A backslash ends the value.", at: line) }
      let simple: [Character: String] = [
        "0": "\u{0}", "a": "\u{7}", "b": "\u{8}", "t": "\t", "\t": "\t", "n": "\n", "v": "\u{B}", "f": "\u{C}", "r": "\r",
        "e": "\u{1B}", " ": " ", "\"": "\"", "/": "/", "\\": "\\", "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}",
      ]
      if let text = simple[character] { return (text, 1) }
      let digits: Int
      switch character {
      case "x": digits = 2
      case "u": digits = 4
      case "U": digits = 8
      default: throw error("Unknown escape \\\(character).", at: line)
      }
      let hex = rest.dropFirst().prefix(digits)
      guard hex.count == digits, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
        throw error("Bad escape \\\(character)\(hex).", at: line)
      }
      return (String(Character(scalar)), 1 + digits)
    }

    // MARK: Flow sequences

    /// `[a, "b", 3]`: scalars only, on one line or several.
    mutating func flowSequence(_ raw: String, line: Int) throws -> [Any] {
      var text = raw
      // Gather lines until the brackets close, outside quotes.
      while !Self.closesFlow(text) {
        guard index < lines.count else { throw error("The [ … ] list isn't closed.", at: line) }
        text += " " + lines[index].trimmingCharacters(in: .whitespaces)
        index += 1
      }
      var items: [Any] = []
      var position = text.index(after: text.startIndex)
      var expectsItem = true
      while position < text.endIndex {
        let character = text[position]
        if character == " " || character == "\t" {
          position = text.index(after: position)
          continue
        }
        if character == "]" {
          let after = stripComment(String(text[text.index(after: position)...]))
          guard after.isEmpty else { throw error("Unexpected text after ].", at: line) }
          return items
        }
        if character == "," {
          guard !expectsItem else { throw error("An empty item in a [ … ] list.", at: line) }
          expectsItem = true
          position = text.index(after: position)
          continue
        }
        guard expectsItem else { throw error("Expected a comma between items.", at: line) }
        if character == "[" || character == "{" { throw error("Nested lists and mappings in [ … ] aren't supported.", at: line) }
        if "&*!".contains(character) { throw error("Anchors, aliases and tags aren't supported.", at: line) }
        if character == "\"" || character == "'" {
          var end = text.index(after: position)
          while end < text.endIndex {
            if text[end] == "\\", character == "\"" {
              end = text.index(end, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
              continue
            }
            if text[end] == character {
              let next = text.index(after: end)
              if character == "'", next < text.endIndex, text[next] == "'" {
                end = text.index(after: next)
                continue
              }
              break
            }
            end = text.index(after: end)
          }
          guard end < text.endIndex else { throw error("A quoted item isn't closed.", at: line) }
          var scratch = Parser(text: "", lineOffset: lineOffset)
          scratch.index = line + 1
          items.append(try scratch.quotedScalar(String(text[position...end]), line: line))
          position = text.index(after: end)
        } else {
          var end = position
          while end < text.endIndex, text[end] != ",", text[end] != "]" { end = text.index(after: end) }
          let item = text[position..<end].trimmingCharacters(in: .whitespaces)
          if item.contains(": ") || item.contains("[") || item.contains("{") || item.contains("}") {
            throw error("Only plain values and quoted strings go in a [ … ] list.", at: line)
          }
          items.append(try Self.resolve(item, error: { error($0, at: line) }))
          position = end
        }
        expectsItem = false
      }
      throw error("The [ … ] list isn't closed.", at: line)
    }

    static func closesFlow(_ text: String) -> Bool {
      var quote: Character?
      var escaped = false
      for character in text {
        if let open = quote {
          if escaped {
            escaped = false
          } else if open == "\"", character == "\\" {
            escaped = true
          } else if character == open {
            quote = nil
          }
        } else if character == "\"" || character == "'" {
          quote = character
        } else if character == "]" {
          return true
        } else if character == "#" {
          return false
        }
      }
      return false
    }

    // MARK: Block scalars

    /// `|` (literal) or `>` (folded), with an optional chomping indicator (`-` strip, `+` keep,
    /// clip by default) and indentation indicator, then the more-indented lines below.
    mutating func blockScalar(header: String, literal: Bool, parentIndent: Int, line: Int) throws -> String {
      var chomping: Character = " "
      var explicitIndent: Int?
      let indicators = stripComment(String(header.dropFirst()))
      for character in indicators {
        if character == "-" || character == "+", chomping == " " {
          chomping = character
        } else if let digit = character.wholeNumberValue, digit > 0, explicitIndent == nil, character.isASCII {
          explicitIndent = digit
        } else {
          throw error("Unexpected \(character) after \(literal ? "|" : ">").", at: line)
        }
      }
      let base = max(parentIndent, 0)
      var contentIndent = explicitIndent.map { base + $0 }
      var collected: [String] = []
      while index < lines.count {
        let next = lines[index]
        if Self.isBlank(next) {
          collected.append(String(next.dropFirst(min(next.count, contentIndent ?? next.count))))
          index += 1
          continue
        }
        let nextIndent = next.prefix(while: { $0 == " " }).count
        if contentIndent == nil {
          if next.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") { throw error("Tabs can't indent YAML; use spaces.") }
          guard nextIndent > parentIndent else { break }
          contentIndent = nextIndent
          // Leading blank lines keep only what's past the content's indentation.
          collected = collected.map { String($0.dropFirst(min($0.count, nextIndent))) }
        }
        guard let contentIndent, nextIndent >= contentIndent else { break }
        collected.append(String(next.dropFirst(contentIndent)))
        index += 1
      }
      // Trailing blank lines are chomped, not content.
      var trailing = 0
      while let last = collected.last, last.allSatisfy({ $0 == " " }) {
        collected.removeLast()
        trailing += 1
      }
      guard !collected.isEmpty else {
        return chomping == "+" ? String(repeating: "\n", count: trailing) : ""
      }
      var text: String
      if literal {
        text = collected.joined(separator: "\n")
      } else {
        text = ""
        var started = false
        var pendingBreaks = 0
        var previousMoreIndented = false
        for piece in collected {
          if piece.isEmpty {
            pendingBreaks += 1
            continue
          }
          let moreIndented = piece.first == " " || piece.first == "\t"
          if started {
            if moreIndented || previousMoreIndented {
              text += String(repeating: "\n", count: pendingBreaks + 1)
            } else {
              text += pendingBreaks == 0 ? " " : String(repeating: "\n", count: pendingBreaks)
            }
          } else {
            text += String(repeating: "\n", count: pendingBreaks)
          }
          text += piece
          started = true
          pendingBreaks = 0
          previousMoreIndented = moreIndented
        }
      }
      switch chomping {
      case "-": break
      case "+": text += String(repeating: "\n", count: trailing + 1)
      default: text += "\n"
      }
      return text
    }
  }

  // MARK: - Rules

  /// What's wrong with a skill name by the Agent Skills specification: 1–64 lowercase letters,
  /// digits and hyphens, not starting or ending with a hyphen or holding two in a row. Nil when
  /// it's fine.
  static func nameProblem(_ name: String) -> String? {
    if name.isEmpty { return "The name can't be empty." }
    if name.count > maxNameLength { return "The name can be at most \(maxNameLength) characters." }
    if !name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) {
      return "The name can only have lowercase letters, digits and hyphens."
    }
    if name.hasPrefix("-") || name.hasSuffix("-") { return "The name can't start or end with a hyphen." }
    if name.contains("--") { return "The name can't have two hyphens in a row." }
    return nil
  }

  /// The Agent Skills specification's rules for the fields it defines; fields it doesn't define
  /// pass.
  static func validate(_ frontmatter: [String: Any], directoryName: String) -> [Issue] {
    var issues: [Issue] = []
    if let name = frontmatter["name"] {
      if let name = name as? String {
        if let problem = nameProblem(name) {
          issues.append(Issue(field: "name", message: problem))
        } else if name != directoryName {
          issues.append(Issue(field: "name", message: "The name “\(name)” must match its folder, “\(directoryName)”."))
        }
      } else {
        issues.append(Issue(field: "name", message: "The name must be text."))
      }
    } else {
      issues.append(Issue(field: "name", message: "The frontmatter needs a name."))
    }
    if let description = frontmatter["description"] {
      if let description = description as? String {
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          issues.append(Issue(field: "description", message: "The description can't be empty."))
        } else if description.count > maxDescriptionLength {
          issues.append(Issue(field: "description", message: "The description can be at most \(maxDescriptionLength) characters."))
        }
      } else {
        issues.append(Issue(field: "description", message: "The description must be text."))
      }
    } else {
      issues.append(Issue(field: "description", message: "The frontmatter needs a description."))
    }
    if let compatibility = frontmatter["compatibility"] {
      if let compatibility = compatibility as? String {
        if compatibility.count > maxCompatibilityLength {
          issues.append(Issue(field: "compatibility", message: "compatibility can be at most \(maxCompatibilityLength) characters."))
        }
      } else {
        issues.append(Issue(field: "compatibility", message: "compatibility must be text."))
      }
    }
    if let metadata = frontmatter["metadata"], !(metadata is [String: Any]) {
      issues.append(Issue(field: "metadata", message: "metadata must be a mapping of keys to values."))
    }
    if let tools = frontmatter["allowed-tools"], !(tools is String) {
      issues.append(Issue(field: "allowed-tools", message: "allowed-tools must be text (tool names separated by spaces)."))
    }
    return issues
  }

  // MARK: - Writing

  /// A SKILL.md: name and description first, quoted when they'd otherwise read as something else,
  /// then the other fields exactly as written, then the body.
  static func serialize(name: String, description: String, otherYAML: String, body: String) -> Data {
    var text = "---\nname: \(scalar(name))\ndescription: \(scalar(description))\n"
    if !otherYAML.isEmpty {
      text += otherYAML
      if !otherYAML.hasSuffix("\n") { text += "\n" }
    }
    text += "---\n" + body
    return Data(text.utf8)
  }

  /// `value` as a YAML scalar that reads back as this exact string: plain when that's safe,
  /// otherwise double-quoted with escapes.
  static func scalar(_ value: String) -> String {
    if isSafePlain(value) { return value }
    var quoted = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": quoted += "\\\""
      case "\\": quoted += "\\\\"
      case "\n": quoted += "\\n"
      case "\t": quoted += "\\t"
      case "\r": quoted += "\\r"
      default:
        if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) || scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{FEFF}" {
          quoted += String(format: "\\u%04X", scalar.value)
        } else {
          quoted.unicodeScalars.append(scalar)
        }
      }
    }
    return quoted + "\""
  }

  private static func isSafePlain(_ value: String) -> Bool {
    guard let first = value.first, let last = value.last else { return false }
    if first == " " || last == " " || first == "\t" || last == "\t" { return false }
    if "-?:,[]{}#&*!|>'\"%@`~".contains(first) { return false }
    if value.contains(": ") || value.contains(" #") || value.hasSuffix(":") { return false }
    if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value >= 0x80 }) { return false }
    guard let resolved = try? Parser.resolve(value, error: { ParseError(line: 0, message: $0) }), resolved is String else { return false }
    return true
  }

  /// The frontmatter without its top-level `name` and `description` (and their continuation
  /// lines), as written: what the editor shows as "other fields" and `serialize` puts back.
  static func extractOther(yaml: String) -> String {
    var lines = yaml.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    var kept: [String] = []
    var skipping = false
    for raw in lines {
      let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
      // A line at the left edge starts the next field; anything else (indented lines, blank
      // lines, a sequence's dashes, comments) goes with the field before it.
      let isBlank = line.allSatisfy { $0 == " " || $0 == "\t" }
      if !isBlank, let first = line.first, first != " ", first != "\t", first != "-", first != "#" {
        let key = topLevelKey(line)
        skipping = key == "name" || key == "description"
      }
      if !skipping { kept.append(line) }
    }
    return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
  }

  private static func topLevelKey(_ line: String) -> String? {
    var parser = Parser(text: "", lineOffset: 0)
    parser.index = 0
    guard let (key, _) = try? parser.key(in: Substring(line)) else { return nil }
    return key
  }
}
#endif
