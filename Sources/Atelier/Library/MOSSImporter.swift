import Diffusion
import DiffusionMappings
import Foundation
import ModelZoo
import NNC

/// Converts a MOSS Image checkpoint in OpenMOSS' safetensors layout (what fine-tunes ship) into
/// Draw Things' MOSS weights. ModelImporter can't: it traps on MOSS. The tensor names follow the
/// engine's own weight mappers, `MOSSImage` and `MOSSImageFixed` in
/// SwiftDiffusion/Sources/Models/MOSSImage.swift, and the store keys the official
/// `moss_image_sft_*.ckpt` files use (`__dit__[t-<name>-<layer>-<0 weight, 1 bias>]`).
enum MOSSImporter {
  /// The built-in model whose specification (text encoder, VAE, objective, scales) an import
  /// copies: a fine-tune is a drop-in replacement for it.
  static let baseModel = "moss_image_sft_q8p.ckpt"

  /// Whether `url` is a MOSS Image checkpoint, from its safetensors header.
  static func isMOSS(_ url: URL) -> Bool {
    guard let archive = SafeTensors(url: url) else { return false }
    return isMOSS(Set(archive.states.keys))
  }

  private static func isMOSS(_ keys: Set<String>) -> Bool {
    ["shared_block_modulation.weight", "video_head_modulation.weight", "text_embedder.proj.weight"]
      .allSatisfy(keys.contains)
  }

  enum Error: LocalizedError {
    case notMOSS
    case missingTensors([String])

    var errorDescription: String? {
      switch self {
      case .notMOSS: "Not a MOSS Image checkpoint."
      case .missingTensors(let keys):
        "The checkpoint is missing \(keys.count) MOSS tensors, such as \(keys.prefix(3).joined(separator: ", "))."
      }
    }
  }

  /// Writes the converted weights to `path` (an s4nnc store, FP16 apart from the time
  /// embedding's output layer, which the engine keeps in FP32 as the official files do).
  static func convert(_ url: URL, to path: String, progress: (Float) -> Void) throws {
    guard let archive = SafeTensors(url: url) else { throw Error.notMOSS }
    let states = archive.states
    guard isMOSS(Set(states.keys)) else { throw Error.notMOSS }
    let layers =
      (states.keys.compactMap { key -> Int? in
        guard key.hasPrefix("layers."), key.hasSuffix(".norm1.weight") else { return nil }
        return Int(key.split(separator: ".")[1])
      }.max() ?? -1) + 1
    let mapping = mapping(layers: layers, fusedQKV: states["layers.0.proj.qkv.weight"] != nil)
    let missing = mapping.keys.filter { states[$0] == nil }.sorted()
    guard missing.isEmpty else { throw Error.missingTensors(missing) }
    let graph = DynamicGraph()
    var done = 0
    try graph.openStore(path) { store in
      for (key, element) in mapping.sorted(by: { $0.key < $1.key }) {
        guard let descriptor = states[key] else { continue }
        try archive.with(descriptor) { tensor in
          let renamer: (String) -> String = { "__dit__[\($0)]" }
          if key.hasPrefix("time_embedding.2.") {
            element.write(
              graph: graph, to: store, tensor: Tensor<Float>(from: tensor), format: element.format,
              isDiagonalUp: false, isDiagonalDown: false, renamer: renamer)
          } else {
            element.write(
              graph: graph, to: store, tensor: Tensor<Float16>(from: tensor),
              format: element.format, isDiagonalUp: false, isDiagonalDown: false,
              renamer: renamer)
          }
        }
        done += 1
        progress(Float(done) / Float(mapping.count))
      }
    }
  }

  /// Draw Things' two 8-bit formats for MOSS.
  enum EightBit: CaseIterable {
    /// Palettized ("8-bit", `_q8p.ckpt`): slow to write (k-means per tensor).
    case palettized
    /// Row-wise integer ("8-bit S", `_i8x.ckpt`): quick to write.
    case rowwise

    var fileSuffix: String { self == .palettized ? "q8p.ckpt" : "i8x.ckpt" }
    var title: String { self == .palettized ? "8-bit" : "8-bit S" }
  }

  /// Writes an 8-bit copy of the MOSS weights at `path` to `output`, matching Draw Things' own
  /// files: `palettized` as draw-things' ModelQuantizer makes `moss_image_sft_q8p.ckpt`, `rowwise`
  /// as `moss_image_sft_i8x.ckpt` stores its tensors (row-wise 8-bit matrices, the modulation
  /// matrices palettized). Both keep the embedders and final linear layer in FP16, FP32 tensors
  /// as they are, and compress vectors (ezm7). An interrupted copy resumes: tensors already in
  /// `output` are kept (each write is its own transaction).
  static func quantize(
    _ path: String, to output: String, format: EightBit, progress: (Float) -> Void
  ) {
    let graph = DynamicGraph()
    graph.openStore(
      path, flags: .readOnly, externalStore: TensorData.externalStore(filePath: path)
    ) { store in
      let keys = store.keys
      graph.openStore(output) { out in
        let written = Set(out.keys)
        for (index, key) in keys.enumerated() {
          defer { progress(Float(index + 1) / Float(keys.count)) }
          guard !written.contains(key), let tensor = store.read(key, codec: [.q8p, .i8x, .ezm7, .externalData]) else {
            continue
          }
          if tensor.dataType == .Float32 {
            out.write(key, tensor: tensor)
            continue
          }
          let fp16 = Tensor<Float16>(from: tensor)
          if key.contains("embedder") || key.contains("final_linear") {
            out.write(key, tensor: fp16)
          } else if fp16.shape.filter({ $0 > 1 }).count > 1 {
            let rowwise = format == .rowwise && !key.contains("ada_ln")
            out.write(key, tensor: fp16, codec: rowwise ? [.i8x, .ezm7] : [.q8p, .ezm7])
          } else {
            out.write(key, tensor: fp16, codec: .ezm7)
          }
        }
      }
    }
  }

  /// Source tensor → store names. `fusedQKV`: the image blocks pack q, k and v in one
  /// `proj.qkv` (as some exports do) instead of the separate `proj.q/k/v` the engine maps.
  static func mapping(layers: Int, fusedQKV: Bool) -> [String: ModelWeightElement] {
    let k = 128
    let heads = 3_072 / k
    func name(_ name: String, _ index: Int = 0, bias: Bool = false) -> String {
      "t-\(name)-\(index)-\(bias ? 1 : 0)"
    }
    func norm(_ name: String) -> ModelWeightElement {
      // The q / k norms are reordered like the q / k rows, for the interleaved rotary embedding.
      ModelWeightElement([name], interleavedIndices: [0], numberOfHeads: 1, headDimension: k)
    }
    var mapping = [String: ModelWeightElement]()
    for i in 0..<layers {
      let prefix = "layers.\(i)"
      mapping["\(prefix).norm1.weight"] = [name("x_norm1", i)]
      mapping["\(prefix).norm2.weight"] = [name("x_norm2", i)]
      mapping["\(prefix).q_norm.weight"] = norm(name("x_norm_q", i))
      mapping["\(prefix).k_norm.weight"] = norm(name("x_norm_k", i))
      if fusedQKV {
        mapping["\(prefix).proj.qkv.weight"] = ModelWeightElement(
          [name("x_q", i), name("x_k", i), name("x_v", i)], interleavedIndices: [0, 1],
          numberOfHeads: heads, headDimension: k)
      } else {
        mapping["\(prefix).proj.q.weight"] = ModelWeightElement(
          [name("x_q", i)], interleavedIndices: [0], numberOfHeads: heads, headDimension: k)
        mapping["\(prefix).proj.k.weight"] = ModelWeightElement(
          [name("x_k", i)], interleavedIndices: [0], numberOfHeads: heads, headDimension: k)
        mapping["\(prefix).proj.v.weight"] = [name("x_v", i)]
      }
      mapping["\(prefix).proj.o.weight"] = [name("x_o", i)]
      // The packed projection is the hidden (up) half followed by the gate half.
      mapping["\(prefix).proj.ffn_up_gate.weight"] = [
        name("ffn_up_proj", i), name("ffn_gate_proj", i),
      ]
      mapping["\(prefix).proj.ffn_down.weight"] = [name("ffn_down_proj", i)]
    }
    for i in 0..<2 {
      let prefix = "text_embedder.blocks.\(i)"
      mapping["\(prefix).norm1.weight"] = [name("context_norm1", i)]
      mapping["\(prefix).norm2.weight"] = [name("context_norm2", i)]
      mapping["\(prefix).q_norm.weight"] = norm(name("context_norm_q", i))
      mapping["\(prefix).k_norm.weight"] = norm(name("context_norm_k", i))
      for bias in [false, true] {
        let suffix = bias ? "bias" : "weight"
        mapping["\(prefix).qkv.\(suffix)"] = ModelWeightElement(
          [
            name("context_q", i, bias: bias), name("context_k", i, bias: bias),
            name("context_v", i, bias: bias),
          ], interleavedIndices: [0, 1], numberOfHeads: heads, headDimension: k)
        mapping["\(prefix).proj.\(suffix)"] = [name("context_o", i, bias: bias)]
        mapping["\(prefix).ffn_gate.\(suffix)"] = [name("context_ffn_gate_proj", i, bias: bias)]
        mapping["\(prefix).ffn_up.\(suffix)"] = [name("context_ffn_up_proj", i, bias: bias)]
        mapping["\(prefix).ffn_down.\(suffix)"] = [name("context_ffn_down_proj", i, bias: bias)]
      }
    }
    for bias in [false, true] {
      let suffix = bias ? "bias" : "weight"
      mapping["video_embedder.\(suffix)"] = [name("x_embedder", bias: bias)]
      mapping["text_embedder.proj.\(suffix)"] = [name("context_embedder", bias: bias)]
      mapping["time_embedding.0.\(suffix)"] = [name("time_embedder_0", bias: bias)]
      mapping["time_embedding.2.\(suffix)"] = [name("time_embedder_2", bias: bias)]
      mapping["shared_block_modulation.\(suffix)"] = ModelWeightElement(
        (0..<6).map { name("x_ada_ln_\($0)", bias: bias) })
      // Shift, then scale.
      mapping["video_head_modulation.\(suffix)"] = [
        name("ada_ln_1", bias: bias), name("ada_ln_0", bias: bias),
      ]
    }
    mapping["final_norm_video.weight"] = [name("final_norm")]
    mapping["final_linear_video.weight"] = [name("final_linear")]
    return mapping
  }

  /// The base model's specification with this import's file and name.
  static func specification(file: String, name: String) -> ModelZoo.Specification? {
    guard var specification = ModelZoo.specificationForModel(baseModel) else { return nil }
    specification.file = file
    specification.name = name
    specification.note = nil
    specification.huggingFaceLink = nil
    return specification
  }
}

/// Rewrites a LoRA from the MOSS Image Edit trainer (github.com/Chenkin-x/Moss-Image-Edit, header
/// format "moss-edit-lora") into names LoRAImporter reads. Its tensors are `<module>.lora_A` and
/// `<module>.lora_B` with no `.weight`, so the importer matched none of them; the module names
/// (`layers.N.proj.q`, `proj.ffn_up_gate`, …) already match the engine's MOSS mapper. Each
/// module's alpha, kept in the header's adapter config, is added as a `<module>.alpha` tensor.
enum MOSSEditLoRA {
  /// A converted copy of `url` in a new temporary folder, or nil when `url` isn't in this format.
  /// The caller removes the copy's folder.
  static func convertedCopy(of url: URL) throws -> URL? {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    guard let lengthData = try input.read(upToCount: 8), lengthData.count == 8 else { return nil }
    let headerLength = lengthData.withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
    guard headerLength > 0, headerLength < 100_000_000,
          let headerData = try input.read(upToCount: headerLength), headerData.count == headerLength,
          let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
    else { return nil }
    let suffixes = [".lora_A", ".lora_B"]
    guard header.keys.contains(where: { key in suffixes.contains { key.hasSuffix($0) } }) else {
      return nil
    }
    var alphas: [String: Double] = [:]
    if let metadata = header["__metadata__"] as? [String: String],
       let config = metadata["adapter_config"]?.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
       let modules = object["modules"] as? [String: [String: Any]]
    {
      for (module, info) in modules {
        if let alpha = (info["alpha"] as? NSNumber)?.doubleValue { alphas[module] = alpha }
      }
    }
    var renamed: [String: Any] = [:]
    var dataLength = 0
    for (key, value) in header {
      if key == "__metadata__" {
        renamed[key] = value
        continue
      }
      if let end = (value as? [String: Any])?["data_offsets"] as? [NSNumber], end.count == 2 {
        dataLength = max(dataLength, end[1].intValue)
      }
      renamed[suffixes.contains { key.hasSuffix($0) } ? key + ".weight" : key] = value
    }
    // Alphas go after the original tensor data as FP32 scalars.
    var alphaData = Data()
    for (module, alpha) in alphas.sorted(by: { $0.key < $1.key })
      where header[module + ".lora_A"] != nil && header[module + ".alpha"] == nil
    {
      let start = dataLength + alphaData.count
      withUnsafeBytes(of: Float(alpha).bitPattern.littleEndian) { alphaData.append(contentsOf: $0) }
      renamed[module + ".alpha"] = [
        "dtype": "F32", "shape": [Int](), "data_offsets": [start, start + 4],
      ]
    }
    var newHeader = try JSONSerialization.data(withJSONObject: renamed, options: [.sortedKeys])
    // Pads the header to 8 bytes so the tensor data stays aligned.
    newHeader.append(contentsOf: [UInt8](repeating: 0x20, count: (8 - newHeader.count % 8) % 8))

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("AtelierLoRA-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let output = folder.appendingPathComponent(url.lastPathComponent)
    do {
      FileManager.default.createFile(atPath: output.path, contents: nil)
      let handle = try FileHandle(forWritingTo: output)
      defer { try? handle.close() }
      withUnsafeBytes(of: UInt64(newHeader.count).littleEndian) { handle.write(Data($0)) }
      handle.write(newHeader)
      var remaining = dataLength
      while remaining > 0 {
        guard let chunk = try input.read(upToCount: min(remaining, 64 << 20)), !chunk.isEmpty else {
          throw CocoaError(.fileReadCorruptFile)
        }
        handle.write(chunk)
        remaining -= chunk.count
      }
      handle.write(alphaData)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
    return output
  }
}
