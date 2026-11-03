import Foundation

/// The knobs of the Characters screen and how they're written as sentences. The knobs are data
/// (CharacterKnobs.json in the app, or a copy of it in Application Support, which wins), so a knob
/// or option can be added without code: the format is in docs/characters.md. Only the sentence
/// shapes (`Section.Sentence`) and a knob's places in them (`Knob.Role`) are code.
struct CharacterKnobSet: Decodable {
  struct Reference: Decodable {
    var template: String
    var negative: String
    /// The No Style look of a sheet: the look without the framing, which the sheet sets.
    var sheetTemplate: String?
  }

  /// A character sheet: one image showing the character several ways, from one prompt.
  struct Sheet: Decodable, Identifiable {
    var id: String
    var title: String
    /// Width over height, which suits how many views it holds and how they're laid out.
    var aspect: Double
    /// `{{SUBJECT}}` is the description, and `{{CUSTOM}}` the character's custom sheet text.
    var template: String
    /// Asks for text of your own (`{{CUSTOM}}`).
    var takesText: Bool?

    /// The size for this sheet at so many megapixels, in the 64-pixel units the size setting uses.
    func size(megapixels: Int) -> (width: Int, height: Int) {
      let height = (Double(megapixels) * 1_000_000 / aspect).squareRoot()
      func units(_ value: Double) -> Int { max(Int((value / 64).rounded()), 1) * 64 }
      return (units(height * aspect), units(height))
    }

    /// The sheet's words around the description, which then fill a style's subject.
    func subject(description: String, custom: String) -> String {
      let values = [Style.subject: description, "CUSTOM": English.withoutFinalStop(custom.trimmed)]
      return Style(name: title, template: template).apply(values, negativePrompt: "").prompt
    }
  }

  struct Option: Decodable, Hashable {
    /// What the picker or slider shows, and what a character stores.
    var label: String
    /// Written instead of the knob's format; `{noun}` is the section's noun.
    var phrase: String?
    /// The head word when it isn't the label ("a collar" writes "collar").
    var word: String?
    /// Takes a/an in front of the words before it ("a Victorian evening gown").
    var article = false
    /// Stands for the whole section's phrase, with nothing else from its knobs ("no hair", "nothing").
    var alone = false
    /// Goes after the noun rather than before it ("auburn hair in a bun").
    var after: String?
    /// The colour goes before this word rather than after it ("a red collar", not "a collar in red").
    var colourFirst = false
    /// Takes plural verbs ("They have").
    var plural = false

    private enum CodingKeys: String, CodingKey {
      case label, phrase, word, article, alone, after, colourFirst, plural
    }

    /// A plain string is an option with just a label.
    init(from decoder: Decoder) throws {
      if let label = try? decoder.singleValueContainer().decode(String.self) {
        self.label = label
        return
      }
      let container = try decoder.container(keyedBy: CodingKeys.self)
      label = try container.decode(String.self, forKey: .label)
      phrase = try container.decodeIfPresent(String.self, forKey: .phrase)
      word = try container.decodeIfPresent(String.self, forKey: .word)
      article = try container.decodeIfPresent(Bool.self, forKey: .article) ?? false
      alone = try container.decodeIfPresent(Bool.self, forKey: .alone) ?? false
      after = try container.decodeIfPresent(String.self, forKey: .after)
      colourFirst = try container.decodeIfPresent(Bool.self, forKey: .colourFirst) ?? false
      plural = try container.decodeIfPresent(Bool.self, forKey: .plural) ?? false
    }
  }

  struct Knob: Decodable, Identifiable {
    enum Control: String, Decodable { case slider, picker, text }

    /// Where a knob's phrase goes in its section's sentence.
    enum Role: String, Decodable {
      /// The noun of the opening sentence.
      case kind
      /// Sets how later sentences refer to the character; writes nothing itself.
      case pronoun
      /// An adjective in front of the noun ("middle-aged woman", "auburn hair").
      case before
      /// An item of the "with …" or "has …" list.
      case list
      /// An adjective of the "is …" list.
      case adjective
      /// A phrase after ", with" ("with an upright posture").
      case with
      /// The noun of a "wears" sentence.
      case head
      /// A phrase after the noun ("in deep green").
      case after
    }

    var id: String
    var title: String
    var control: Control
    var role: Role
    var options: [Option]
    /// How an option's label is written: `{value}` is the label, `{a}` is a or an.
    var format: String?
    var placeholder: String?
    /// How a plain number in the Custom box is written: 35 is "35-year-old" for Age.
    var numericFormat: String?
    /// The Custom box's placeholder, when "Custom" doesn't say enough.
    var customPrompt: String?
    /// Whether the dice change it. Off for Pronoun: the kind usually decides it.
    var randomizes: Bool

    private enum CodingKeys: String, CodingKey {
      case id, title, control, role, options, format, placeholder, numericFormat, customPrompt, randomizes
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      title = try container.decode(String.self, forKey: .title)
      control = try container.decode(Control.self, forKey: .control)
      role = try container.decode(Role.self, forKey: .role)
      options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
      format = try container.decodeIfPresent(String.self, forKey: .format)
      placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
      numericFormat = try container.decodeIfPresent(String.self, forKey: .numericFormat)
      customPrompt = try container.decodeIfPresent(String.self, forKey: .customPrompt)
      randomizes = try container.decodeIfPresent(Bool.self, forKey: .randomizes) ?? (control != .text)
    }

    func option(_ label: String?) -> Option? {
      label.flatMap { label in options.first { $0.label == label } }
    }

    /// What the Custom box writes: its text, or for a knob that takes numbers, a number in words
    /// around it. Empty when Custom is off.
    func customPhrase(_ custom: String) -> String {
      let custom = custom.trimmed
      guard let numericFormat, custom.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil else { return custom }
      return numericFormat.replacingOccurrences(of: "{value}", with: custom)
    }

    /// The words an option writes, with `noun` for `{noun}`.
    func phrase(_ option: Option, noun: String = "") -> String {
      let written = (option.phrase ?? format ?? "{value}")
        .replacingOccurrences(of: "{value}", with: option.label)
        .replacingOccurrences(of: "{noun}", with: noun)
      guard let range = written.range(of: "{a} ") else { return written }
      let rest = String(written[range.upperBound...])
      return written.replacingCharacters(in: range, with: English.article(before: rest) + " ")
    }
  }

  struct Noun: Decodable {
    var `default`: String
    var options: [Option]

    func option(_ label: String?) -> Option? {
      let label = label ?? `default`
      return options.first { $0.label == label } ?? options.first { $0.label == `default` }
    }
  }

  struct Section: Decodable, Identifiable {
    /// A sentence's shape. A section that joins the one before shares its sentence.
    enum Sentence: String, Decodable {
      case opening, `is`, has, wears
    }

    var id: String
    var title: String
    var sentence: Sentence?
    var joinsPrevious = false
    /// Between a section's adjectives when they make one noun phrase.
    var separator = " "
    var textPrompt: String
    /// The noun switch on the section's header.
    var noun: Noun?
    var knobs: [Knob]

    private enum CodingKeys: String, CodingKey {
      case id, title, sentence, joinsPrevious, separator, textPrompt, noun, knobs
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      title = try container.decode(String.self, forKey: .title)
      sentence = try container.decodeIfPresent(Sentence.self, forKey: .sentence)
      joinsPrevious = try container.decodeIfPresent(Bool.self, forKey: .joinsPrevious) ?? false
      separator = try container.decodeIfPresent(String.self, forKey: .separator) ?? " "
      textPrompt = try container.decodeIfPresent(String.self, forKey: .textPrompt) ?? ""
      noun = try container.decodeIfPresent(Noun.self, forKey: .noun)
      knobs = try container.decodeIfPresent([Knob].self, forKey: .knobs) ?? []
    }
  }

  var reference: Reference
  var sections: [Section]
  var sheets: [Sheet] = []

  /// The two sizes a sheet can be, in megapixels.
  static let sheetMegapixels = [1, 2]

  private enum CodingKeys: String, CodingKey { case reference, sections, sheets }

  init(reference: Reference, sections: [Section]) {
    self.reference = reference
    self.sections = sections
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    reference = try container.decode(Reference.self, forKey: .reference)
    sections = try container.decode([Section].self, forKey: .sections)
    sheets = try container.decodeIfPresent([Sheet].self, forKey: .sheets) ?? []
  }

  /// The look of a sheet with No Style.
  var referenceSheetStyle: Style {
    Style(name: "No Style", template: reference.sheetTemplate ?? "{{SUBJECT}}", negative: reference.negative)
  }

  /// The character's chosen sheet, else the first.
  func sheet(of character: SavedCharacter) -> Sheet? {
    sheets.first { $0.id == character.sheet } ?? sheets.first
  }

  /// The look of a render with No Style.
  var referenceStyle: Style {
    Style(name: "No Style", template: reference.template, negative: reference.negative)
  }

  private var allKnobs: [Knob] { sections.flatMap(\.knobs) }

  /// The file that replaces the knobs in the app.
  static var overrideFile: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier/CharacterKnobs.json")
  }

  /// The knobs in Application Support when there's a readable file there, else the app's own.
  static func load() -> CharacterKnobSet {
    let own = bundled()
    if let data = try? Data(contentsOf: overrideFile) {
      do {
        var knobs = try JSONDecoder().decode(CharacterKnobSet.self, from: data)
        // A copy from before sheets keeps working, with the app's.
        if knobs.sheets.isEmpty { knobs.sheets = own.sheets }
        if knobs.reference.sheetTemplate == nil { knobs.reference.sheetTemplate = own.reference.sheetTemplate }
        return knobs
      } catch {
        print("Couldn't read \(overrideFile.path): \(error)")
      }
    }
    return own
  }

  private static func bundled() -> CharacterKnobSet {
    guard let url = Bundle.main.url(forResource: "CharacterKnobs", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let knobs = try? JSONDecoder().decode(CharacterKnobSet.self, from: data)
    else {
      print("The app's CharacterKnobs.json is missing or unreadable")
      return CharacterKnobSet(reference: Reference(template: "{{SUBJECT}}", negative: ""), sections: [])
    }
    return knobs
  }

  // MARK: - The description

  /// One sentence for each group of sections, skipping any with nothing set. The two examples in
  /// docs/characters.md are checked by `--characters-check`.
  func description(of character: SavedCharacter) -> String {
    let writer = Writer(character: character, voice: voice(of: character), kind: kind(of: character))
    var groups: [[Section]] = []
    for section in sections {
      if section.joinsPrevious, !groups.isEmpty {
        groups[groups.count - 1].append(section)
      } else {
        groups.append([section])
      }
    }
    return groups.compactMap { group in
      writer.sentence(group).map(English.sentence)
    }
    .joined(separator: " ")
  }

  private func kind(of character: SavedCharacter) -> String {
    allKnobs.first { $0.role == .kind }.map { character.written($0) } ?? ""
  }

  /// How later sentences refer to the character: the pronoun, or "The <kind>".
  private func voice(of character: SavedCharacter) -> English.Voice {
    if let knob = allKnobs.first(where: { $0.role == .pronoun }) {
      let setting = character.setting(knob.id)
      let custom = setting.custom.trimmed
      if !custom.isEmpty { return English.Voice(subject: custom.capitalizedFirst, plural: false) }
      if let option = knob.option(setting.value) {
        return English.Voice(subject: option.label.capitalizedFirst, plural: option.plural)
      }
    }
    let kind = English.splitDeterminer(kind(of: character)).rest
    return English.Voice(subject: "The " + (kind.isEmpty ? English.fallbackKind : kind), plural: false)
  }

  /// Writes the sentences; each `Section.Sentence` is a shape filled from its knobs' roles.
  private struct Writer {
    let character: SavedCharacter
    let voice: English.Voice
    let kind: String

    func sentence(_ group: [Section]) -> String? {
      switch group.first?.sentence {
      case .opening: opening(group)
      case .is: isSentence(group)
      case .wears: wears(group)
      case .has, nil: has(group)
      }
    }

    /// What a knob writes in this section, or nil when it's unset: Custom replaces the phrase.
    private func phrase(_ knob: Knob, in section: Section) -> String? {
      let setting = character.setting(knob.id)
      let custom = knob.customPhrase(setting.custom)
      if !custom.isEmpty { return custom }
      if knob.control == .text { return setting.value?.trimmed.nilIfEmpty }
      guard let option = knob.option(setting.value) else { return nil }
      return knob.phrase(option, noun: section.noun?.option(character.nouns[section.id])?.label ?? "")
    }

    private func phrases(_ section: Section, _ role: Knob.Role) -> [String] {
      section.knobs.filter { $0.role == role }.compactMap { phrase($0, in: section) }
    }

    private func text(_ section: Section) -> String? {
      character.texts[section.id]?.trimmed.nilIfEmpty.map(English.withoutFinalStop)
    }

    /// "A middle-aged woman, its text, with an oval face, green eyes and a warm smile, the rest."
    private func opening(_ group: [Section]) -> String? {
      guard let identity = group.first else { return nil }
      let before = phrases(identity, .before)
      let listed = group.flatMap { phrases($0, .list) }
      let identityText = text(identity)
      let otherTexts = group.dropFirst().compactMap(text)
      guard !kind.isEmpty || !before.isEmpty || !listed.isEmpty || identityText != nil || !otherTexts.isEmpty else {
        return nil
      }
      let split = English.splitDeterminer(kind)
      let words = (before + [split.rest.isEmpty ? English.fallbackKind : split.rest]).joined(separator: " ")
      // A typed "the", "two" or "some" stays; anything else takes a or an for its new first word.
      let determiner = split.keepsDeterminer ? split.determiner : English.article(before: words)
      var sentence = determiner + " " + words
      if let identityText { sentence += ", " + identityText }
      if !listed.isEmpty {
        sentence += (identityText == nil ? " with " : ", with ") + English.list(listed)
        if !otherTexts.isEmpty { sentence += ", " + otherTexts.joined(separator: ", ") }
      } else if !otherTexts.isEmpty {
        sentence += (identityText == nil ? " with " : ", with ") + otherTexts.joined(separator: ", ")
      }
      return sentence
    }

    /// "She is tall, slender and athletic, with an upright posture, its text."
    private func isSentence(_ group: [Section]) -> String? {
      let adjectives = group.flatMap { phrases($0, .adjective) }
      let withs = group.flatMap { phrases($0, .with) }
      let texts = group.compactMap(text)
      var parts: [String] = []
      if !adjectives.isEmpty {
        parts.append("\(voice.subject) \(voice.is) \(English.list(adjectives))")
        if !withs.isEmpty { parts.append("with " + English.list(withs)) }
      } else if !withs.isEmpty {
        parts.append("\(voice.subject) \(voice.has) \(English.list(withs))")
      } else if let first = texts.first {
        return "\(voice.subject) \(voice.is) " + ([first] + texts.dropFirst()).joined(separator: ", ")
      } else {
        return nil
      }
      return (parts + texts).joined(separator: ", ")
    }

    /// One noun phrase from a section's adjectives and noun: "shoulder-length wavy auburn hair".
    private func nounPhrase(_ section: Section) -> String? {
      guard let noun = section.noun?.option(character.nouns[section.id]) else { return nil }
      let knobs = section.knobs.filter { $0.role == .before }
      for knob in knobs where character.setting(knob.id).custom.trimmed.isEmpty {
        if let option = knob.option(character.setting(knob.id).value), option.alone {
          return knob.phrase(option, noun: noun.label)
        }
      }
      var before: [String] = []
      var after: [String] = []
      for knob in knobs {
        let setting = character.setting(knob.id)
        if setting.custom.trimmed.isEmpty, let placed = knob.option(setting.value)?.after {
          after.append(placed)
        } else if let phrase = phrase(knob, in: section) {
          before.append(phrase)
        }
      }
      guard !before.isEmpty || !after.isEmpty else { return nil }
      var words = before.joined(separator: section.separator)
      if !words.isEmpty { words += " " }
      words += noun.label
      if noun.article { words = English.article(before: words) + " " + words }
      return ([words] + after).joined(separator: " ")
    }

    /// "She has shoulder-length wavy auburn hair and fair, freckled skin, their texts."
    private func has(_ group: [Section]) -> String? {
      let phrases = group.flatMap { section in
        section.noun == nil ? self.phrases(section, .list) : [nounPhrase(section)].compactMap(\.self)
      }
      let texts = group.compactMap(text)
      guard !phrases.isEmpty || !texts.isEmpty else { return nil }
      let lead = phrases.isEmpty ? [] : [English.list(phrases)]
      return "\(voice.subject) \(voice.has) " + (lead + texts).joined(separator: ", ")
    }

    /// "She wears a Victorian evening gown in deep green, with a leather satchel, its text."
    private func wears(_ group: [Section]) -> String? {
      guard let section = group.first else { return nil }
      let withs = phrases(section, .with)
      let texts = group.compactMap(text)
      var parts: [String] = []
      if let garment = garment(section) { parts.append(garment) }
      if !withs.isEmpty {
        parts.append(parts.isEmpty ? English.list(withs) : "with " + English.list(withs))
      }
      parts += texts
      return parts.isEmpty ? nil : "\(voice.subject) \(voice.wears) " + parts.joined(separator: ", ")
    }

    private func garment(_ section: Section) -> String? {
      let head = section.knobs.first { $0.role == .head }
      let setting = head.map { character.setting($0.id) }
      let custom = setting?.custom.trimmed ?? ""
      let option = head?.option(setting?.value)
      if custom.isEmpty, let option, option.alone { return option.word ?? option.label }
      var before = phrases(section, .before)
      var after = phrases(section, .after)
      // Words the colour goes in front of, when its knob isn't Custom.
      if custom.isEmpty, option?.colourFirst == true,
         let colour = section.knobs.first(where: { $0.role == .after }),
         character.setting(colour.id).custom.trimmed.isEmpty,
         let label = character.setting(colour.id).value, colour.option(label) != nil
      {
        before.append(label)
        after = []
      }
      let noun: String
      var determiner: String?
      if !custom.isEmpty {
        let split = English.splitDeterminer(custom)
        noun = split.rest
        if !split.determiner.isEmpty { determiner = split.keepsDeterminer ? split.determiner : "" }
      } else if let option {
        noun = option.word ?? option.label
        if option.article { determiner = "" }
      } else if !before.isEmpty || !after.isEmpty {
        noun = English.fallbackClothes
      } else {
        return nil
      }
      var words = (before + [noun]).joined(separator: " ")
      if let determiner { words = (determiner.isEmpty ? English.article(before: words) : determiner) + " " + words }
      return ([words] + after).joined(separator: " ")
    }
  }

  // MARK: - Randomize

  /// Rerolls a section's unlocked, non-Custom knobs (never Kind or Pronoun). A knob can come up
  /// unset, so a reroll isn't always fully dressed.
  func randomize(_ section: Section, in character: inout SavedCharacter) {
    for knob in section.knobs where knob.randomizes && !knob.options.isEmpty {
      var setting = character.setting(knob.id)
      guard !setting.locked, setting.custom.trimmed.isEmpty else { continue }
      setting.value = Double.random(in: 0..<1) < Self.unsetChance ? nil : knob.options.randomElement()?.label
      character.knobs[knob.id] = setting
    }
  }

  private static let unsetChance = 0.2

  /// Randomize All: every section.
  func randomizeAll(in character: inout SavedCharacter) {
    for section in sections { randomize(section, in: &character) }
  }
}

/// The bits of English the sentences need.
enum English {
  /// Refers to a character with no kind typed.
  static let fallbackKind = "person"
  /// The noun for an era or colour with no outfit picked.
  static let fallbackClothes = "clothes"

  struct Voice {
    var subject: String
    var plural: Bool
    var `is`: String { plural ? "are" : "is" }
    var has: String { plural ? "have" : "has" }
    var wears: String { plural ? "wear" : "wears" }
  }

  /// "a" or "an" for what follows, by how it starts: a vowel, less the words that sound otherwise.
  static func article(before words: String) -> String {
    let word = words.lowercased()
    for start in ["hour", "honest", "heir"] where word.hasPrefix(start) { return "an" }
    for start in ["uni", "use", "usu", "uto", "one", "once", "eu"] where word.hasPrefix(start) { return "a" }
    // Digits read as words: "an 8-year-old", "an 18-year-old", "an 1890s", but "a 180-year-old".
    let digits = word.prefix { $0.isNumber }
    if !digits.isEmpty {
      return digits.hasPrefix("8") || (digits.count != 3 && (digits.hasPrefix("11") || digits.hasPrefix("18"))) ? "an" : "a"
    }
    return word.first.map { "aeiou".contains($0) } == true ? "an" : "a"
  }

  /// A phrase's leading determiner, apart from the rest: "an old man" is "an" and "old man". A typed
  /// a or an gets recomputed for whatever goes in front of the noun; the others stay as typed.
  static func splitDeterminer(_ text: String) -> (determiner: String, rest: String, keepsDeterminer: Bool) {
    let text = text.trimmed
    let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return ("", text, false) }
    let first = parts[0].lowercased()
    if first == "a" || first == "an" { return (first, parts[1], false) }
    let kept: Set = ["the", "some", "two", "three", "four", "five", "six", "several", "many", "his", "her", "their", "my", "our"]
    if kept.contains(first) { return (first, parts[1], true) }
    return ("", text, false)
  }

  /// "a, b and c".
  static func list(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
  }

  /// Capitalized and ending in a full stop.
  static func sentence(_ text: String) -> String {
    let text = text.trimmed.capitalizedFirst
    return text.last.map { ".!?".contains($0) } == true ? text : text + "."
  }

  static func withoutFinalStop(_ text: String) -> String {
    text.hasSuffix(".") && !text.hasSuffix("..") ? String(text.dropLast()) : text
  }
}

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
