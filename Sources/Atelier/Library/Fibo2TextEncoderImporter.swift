@preconcurrency import Diffusion
import Foundation
@preconcurrency import ModelZoo
@preconcurrency import NNC

/// Converts Fibo 2.0's text encoder (Qwen3-VL-4B, text and vision, as Hugging Face's
/// briaai/Fibo-2.0-edit-turbo ships it in `text_encoder/`) into the file an imported Fibo 2.0
/// model names as its text encoder. ModelImporter leaves it out (`inferModelSpecification` names
/// the file but doesn't write it) and Draw Things' download server doesn't have it. This follows
/// `convertFibo2TextEncoder()` in the engine's Apps/ModelConverter/Converter.swift, tensor for
/// tensor.
nonisolated enum Fibo2TextEncoderImporter {
  /// The file Fibo 2.0's specification names as its text encoder
  /// (`ModelImporter.inferModelSpecification`, `case .fibo2`).
  static let file = "fibo_2_qwen_3_vl_4b_f16.ckpt"
  /// The folder Hugging Face's repo keeps it in.
  static let folderName = "text_encoder"

  private static let textLayers = 36
  private static let visionBlocks = 24
  /// A tensor only the text half of Qwen3-VL has, to tell this encoder from other Qwen folders.
  private static let markerKey = "model.language_model.embed_tokens.weight"
  private static let visionMarkerKey = "model.visual.patch_embed.proj.weight"

  enum Error: LocalizedError {
    case notTextEncoder
    case missingTensor(String)

    var errorDescription: String? {
      switch self {
      case .notTextEncoder: "Not Fibo 2.0's text encoder."
      case .missingTensor(let key): "The text encoder is missing the tensor \(key)."
      }
    }
  }

  /// Whether no models folder has the converted text encoder yet.
  static func isMissing(in directories: [URL]) -> Bool {
    !directories.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(file).path) }
  }

  /// The safetensors files of the encoder in `folder`, if it is one: Qwen3-VL with its vision
  /// tower, from the headers.
  static func weights(in folder: URL) -> [URL]? {
    let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension.lowercased() == "safetensors" }
      .sorted { $0.path < $1.path }
    guard !urls.isEmpty else { return nil }
    var keys = Set<String>()
    for url in urls {
      guard let archive = SafeTensors(url: url) else { return nil }
      keys.formUnion(archive.states.keys)
    }
    return keys.contains(markerKey) && keys.contains(visionMarkerKey) ? urls : nil
  }

  /// The encoder to convert with the Fibo 2.0 checkpoint `model`: a `text_encoder` folder beside
  /// it or beside its parent (Hugging Face's layout: `transformer/…` next to `text_encoder/…`; a
  /// link download keeps the joined file at the top of its staging folder, next to it).
  static func sibling(of model: URL) -> URL? {
    let folder = model.deletingLastPathComponent()
    for directory in [folder, folder.deletingLastPathComponent()] {
      let candidate = directory.appendingPathComponent(folderName, isDirectory: true)
      if weights(in: candidate) != nil { return candidate }
    }
    return nil
  }

  /// Writes the converted encoder to `path` (an s4nnc store, FP16). It's written under a temporary
  /// name and moved into place when done, so a failed conversion leaves no half-written file.
  static func convert(_ folder: URL, to path: String, progress: (Float) -> Void) throws {
    guard let urls = weights(in: folder) else { throw Error.notTextEncoder }
    let partial = path + ".part"
    let fileManager = FileManager.default
    try? fileManager.removeItem(atPath: partial)
    do {
      try write(urls, to: partial, progress: progress)
      try? fileManager.removeItem(atPath: path)
      try fileManager.moveItem(atPath: partial, toPath: path)
    } catch {
      try? fileManager.removeItem(atPath: partial)
      throw error
    }
  }

  /// Rows `[head * dim + i]` and `[head * dim + i + dim / 2]` become rows `2i` and `2i + 1` of the
  /// head: Hugging Face rotates the two halves of each head, the engine rotates adjacent pairs.
  /// `values` is a row-major `[rows, columns]` matrix, or a vector (`columns` 1).
  static func interleave(_ values: [Float], rows: Int, headDimension: Int) -> [Float] {
    let columns = values.count / rows
    let half = headDimension / 2
    var result = values
    for row in 0..<rows {
      let head = row / headDimension
      let i = row % headDimension
      let target = head * headDimension + (i < half ? i * 2 : (i - half) * 2 + 1)
      for column in 0..<columns {
        result[target * columns + column] = values[row * columns + column]
      }
    }
    return result
  }

  private static func write(_ urls: [URL], to path: String, progress: (Float) -> Void) throws {
    var sources = [String: (SafeTensors, TensorDescriptor)]()
    for url in urls {
      guard let archive = SafeTensors(url: url) else { throw Error.notTextEncoder }
      for (key, value) in archive.states {
        sources[key] = (archive, value)
      }
    }
    func read(_ key: String) throws -> Tensor<Float> {
      guard let (archive, descriptor) = sources[key] else { throw Error.missingTensor(key) }
      return try archive.with(descriptor) { Tensor<Float>(from: $0).toCPU() }
    }
    func values(_ tensor: Tensor<Float>) -> [Float] {
      let count = tensor.shape.reduce(1, *)
      return tensor.withUnsafeBytes {
        Array(UnsafeBufferPointer(start: $0.baseAddress!.assumingMemoryBound(to: Float.self), count: count))
      }
    }
    func half(_ values: [Float], shape: [Int]) -> Tensor<Float16> {
      precondition(values.count == shape.reduce(1, *))
      return Tensor<Float16>(from: Tensor<Float>(values, kind: .CPU, format: .NCHW, shape: TensorShape(shape)))
    }
    func interleaved(_ tensor: Tensor<Float>, headDimension: Int) -> Tensor<Float16> {
      let shape = Array(tensor.shape)
      return half(interleave(values(tensor), rows: shape[0], headDimension: headDimension), shape: shape)
    }
    let graph = DynamicGraph()
    try graph.openStore(path) { store in
      func write(_ name: String, _ tensor: Tensor<Float>) {
        store.write(name, tensor: Tensor<Float16>(from: tensor))
      }
      try store.withTransaction {
        // Text model: 36 layers, 32 query heads and 8 key / value heads of 128.
        let text = "model.language_model"
        write("__text_model__[t-tok_embeddings-0-0]", try read("\(text).embed_tokens.weight"))
        write("__text_model__[t-norm-0-0]", try read("\(text).norm.weight"))
        for layer in 0..<textLayers {
          let prefix = "\(text).layers.\(layer)"
          store.write(
            "__text_model__[t-q_proj-\(layer)-0]",
            tensor: interleaved(try read("\(prefix).self_attn.q_proj.weight"), headDimension: 128))
          store.write(
            "__text_model__[t-k_proj-\(layer)-0]",
            tensor: interleaved(try read("\(prefix).self_attn.k_proj.weight"), headDimension: 128))
          write("__text_model__[t-v_proj-\(layer)-0]", try read("\(prefix).self_attn.v_proj.weight"))
          write("__text_model__[t-out_proj-\(layer)-0]", try read("\(prefix).self_attn.o_proj.weight"))
          store.write(
            "__text_model__[t-norm_q-\(layer)-0]",
            tensor: interleaved(try read("\(prefix).self_attn.q_norm.weight"), headDimension: 128))
          store.write(
            "__text_model__[t-norm_k-\(layer)-0]",
            tensor: interleaved(try read("\(prefix).self_attn.k_norm.weight"), headDimension: 128))
          write("__text_model__[t-input_layernorm-\(layer)-0]", try read("\(prefix).input_layernorm.weight"))
          write(
            "__text_model__[t-post_attention_layernorm-\(layer)-0]",
            try read("\(prefix).post_attention_layernorm.weight"))
          // The MLP is a nested model named "mlp", so its weights carry the layer in the model part.
          write("__text_model__[t-mlp-\(layer)-mlp_gate_proj-0-0]", try read("\(prefix).mlp.gate_proj.weight"))
          write("__text_model__[t-mlp-\(layer)-mlp_up_proj-0-0]", try read("\(prefix).mlp.up_proj.weight"))
          write("__text_model__[t-mlp-\(layer)-mlp_down_proj-0-0]", try read("\(prefix).mlp.down_proj.weight"))
          progress(Float(layer + 1) / Float(textLayers) * 0.8)
        }
        // Vision tower: 24 blocks, 16 heads of 64, under its Hugging Face names.
        let visual = "model.visual"
        func vision(_ name: String, _ parameter: Int, _ tensor: Tensor<Float16>) {
          store.write("__vision_model__[t-\(name)-0-\(parameter)]", tensor: tensor)
        }
        func visionPair(_ name: String) throws {
          vision(name, 0, Tensor<Float16>(from: try read("\(name).weight")))
          vision(name, 1, Tensor<Float16>(from: try read("\(name).bias")))
        }
        let patchWeight = try read("\(visual).patch_embed.proj.weight")
        vision(
          "\(visual).patch_embed.proj", 0,
          half(values(patchWeight), shape: [patchWeight.shape[0], 3 * 2 * 16 * 16]))
        vision("\(visual).patch_embed.proj", 1, Tensor<Float16>(from: try read("\(visual).patch_embed.proj.bias")))
        write("__vision_model__[t-pos_embed-0-0]", try read("\(visual).pos_embed.weight"))
        for block in 0..<visionBlocks {
          let prefix = "\(visual).blocks.\(block)"
          let qkvWeight = try read("\(prefix).attn.qkv.weight")
          let qkvBias = values(try read("\(prefix).attn.qkv.bias"))
          let columns = qkvWeight.shape[1]
          let weights = values(qkvWeight)
          let width = qkvBias.count / 3
          for (index, projection) in ["q_proj", "k_proj", "v_proj"].enumerated() {
            let rows = (index * width)..<((index + 1) * width)
            var weight = Array(weights[(rows.lowerBound * columns)..<(rows.upperBound * columns)])
            var bias = Array(qkvBias[rows])
            if index < 2 {
              weight = interleave(weight, rows: width, headDimension: 64)
              bias = interleave(bias, rows: width, headDimension: 64)
            }
            vision("\(prefix).attn.\(projection)", 0, half(weight, shape: [width, columns]))
            vision("\(prefix).attn.\(projection)", 1, half(bias, shape: [width]))
          }
          for name in ["attn.proj", "norm1", "norm2", "mlp.linear_fc1", "mlp.linear_fc2"] {
            try visionPair("\(prefix).\(name)")
          }
          progress(0.8 + Float(block + 1) / Float(visionBlocks) * 0.18)
        }
        var mergers = ["\(visual).merger"]
        mergers += (0..<3).map { "\(visual).deepstack_merger_list.\($0)" }
        for merger in mergers {
          for name in ["norm", "linear_fc1", "linear_fc2"] {
            try visionPair("\(merger).\(name)")
          }
        }
        progress(1)
      }
    }
  }
}
