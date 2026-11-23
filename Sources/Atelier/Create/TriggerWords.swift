import Foundation

/// A LoRA's trigger words: the `prefix` its custom_lora.json entry gives (`LoRAZoo`'s
/// `Specification.prefix`, which Draw Things only shows), split into words the Create screen
/// turns on or off and puts in front of the prompt a run sends. Pure, so it's tested on its own.
nonisolated enum TriggerWords {
  /// One selected LoRA's words, and whether the engine applies it with the model (and refiner):
  /// it skips a LoRA made for another family, so its words would only steer the prompt.
  struct Source: Equatable {
    var file: String
    var words: [String]
    var applies: Bool
  }

  /// The words in a prefix. Commas separate them, as in the prefixes LoRA authors publish
  /// ("l1r4, woman"); each is trimmed, and a word given twice (in any case) is kept once.
  static func words(fromPrefix prefix: String) -> [String] {
    var seen = Set<String>()
    return prefix.split(separator: ",").compactMap { part in
      let word = part.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
      return word
    }
  }

  /// A JSON prompt (Ideogram's or MOSS Image's layout): text put in front would break it, and its
  /// caption is the place for the words. A FLUX.3 layout never counts: it's a caption then its box
  /// list, which `LayoutPrompt` finds by searching for `[{`, so words in front still parse, even
  /// when the caption is empty and the prompt is only the list. `format` is the model's layout
  /// format, nil for a model that reads none.
  static func isJSON(_ prompt: String, format: LayoutPrompt.Format?) -> Bool {
    guard format != .flux3, let first = prompt.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
    return first == "{" || first == "["
  }

  /// Whether `prompt` has `word` already, in any case, as a whole word: not inside a longer one,
  /// so a LoRA's "art" isn't taken to be in "party".
  static func contains(_ prompt: String, word: String) -> Bool {
    var searchRange = prompt.startIndex..<prompt.endIndex
    while let found = prompt.range(of: word, options: .caseInsensitive, range: searchRange) {
      let before = found.lowerBound == prompt.startIndex ? nil : prompt[prompt.index(before: found.lowerBound)]
      let after = found.upperBound == prompt.endIndex ? nil : prompt[found.upperBound]
      if !(before.map(isWordCharacter) ?? false), !(after.map(isWordCharacter) ?? false) { return true }
      guard found.lowerBound < prompt.endIndex else { break }
      searchRange = prompt.index(after: found.lowerBound)..<prompt.endIndex
    }
    return false
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  /// The words of `source` that are on, lowercased. `choices` holds, for each LoRA file whose words
  /// were set (by the user, an agent, or restoring a step), the words turned on, lowercased. A LoRA
  /// not there has only its first word on: usually one is all it needs, and the rest would
  /// otherwise all have to be turned off by hand.
  static func enabled(_ source: Source, choices: [String: Set<String>]) -> Set<String> {
    choices[source.file] ?? Set(source.words.prefix(1).map { $0.lowercased() })
  }

  static func isOn(_ word: String, of source: Source, choices: [String: Set<String>]) -> Bool {
    enabled(source, choices: choices).contains(word.lowercased())
  }

  /// The words a run puts in front of `prompt`, in LoRA then word order: those turned on, of
  /// LoRAs the engine applies, that the prompt doesn't have yet, each once. None for a JSON prompt.
  static func added(
    to prompt: String, from sources: [Source], choices: [String: Set<String>], format: LayoutPrompt.Format?
  ) -> [String] {
    guard !isJSON(prompt, format: format) else { return [] }
    var seen = Set<String>()
    var words: [String] = []
    for source in sources where source.applies {
      let on = enabled(source, choices: choices)
      for word in source.words where on.contains(word.lowercased()) {
        guard seen.insert(word.lowercased()).inserted, !contains(prompt, word: word) else { continue }
        words.append(word)
      }
    }
    return words
  }

  /// The prompt a run sends: `added` in front of `prompt`, ", "-joined, as trigger words are
  /// usually written.
  static func prompt(
    _ prompt: String, sources: [Source], choices: [String: Set<String>], format: LayoutPrompt.Format?
  ) -> String {
    let words = added(to: prompt, from: sources, choices: choices, format: format)
    guard !words.isEmpty else { return prompt }
    let joined = words.joined(separator: ", ")
    return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? joined : joined + ", " + prompt
  }

  /// A saved prompt taken apart again: what `prompt(_:sources:choices:format:)` put in front comes
  /// off (any of the applied LoRAs' words, in any order and case, each followed by ", " or ending
  /// the prompt; a skipped LoRA's words were never put in, so text matching them is the user's),
  /// and `choices` says, for each LoRA the engine applies, which of its words were on: those taken
  /// off the front or in what's left (on or off, a word the prompt has isn't added, so on keeps it
  /// as it was). Explicit for every such LoRA, so its default doesn't apply. Running the result
  /// again gives the same prompt. A JSON prompt never had words put in, so it comes back as it is, changing nothing.
  static func strip(
    _ saved: String, sources: [Source], format: LayoutPrompt.Format?
  ) -> (prompt: String, choices: [String: Set<String>]) {
    guard !isJSON(saved, format: format) else { return (saved, [:]) }
    // Longest first, so "red hat" comes off before "red".
    let all = Set(sources.filter(\.applies).flatMap { $0.words.map { $0.lowercased() } }).sorted { $0.count > $1.count }
    var rest = Substring(saved)
    var found = Set<String>()
    var removed = true
    while removed {
      removed = false
      for word in all {
        // Anchored and case-insensitive, rather than comparing the first `word.count` characters
        // lowercased: lowercasing can change how many characters there are ("İ").
        guard let match = rest.range(of: word, options: [.caseInsensitive, .anchored]) else { continue }
        let after = rest[match.upperBound...]
        if after.isEmpty {
          rest = after
        } else if after.hasPrefix(", ") {
          rest = after.dropFirst(2)
        } else {
          continue
        }
        found.insert(word)
        removed = true
        break
      }
    }
    let prompt = String(rest)
    var choices: [String: Set<String>] = [:]
    for source in sources where source.applies {
      choices[source.file] = Set(
        source.words.map { $0.lowercased() }.filter { found.contains($0) || contains(prompt, word: $0) })
    }
    return (prompt, choices)
  }
}
