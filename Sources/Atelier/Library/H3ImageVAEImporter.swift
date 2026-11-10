@preconcurrency import Diffusion
import Foundation
@preconcurrency import ModelZoo
@preconcurrency import NNC

/// Converts the MiniMax H3 Image VAE as ComfyUI ships it (`minimax_h3_image_vae_fp16.safetensors`,
/// in Hugging Face's Comfy-Org/MiniMax-H3-Image `vae/` folder) into the file an imported MiniMax H3
/// Image model names as its autoencoder. ModelImporter can't, and Draw Things' download server
/// doesn't have it. This follows `convertMiniMaxH3ImageVAE()` in the engine's
/// Apps/ModelConverter/Converter.swift, tensor for tensor: the encoder is the H3 video encoder
/// (`MiniMaxH3VideoEncoder`, names `__video_encoder__[t-…]`, NCHW) and the decoder is
/// `MiniMaxH3ImageDecoder`'s 24-layer, 1,024-wide ViT (`__video_decoder__[t-…]`, NHWC).
nonisolated enum H3ImageVAEImporter {
  /// The file MiniMax H3 Image's specification names as its autoencoder.
  static let file = "minimax_h3_image_vae_f16.ckpt"

  private static let hiddenSize = 1_024
  private static let layers = 24

  enum Error: LocalizedError {
    case notVAE
    case missingTensor(String)

    var errorDescription: String? {
      switch self {
      case .notVAE: "Not the MiniMax H3 Image VAE."
      case .missingTensor(let key): "The VAE is missing the tensor \(key)."
      }
    }
  }

  /// Whether `url` is the MiniMax H3 Image VAE, from its safetensors header. The decoder's width
  /// and depth tell it from MiniMax H3's video VAE, which shares some names.
  static func isVAE(_ url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "safetensors", let archive = SafeTensors(url: url)
    else { return false }
    let states = archive.states
    guard
      ["decoder.transformer_blocks.0.attn.to_qkv.weight", "encoder.conv_in.weight",
       "post_quant_conv.weight"].allSatisfy({ states[$0] != nil }),
      states["decoder.transformer_blocks.\(layers - 1).attn.to_qkv.weight"] != nil,
      states["decoder.transformer_blocks.\(layers).attn.to_qkv.weight"] == nil,
      let embedder = states["decoder.x_embedder.weight"], embedder.shape.first == hiddenSize
    else { return false }
    return true
  }

  /// A VAE to pick up with `model`: a `.safetensors` that passes `isVAE` in the model file's
  /// folder, or in a `vae` folder beside it or beside its parent (Hugging Face's layout:
  /// `diffusion_models/…` next to `vae/…`).
  static func sibling(of model: URL) -> URL? {
    let folder = model.deletingLastPathComponent()
    let candidates = [
      folder, folder.appendingPathComponent("vae", isDirectory: true),
      folder.deletingLastPathComponent().appendingPathComponent("vae", isDirectory: true),
    ]
    for directory in candidates {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      for name in names.sorted() where name.lowercased().hasSuffix(".safetensors") {
        let url = directory.appendingPathComponent(name)
        if url != model, isVAE(url) { return url }
      }
    }
    return nil
  }

  /// Writes the converted VAE to `path` (an s4nnc store, FP16). It's written under a temporary
  /// name and moved into place when done, so a failed conversion leaves no half-written file.
  static func convert(_ url: URL, to path: String, progress: (Float) -> Void) throws {
    guard let archive = SafeTensors(url: url) else { throw Error.notVAE }
    let partial = path + ".part"
    let fileManager = FileManager.default
    try? fileManager.removeItem(atPath: partial)
    do {
      try write(archive, to: partial, progress: progress)
      try? fileManager.removeItem(atPath: path)
      try fileManager.moveItem(atPath: partial, toPath: path)
    } catch {
      try? fileManager.removeItem(atPath: partial)
      throw error
    }
  }

  private static func write(_ archive: SafeTensors, to path: String, progress: (Float) -> Void) throws {
    func read(_ key: String) throws -> Tensor<Float> {
      guard let descriptor = archive.states[key] else { throw Error.missingTensor(key) }
      return try archive.with(descriptor) { Tensor<Float>(from: $0).toCPU() }
    }
    func values(_ tensor: Tensor<Float>) -> [Float] {
      let count = tensor.shape.reduce(1, *)
      return tensor.withUnsafeBytes {
        Array(UnsafeBufferPointer(
          start: $0.baseAddress!.assumingMemoryBound(to: Float.self), count: count))
      }
    }
    func tensor(_ values: [Float], format: TensorFormat, shape: [Int]) -> Tensor<Float16> {
      precondition(values.count == shape.reduce(1, *))
      return Tensor<Float16>(
        from: Tensor<Float>(values, kind: .CPU, format: format, shape: TensorShape(shape)))
    }
    // Rows of a [rows, columns] matrix (or a vector), with the first 32 rows of every 64-row head
    // interleaved: rows i and i + 16 become rows 2i and 2i + 1. The reference rotates the two
    // halves of those channels, the engine rotates adjacent pairs.
    func interleave(_ values: [Float], rows: Int) -> [Float] {
      let columns = values.count / rows
      var result = values
      for row in 0..<rows {
        let head = row / 64
        let i = row % 64
        guard i < 32 else { continue }
        let target = head * 64 + (i < 16 ? i * 2 : (i - 16) * 2 + 1)
        for column in 0..<columns {
          result[target * columns + column] = values[row * columns + column]
        }
      }
      return result
    }
    let hiddenSize = hiddenSize
    let graph = DynamicGraph()
    try graph.openStore(path) { store in
      try store.withTransaction {
        // Encoder: causal 3D convolutions and group norms, named by order of appearance.
        func encoder(_ name: String, _ index: Int, _ key: String, norm: Bool = false) throws {
          for (parameter, suffix) in ["weight", "bias"].enumerated() {
            let source = try read("\(key).\(suffix)")
            var shape = Array(source.shape)
            if norm {
              shape = [1, shape[0], 1, 1]
            }
            store.write(
              "__video_encoder__[t-\(name)-\(index)-\(parameter)]",
              tensor: tensor(values(source), format: .NCHW, shape: shape))
          }
        }
        try encoder("conv_in", 0, "encoder.conv_in")
        var shortcuts = 0
        for level in 0..<6 {
          for block in 0..<2 {
            let prefix = "encoder.down.\(level).block.\(block)"
            let index = level * 2 + block
            try encoder("norm1", index, "\(prefix).norm1", norm: true)
            try encoder("conv1", index, "\(prefix).conv1")
            try encoder("norm2", index, "\(prefix).norm2", norm: true)
            try encoder("conv2", index, "\(prefix).conv2")
            if archive.states["\(prefix).nin_shortcut.weight"] != nil {
              try encoder("nin_shortcut", shortcuts, "\(prefix).nin_shortcut")
              shortcuts += 1
            }
          }
          if level < 4 {
            try encoder("downsample_\(level)", 0, "encoder.down.\(level).downsample.conv")
          }
        }
        try encoder("norm_out", 0, "encoder.norm_out", norm: true)
        try encoder("conv_out", 0, "encoder.conv_out")
        try encoder("quant_conv", 0, "quant_conv")
        progress(0.1)
        // Decoder: a 24-layer, 1,024-wide 2D ViT.
        func decoder(_ name: String, _ index: Int, _ parameter: Int, _ values: [Float], shape: [Int]) {
          store.write(
            "__video_decoder__[t-\(name)-\(index)-\(parameter)]",
            tensor: tensor(values, format: .NHWC, shape: shape))
        }
        func dense(_ name: String, _ index: Int, _ key: String) throws {
          let weight = try read("\(key).weight")
          let bias = try read("\(key).bias")
          decoder(name, index, 0, values(weight), shape: [weight.shape[0], weight.shape[1]])
          decoder(name, index, 1, values(bias), shape: [bias.shape[0]])
        }
        try dense("post_quant_conv", 0, "post_quant_conv")
        try dense("decoder_proj_in", 0, "decoder.x_embedder")
        try dense("decoder_proj_out", 0, "decoder.proj_out")
        decoder(
          "decoder_norm_out", 0, 0, values(try read("decoder.norm_out.weight")),
          shape: [1, 1, hiddenSize])
        decoder(
          "decoder_norm_out", 0, 1, values(try read("decoder.norm_out.bias")),
          shape: [1, 1, hiddenSize])
        decoder(
          "register_tokens", 0, 0, values(try read("decoder.register_tokens")),
          shape: [1, 4, hiddenSize])
        for layer in 0..<layers {
          let prefix = "decoder.transformer_blocks.\(layer)"
          let qkvWeight = values(try read("\(prefix).attn.to_qkv.weight"))
          let qkvBias = values(try read("\(prefix).attn.to_qkv.bias"))
          for (index, projection) in ["to_q", "to_k", "to_v"].enumerated() {
            // The reference views the output as [heads, 3 * 64] and chunks it, so each head's
            // query, key and value rows sit together.
            var weight = [Float]()
            var bias = [Float]()
            weight.reserveCapacity(hiddenSize * hiddenSize)
            for head in 0..<(hiddenSize / 64) {
              let row = head * 192 + index * 64
              weight.append(contentsOf: qkvWeight[(row * hiddenSize)..<((row + 64) * hiddenSize)])
              bias.append(contentsOf: qkvBias[row..<(row + 64)])
            }
            if index < 2 {
              weight = interleave(weight, rows: hiddenSize)
              bias = interleave(bias, rows: hiddenSize)
            }
            decoder(projection, layer, 0, weight, shape: [hiddenSize, hiddenSize])
            decoder(projection, layer, 1, bias, shape: [hiddenSize])
          }
          try dense("to_out", layer, "\(prefix).attn.to_out")
          // The feed-forward's first projection is [gate; up].
          let inner = 4 * hiddenSize
          let w1Weight = values(try read("\(prefix).ff.w1.weight"))
          let w1Bias = values(try read("\(prefix).ff.w1.bias"))
          decoder(
            "ff_gate", layer, 0, Array(w1Weight[0..<(inner * hiddenSize)]),
            shape: [inner, hiddenSize])
          decoder("ff_gate", layer, 1, Array(w1Bias[0..<inner]), shape: [inner])
          decoder(
            "ff_up", layer, 0, Array(w1Weight[(inner * hiddenSize)...]), shape: [inner, hiddenSize])
          decoder("ff_up", layer, 1, Array(w1Bias[inner...]), shape: [inner])
          try dense("ff_down", layer, "\(prefix).ff.w2")
          for name in ["norm1", "norm2", "scale1", "scale2"] {
            decoder(
              name, layer, 0,
              values(try read("\(prefix).\(name)\(name.hasPrefix("norm") ? ".weight" : "")")),
              shape: [1, 1, hiddenSize])
          }
          progress(0.1 + 0.9 * Float(layer + 1) / Float(layers))
        }
      }
    }
  }
}
