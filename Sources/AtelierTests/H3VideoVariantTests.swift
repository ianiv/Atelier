@testable import Atelier
import Foundation
import Testing

/// `H3VideoVariant.detect`: FL2VA or Ref2VA for a MiniMax H3 video checkpoint, which the engine
/// reads from the file name alone. HyperFlow H3 Flash's partitions drop different blocks, so the
/// weights settle it whatever the file is called.
@Suite(.tags(.smoke))
struct H3VideoVariantTests {
  /// A header with one tensor per block of the 50 except `dropped`, spelled as the HyperFlow
  /// converter writes them, plus `metadata`.
  private static func header(dropping dropped: Set<Int>, prefix: String = "model.diffusion_model.blocks.", metadata: [String: String]? = nil) -> [String: Any] {
    var header: [String: Any] = [:]
    for block in 0..<50 where !dropped.contains(block) {
      header["\(prefix)\(block).attn.q_proj.down.weight"] = ["dtype": "F16", "shape": [512, 5376], "data_offsets": [0, 1]]
    }
    header["model.diffusion_model.token_refiner.blocks.0.attn.qkv_proj.weight"] = ["dtype": "F16", "shape": [16128, 5376], "data_offsets": [0, 1]]
    if let metadata { header["__metadata__"] = metadata }
    return header
  }

  @Test func hyperFlowRef2VAMisnamedAsFL2VA() {
    let detected = H3VideoVariant.detect(header: Self.header(dropping: [9]), fileName: "hyperflow_h3_flash_fl2va.safetensors")
    #expect(detected == .init(variant: .ref2va, evidence: .weights))
  }

  @Test func hyperFlowFL2VAWithNoNameHint() {
    let detected = H3VideoVariant.detect(header: Self.header(dropping: [6, 21, 22]), fileName: "hyperflow.safetensors")
    #expect(detected == .init(variant: .fl2va, evidence: .weights))
  }

  @Test func diffusersBlockSpelling() {
    let header = Self.header(dropping: [9], prefix: "transformer_blocks.")
    #expect(H3VideoVariant.detect(header: header, fileName: "x.safetensors")?.variant == .ref2va)
  }

  @Test func converterMetadataWhenBlocksDontSay() {
    // Stock block set (nothing missing) but the converter's metadata names the partition.
    let header = Self.header(dropping: [], metadata: ["dropped_blocks": "[9]"])
    #expect(H3VideoVariant.detect(header: header, fileName: "x.safetensors") == .init(variant: .ref2va, evidence: .weights))
  }

  @Test func ggufSourceNameBeforeFileName() {
    let header = Self.header(dropping: [], metadata: ["source": "Ref2VA-Q8_0.gguf"])
    #expect(H3VideoVariant.detect(header: header, fileName: "h3_fl2va.safetensors") == .init(variant: .ref2va, evidence: .name))
  }

  @Test func stockFilesGoByName() {
    let stock = Self.header(dropping: [])
    #expect(H3VideoVariant.detect(header: stock, fileName: "MiniMax_H3_Ref2VA.safetensors") == .init(variant: .ref2va, evidence: .name))
    #expect(H3VideoVariant.detect(header: stock, fileName: "minimax_h3_fl2va.safetensors") == .init(variant: .fl2va, evidence: .name))
    #expect(H3VideoVariant.detect(header: stock, fileName: "minimax_h3.safetensors") == nil)
    #expect(H3VideoVariant.detect(header: nil, fileName: "minimax_h3.ckpt") == nil)
  }

  @Test func otherDroppedBlocksDontGuess() {
    #expect(H3VideoVariant.detect(header: Self.header(dropping: [3]), fileName: "x.safetensors") == nil)
  }
}
