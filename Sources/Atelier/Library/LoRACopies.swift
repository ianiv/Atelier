import Foundation

extension ModelLibrary {
  /// Draw Things' 8-bit conversion deletes the original LoRA's file but leaves its custom_lora.json
  /// entry, and the copy's new entry has no trigger words. So a file that's gone and a file that's
  /// here, in the same family with the same name apart from the precision, are one LoRA: it's shown
  /// once, as the copy, with the original's trigger words if it has none. Only in memory: this
  /// file is Draw Things' too, and saving an edit in the LoRAs screen is what writes them down.
  ///
  /// Each LoRA present takes the first missing one (in list order) that matches. The keys are
  /// worked out once per LoRA and the missing ones indexed by family and key, rather than comparing
  /// every pair: with hundreds of each (a heavy Draw Things user's custom_lora.json) the pairwise
  /// version took seconds.
  nonisolated static func linkingLoRACopies(_ loras: [LoRA]) -> [LoRA] {
    let present = loras.filter(\.isDownloaded)
    let missing = loras.filter { !$0.isDownloaded }
    struct Key: Hashable {
      var version: String
      var text: String
    }
    // For each family and key, the missing LoRAs that have it, in list order; `next` skips past
    // ones already taken, which never come back.
    var candidates: [Key: [Int]] = [:]
    for (index, lora) in missing.enumerated() {
      for text in loraCopyKeys(lora) {
        candidates[Key(version: lora.version, text: text), default: []].append(index)
      }
    }
    var next: [Key: Int] = [:]
    var taken = [Bool](repeating: false, count: missing.count)
    func firstUntaken(_ key: Key) -> Int? {
      guard let indices = candidates[key] else { return nil }
      var position = next[key] ?? 0
      while position < indices.count, taken[indices[position]] { position += 1 }
      next[key] = position
      return position < indices.count ? indices[position] : nil
    }
    var result = present
    for index in result.indices {
      let copy = result[index]
      let file = normalizedLoRAName(copy.file)
      let name = normalizedLoRAName(copy.name)
      guard let match = Set([file, name]).compactMap({ firstUntaken(Key(version: copy.version, text: $0)) }).min()
      else { continue }
      let original = missing[match]
      if copy.prefix.trimmingCharacters(in: .whitespaces).isEmpty { result[index].prefix = original.prefix }
      if copy.weight == nil { result[index].weight = original.weight }
      // A name that's only the file name says less than the one its owner chose.
      if name == file, name != copy.name.lowercased() || copy.name.contains("_") {
        result[index].name = original.name
      }
      taken[match] = true
    }
    return result + missing.indices.filter { !taken[$0] }.map { missing[$0] }
  }

  /// What `linkingLoRACopies` matches on: the LoRA's file name and name, normalized.
  nonisolated static func loraCopyKeys(_ lora: LoRA) -> Set<String> {
    [normalizedLoRAName(lora.file), normalizedLoRAName(lora.name)]
  }

  /// A name or file name without what differs between a LoRA and its copy. The copy's name is
  /// usually just its file name ("Age Slider v1 Krea" becomes age_slider_v1_krea_lora_q8p.ckpt).
  nonisolated static func normalizedLoRAName(_ text: String) -> String {
    var text = text.lowercased()
    for (expression, template) in loraNameRules {
      text = expression.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    return text
  }

  /// `normalizedLoRAName`'s replacements, in order, compiled once. The same patterns as
  /// `replacingOccurrences(of:with:options: .regularExpression)` took, which compiled each one
  /// on every call.
  private nonisolated static let loraNameRules: [(NSRegularExpression, String)] = [
    ("[^a-z0-9.]+", "_"),
    ("\\.ckpt$", ""),
    ("(_lora)?(_(f16|q8p|q6p|q5p|i8x|8_?bit))?_*$", ""),
    ("^_+", ""),
  ].map { pattern, template in
    // The patterns are constants; one that doesn't compile is a programming error.
    (try! NSRegularExpression(pattern: pattern), template)
  }
}
