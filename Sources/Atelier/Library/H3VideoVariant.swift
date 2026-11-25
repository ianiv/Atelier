import Foundation

/// Which MiniMax H3 video model a checkpoint is: FL2VA (first and last frame) or Ref2VA (reference
/// images). The engine's `ModelImporter.import` tells them apart by file name alone (a name without
/// `ref2va` is FL2VA), since stock FL2VA and Ref2VA checkpoints have the same tensors. A
/// misnamed file then imports as the wrong one, so the import sheet decides first (`detect`) and
/// asks when nothing settles it, and `ModelLibrary.convert` sets the result on the specification.
nonisolated enum H3VideoVariant: String, CaseIterable, Sendable {
  case fl2va
  case ref2va

  var title: String {
    switch self {
    case .fl2va: "FL2VA (first and last frame)"
    case .ref2va: "Ref2VA (reference images)"
    }
  }

  /// What a detection was based on, for the sheet to say.
  enum Evidence: Equatable, Sendable {
    /// HyperFlow H3 Flash's dropped blocks, from the weights or the converter's metadata.
    case weights
    /// `ref2va` or `fl2va` in the file's name, or in the GGUF name the converter recorded.
    case name
  }

  struct Detection: Equatable, Sendable {
    var variant: H3VideoVariant
    var evidence: Evidence
  }

  /// The blocks of the 50 in MiniMax H3 that each HyperFlow H3 Flash partition drops (its
  /// `config.json` `dropped_blocks`; `DEFAULT_DROPPED` in the fork's
  /// `Scripts/hyperflow/hyperflow_gguf_to_safetensors.py`, which restores the original indices).
  static let hyperFlowDroppedBlocks: [H3VideoVariant: Set<Int>] = [.fl2va: [6, 21, 22], .ref2va: [9]]
  static let blockCount = 50

  /// The variant of the checkpoint named `fileName` with safetensors `header` (nil for a file that
  /// isn't safetensors), or nil when nothing says. The weights come first, since they can't be
  /// misnamed; then the converter's metadata; then the name, as the engine reads it.
  static func detect(header: [String: Any]?, fileName: String) -> Detection? {
    let metadata = header?["__metadata__"] as? [String: Any]
    if let header, let variant = fromDroppedBlocks(missingBlocks(header)) { return Detection(variant: variant, evidence: .weights) }
    if let dropped = metadata?["dropped_blocks"] as? String,
       let list = try? JSONSerialization.jsonObject(with: Data(dropped.utf8)) as? [Int],
       let variant = fromDroppedBlocks(Set(list))
    {
      return Detection(variant: variant, evidence: .weights)
    }
    if let source = metadata?["source"] as? String, let variant = fromName(source) { return Detection(variant: variant, evidence: .name) }
    if let variant = fromName(fileName) { return Detection(variant: variant, evidence: .name) }
    return nil
  }

  /// The variant whose file name says it. Ref2VA is checked first, as the engine does.
  static func fromName(_ name: String) -> H3VideoVariant? {
    let name = name.lowercased()
    if name.contains("ref2va") { return .ref2va }
    if name.contains("fl2va") { return .fl2va }
    return nil
  }

  private static func fromDroppedBlocks(_ dropped: Set<Int>) -> H3VideoVariant? {
    hyperFlowDroppedBlocks.first { $0.value == dropped }?.key
  }

  /// The block indices below `blockCount` with no tensors in `header`, with the prefixes and block
  /// spellings the engine's `MiniMaxH3LayoutFromStateDict` accepts. Empty for a file with no blocks.
  static func missingBlocks(_ header: [String: Any]) -> Set<Int> {
    var present = Set<Int>()
    for key in header.keys where key != "__metadata__" {
      var name = Substring(key)
      for prefix in ["model.diffusion_model.", "model."] where name.hasPrefix(prefix) {
        name = name.dropFirst(prefix.count)
        break
      }
      for prefix in ["blocks.", "transformer_blocks."] where name.hasPrefix(prefix) {
        let rest = name.dropFirst(prefix.count)
        if let dot = rest.firstIndex(of: "."), let index = Int(rest[..<dot]) { present.insert(index) }
        break
      }
    }
    guard !present.isEmpty else { return [] }
    return Set(0..<blockCount).subtracting(present)
  }
}
