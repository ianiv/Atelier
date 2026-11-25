@testable import Atelier
import Foundation
import Testing

@Suite(.tags(.smoke))
struct SkillFrontmatterTests {
  /// The spec's pdf-processing SKILL.md (Skills: Example Message Flow), 151 bytes.
  static let pdfSkill = "---\nname: pdf-processing\ndescription: Extract, fill, and assemble PDF documents\n---\n\n# PDF processing\n\nChoose the matching template from `templates/`.\n"

  private func parse(_ yaml: String) throws -> [String: Any] { try SkillFrontmatter.parse(yaml) }

  private func parseError(_ yaml: String) -> SkillFrontmatter.ParseError? {
    do {
      _ = try SkillFrontmatter.parse(yaml)
      return nil
    } catch let error as SkillFrontmatter.ParseError {
      return error
    } catch {
      return nil
    }
  }

  @Test func specExample() throws {
    #expect(Data(Self.pdfSkill.utf8).count == 151)
    let frontmatter = try SkillFrontmatter.parse(skillFile: Data(Self.pdfSkill.utf8))
    #expect(frontmatter["name"] as? String == "pdf-processing")
    #expect(frontmatter["description"] as? String == "Extract, fill, and assemble PDF documents")
    #expect(frontmatter.count == 2)
    let (_, body) = try SkillFrontmatter.split(Data(Self.pdfSkill.utf8))
    #expect(body == "\n# PDF processing\n\nChoose the matching template from `templates/`.\n")
    #expect(SkillFrontmatter.validate(frontmatter, directoryName: "pdf-processing").isEmpty)
  }

  @Test func scalarKinds() throws {
    let value = try parse(
      """
      a: plain text
      b: 'single ''quoted'''
      c: "double \\"quoted\\"\\t\\u00e9\\x41"
      d: true
      e: False
      f: null
      g: ~
      h: 42
      i: -7
      j: 0x1F
      k: 0o17
      l: 1.5
      m: 2e3
      n: yes
      o:
      p: 1.2.3
      q: "123"
      r: http://example.com/a#b
      s: value # a comment
      """)
    #expect(value["a"] as? String == "plain text")
    #expect(value["b"] as? String == "single 'quoted'")
    #expect(value["c"] as? String == "double \"quoted\"\té" + "A")
    #expect(value["d"] as? Bool == true)
    #expect(value["e"] as? Bool == false)
    #expect(value["f"] is NSNull && value["g"] is NSNull && value["o"] is NSNull)
    #expect(value["h"] as? Int == 42 && value["i"] as? Int == -7 && value["j"] as? Int == 31 && value["k"] as? Int == 15)
    #expect(value["l"] as? Double == 1.5 && value["m"] as? Double == 2000)
    #expect(value["n"] as? String == "yes", "YAML 1.2's core schema: yes is a string")
    #expect(value["p"] as? String == "1.2.3")
    #expect(value["q"] as? String == "123")
    #expect(value["r"] as? String == "http://example.com/a#b")
    #expect(value["s"] as? String == "value")
  }

  @Test func collections() throws {
    let value = try parse(
      """
      license: Apache-2.0
      metadata:
        author: someone
        version: "1.0"
        nested:
          deep: 3
      tags: [a, "b c", 3, true]
      empty: []
      steps:
        - one
        - two: 2
          three: 3
        -
          - inner
      top:
      - x
      - y
      """)
    let metadata = try #require(value["metadata"] as? [String: Any])
    #expect(metadata["author"] as? String == "someone")
    #expect(metadata["version"] as? String == "1.0")
    #expect((metadata["nested"] as? [String: Any])?["deep"] as? Int == 3)
    let tags = try #require(value["tags"] as? [Any])
    #expect(tags.count == 4 && tags[1] as? String == "b c" && tags[2] as? Int == 3 && tags[3] as? Bool == true)
    #expect((value["empty"] as? [Any])?.isEmpty == true)
    let steps = try #require(value["steps"] as? [Any])
    #expect(steps.count == 3)
    #expect(steps[0] as? String == "one")
    #expect((steps[1] as? [String: Any])?["three"] as? Int == 3)
    #expect((steps[2] as? [Any])?.first as? String == "inner")
    #expect(value["top"] as? [String] == ["x", "y"])
  }

  @Test func multiLineScalars() throws {
    let value = try parse(
      """
      literal: |
        line one
          indented
        line three

      folded: >
        folded
        together

        new paragraph
      strip: |-
        no newline
      keep: |+
        kept

      plain: a long
        description that
        wraps
      quoted: "first
        second"
      after: done
      """)
    #expect(value["literal"] as? String == "line one\n  indented\nline three\n")
    #expect(value["folded"] as? String == "folded together\nnew paragraph\n")
    #expect(value["strip"] as? String == "no newline")
    #expect(value["keep"] as? String == "kept\n\n")
    #expect(value["plain"] as? String == "a long description that wraps")
    #expect(value["quoted"] as? String == "first second")
    #expect(value["after"] as? String == "done")
  }

  @Test func rejectionsCarryTheirLine() {
    let cases: [(String, Int)] = [
      ("a: 1\nb: &anchor x\n", 2),
      ("a: *alias\n", 1),
      ("a: !tag x\n", 1),
      ("a: {b: 1}\n", 1),
      ("? complex\n", 1),
      ("a: 1\na: 2\n", 2),
      ("a:\n\tb: 1\n", 2),
      ("a: 1\n...\nb: 2\n", 2),
      ("a: .inf\n", 1),
      ("a: .nan\n", 1),
      ("a: \"open\n", 1),
      ("a: [x, [y]]\n", 1),
      ("a: Use this: when\n", 1),
      ("name: x\n  bad: indent\n", 2),
      ("- just\n- a list\n", 1),
      ("a: 99999999999999999999\n", 1),
      ("a: 'x' y\n", 1),
    ]
    for (yaml, line) in cases {
      let error = parseError(yaml)
      #expect(error != nil, "refused: \(yaml.debugDescription)")
      #expect(error?.line == line, "\(yaml.debugDescription) on line \(line), got \(error?.line ?? 0): \(error?.message ?? "")")
    }
    // Numbered by SKILL.md's lines through parse(skillFile:).
    let file = Data("---\nname: a\ndescription: b\nc: &x 1\n---\n".utf8)
    #expect(throws: SkillFrontmatter.ParseError(line: 4, message: "Anchors and aliases aren't supported.")) { try SkillFrontmatter.parse(skillFile: file) }
  }

  @Test func splitting() {
    #expect(throws: SkillFrontmatter.ParseError.self) { try SkillFrontmatter.split(Data("# no frontmatter\n".utf8)) }
    #expect(throws: SkillFrontmatter.ParseError.self) { try SkillFrontmatter.split(Data("---\nname: x\n".utf8)) }
    #expect(throws: SkillFrontmatter.ParseError.self) { try SkillFrontmatter.split(Data([0xFF, 0xFE, 0x00])) }
    let crlf = try? SkillFrontmatter.parse(skillFile: Data("---\r\nname: a\r\ndescription: b\r\n---\r\nbody".utf8))
    #expect(crlf?["description"] as? String == "b")
  }

  @Test func nameRules() {
    #expect(SkillFrontmatter.nameProblem("pdf-processing") == nil)
    #expect(SkillFrontmatter.nameProblem("a") == nil)
    #expect(SkillFrontmatter.nameProblem(String(repeating: "a", count: 64)) == nil)
    for bad in ["", String(repeating: "a", count: 65), "Upper", "under_score", "-lead", "trail-", "dou--ble", "spa ce", "é"] {
      #expect(SkillFrontmatter.nameProblem(bad) != nil, "\(bad) refused")
    }
    let mismatch = SkillFrontmatter.validate(["name": "other", "description": "x"], directoryName: "folder")
    #expect(mismatch.map(\.field) == ["name"])
    let missing = SkillFrontmatter.validate([:], directoryName: "folder")
    #expect(Set(missing.map(\.field)) == ["name", "description"])
    let long = SkillFrontmatter.validate(
      ["name": "folder", "description": String(repeating: "d", count: 1025), "compatibility": String(repeating: "c", count: 501), "metadata": "x", "allowed-tools": [1]],
      directoryName: "folder")
    #expect(Set(long.map(\.field)) == ["description", "compatibility", "metadata", "allowed-tools"])
    #expect(SkillFrontmatter.validate(["name": "folder", "description": "ok", "whatever": [1, 2]], directoryName: "folder").isEmpty, "unknown keys pass")
  }

  @Test func serializeRoundTrip() throws {
    let original = """
    ---
    license: MIT # kept as written
    name: my-skill
    metadata:
      atelier-ignore-tools: "foo_bar"
      list:
      - a
    description: >
      A folded description
      over two lines.

    allowed-tools: Bash Read
    ---
    Body text.

    """
    let (yaml, body) = try SkillFrontmatter.split(Data(original.utf8))
    let other = SkillFrontmatter.extractOther(yaml: yaml)
    #expect(other == "license: MIT # kept as written\nmetadata:\n  atelier-ignore-tools: \"foo_bar\"\n  list:\n  - a\nallowed-tools: Bash Read\n")
    let tricky = ["true", "123", "a: b", "# hash", "- dash", " padded ", "line\nbreak", "quote \" and \\ back", "null", "émoji 🎨", "plain words"]
    for description in tricky {
      let data = SkillFrontmatter.serialize(name: "my-skill", description: description, otherYAML: other, body: body)
      let (newYAML, newBody) = try SkillFrontmatter.split(data)
      #expect(SkillFrontmatter.extractOther(yaml: newYAML) == other, "other fields survive byte for byte")
      #expect(newBody == body)
      let parsed = try SkillFrontmatter.parse(newYAML)
      #expect(parsed["description"] as? String == description, "\(description.debugDescription) reads back")
      #expect(parsed["name"] as? String == "my-skill")
      #expect(parsed["license"] as? String == "MIT")
    }
    #expect(SkillFrontmatter.scalar("true") == "\"true\"")
    #expect(SkillFrontmatter.scalar("pdf-processing") == "pdf-processing")
    #expect(SkillFrontmatter.extractOther(yaml: "name: a\ndescription: b\n") == "")
  }
}
