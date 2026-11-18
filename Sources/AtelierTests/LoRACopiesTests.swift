@testable import Atelier
import Foundation
import Testing

/// `ModelLibrary.linkingLoRACopies`: a missing LoRA and the 8-bit copy Draw Things left in its
/// place are shown as one. The indexed version must give exactly what the pairwise one it replaced
/// gave (`reference` below, kept verbatim), and stay fast with hundreds of each.
@Suite(.tags(.smoke))
struct LoRACopiesTests {
  private static let folder = URL(fileURLWithPath: "/tmp/models", isDirectory: true)

  private static func lora(
    _ name: String, _ file: String, prefix: String = "", version: String = "flux1", present: Bool,
    weight: ModelLibrary.Weight? = nil
  ) -> ModelLibrary.LoRA {
    ModelLibrary.LoRA(
      name: name, file: file, prefix: prefix, version: version, size: present ? 1 : nil,
      registry: folder, folder: present ? folder : nil, weight: weight)
  }

  /// The pairwise version this replaced, as it was.
  private static func reference(_ loras: [ModelLibrary.LoRA]) -> [ModelLibrary.LoRA] {
    func normalized(_ text: String) -> String {
      text.lowercased()
        .replacingOccurrences(of: "[^a-z0-9.]+", with: "_", options: .regularExpression)
        .replacingOccurrences(of: "\\.ckpt$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(_lora)?(_(f16|q8p|q6p|q5p|i8x|8_?bit))?_*$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "^_+", with: "", options: .regularExpression)
    }
    func keys(_ lora: ModelLibrary.LoRA) -> Set<String> { [normalized(lora.file), normalized(lora.name)] }
    let present = loras.filter(\.isDownloaded)
    var missing = loras.filter { !$0.isDownloaded }
    var result = present
    for index in result.indices {
      let copy = result[index]
      guard let match = missing.firstIndex(where: { $0.version == copy.version && !keys($0).isDisjoint(with: keys(copy)) }) else { continue }
      if copy.prefix.trimmingCharacters(in: .whitespaces).isEmpty { result[index].prefix = missing[match].prefix }
      if copy.weight == nil { result[index].weight = missing[match].weight }
      if normalized(copy.name) == normalized(copy.file), normalized(copy.name) != copy.name.lowercased() || copy.name.contains("_") {
        result[index].name = missing[match].name
      }
      missing.remove(at: match)
    }
    return result + missing
  }

  @Test func copyTakesTheOriginalsNameAndTriggerWords() {
    let original = Self.lora("Age Slider v1 Krea", "age_slider_v1_krea_lora_f16.ckpt", prefix: "aged", present: false)
    let copy = Self.lora("age_slider_v1_krea_lora_q8p", "age_slider_v1_krea_lora_q8p.ckpt", present: true)
    let linked = ModelLibrary.linkingLoRACopies([original, copy])
    #expect(linked.count == 1)
    #expect(linked[0].file == copy.file)
    #expect(linked[0].name == "Age Slider v1 Krea")
    #expect(linked[0].prefix == "aged")
    #expect(linked == Self.reference([original, copy]))
  }

  @Test func otherFamiliesAndOwnTriggerWordsAreLeftAlone() {
    let original = Self.lora("Style", "style_lora_f16.ckpt", prefix: "old", version: "v1", present: false)
    let copy = Self.lora("Style", "style_lora_q8p.ckpt", prefix: "", version: "flux1", present: true)
    let keeps = Self.lora("Ink", "ink_lora_q8p.ckpt", prefix: "mine", present: true)
    let inkOriginal = Self.lora("Ink", "ink_lora_f16.ckpt", prefix: "theirs", present: false)
    let input = [original, copy, keeps, inkOriginal]
    let linked = ModelLibrary.linkingLoRACopies(input)
    #expect(linked == Self.reference(input))
    #expect(linked.map(\.file) == ["style_lora_q8p.ckpt", "ink_lora_q8p.ckpt", "style_lora_f16.ckpt"])
    #expect(linked[1].prefix == "mine")
  }

  @Test func eachOriginalLinksOnceInListOrder() {
    // Two copies match the same two originals: the first copy takes the first original.
    let input = [
      Self.lora("Dup", "dup_lora_f16.ckpt", prefix: "a", present: false),
      Self.lora("Dup", "dup_lora_q6p.ckpt", prefix: "b", present: false),
      Self.lora("dup_lora_q8p", "dup_lora_q8p.ckpt", present: true),
      Self.lora("dup_8bit", "dup_8bit.ckpt", present: true),
      Self.lora("dup_i8x", "dup_i8x.ckpt", present: true),
    ]
    let linked = ModelLibrary.linkingLoRACopies(input)
    #expect(linked == Self.reference(input))
    #expect(linked.map(\.prefix) == ["a", "b", ""])
  }

  /// A generated set with many near-collisions, compared against the pairwise version.
  @Test func matchesThePairwiseVersionOnAGeneratedSet() throws {
    var seeded = SplitMix(seed: 42)
    let half = try JSONDecoder().decode(ModelLibrary.Weight.self, from: Data(#"{"value": 0.5, "lowerBound": -1, "upperBound": 2}"#.utf8))
    let versions = ["flux1", "sdxl_base_v0.9", "v1"]
    let suffixes = ["_lora_f16.ckpt", "_lora_q8p.ckpt", "_q6p.ckpt", "_8_bit.ckpt", "_lora.ckpt", ".ckpt", "__lora_i8x.ckpt"]
    var input: [ModelLibrary.LoRA] = []
    for index in 0..<800 {
      let stem = "Pack \(Int.random(in: 0..<120, using: &seeded))"
      let fileStem = stem.lowercased().replacingOccurrences(of: " ", with: Bool.random(using: &seeded) ? "_" : "-")
      let file = fileStem + suffixes[Int.random(in: 0..<suffixes.count, using: &seeded)]
      let name = Bool.random(using: &seeded) ? stem : (file as NSString).deletingPathExtension
      let weight = Bool.random(using: &seeded) ? half : nil
      input.append(Self.lora(
        name, "\(index)_" + file, prefix: Bool.random(using: &seeded) ? "trigger \(index)" : " ",
        version: versions[Int.random(in: 0..<versions.count, using: &seeded)], present: Bool.random(using: &seeded), weight: weight))
      // Some without the index, so file keys collide too.
      if index % 3 == 0 {
        input.append(Self.lora(name, file, version: versions[index % 3], present: index % 2 == 0))
      }
    }
    let linked = ModelLibrary.linkingLoRACopies(input)
    #expect(linked == Self.reference(input))
    // The set does exercise linking: plenty of pairs merge, and some names change.
    #expect(input.count - linked.count > 50)
    #expect(Set(linked.map(\.name)) != Set(input.filter(\.isDownloaded).map(\.name)))
  }

  @Test func fiveHundredByFiveHundredIsQuick() {
    var input: [ModelLibrary.LoRA] = []
    for index in 0..<500 {
      input.append(Self.lora("Style \(index)", "style_\(index)_lora_f16.ckpt", prefix: "t\(index)", present: false))
    }
    for index in 0..<500 {
      // Half are copies of a missing original; half match nothing, the slow case pairwise.
      let file = index % 2 == 0 ? "style_\(index)_lora_q8p.ckpt" : "other_\(index)_lora_q8p.ckpt"
      input.append(Self.lora((file as NSString).deletingPathExtension, file, present: true))
    }
    let start = ContinuousClock.now
    let linked = ModelLibrary.linkingLoRACopies(input)
    let elapsed = start.duration(to: .now)
    #expect(linked.count == 750)
    #expect(elapsed < .milliseconds(500), "took \(elapsed)")
  }
}

/// A seeded generator, so the generated set is the same on every run.
private struct SplitMix: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
