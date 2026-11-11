@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// Where the DiT's weights come from: the published BF16 safetensors (`ReCaVSRCheckpoint`) or
/// the local 8-bit copy (`ReCaVSRQuantizedSource`). Names are the checkpoint's.
nonisolated protocol ReCaVSRWeightSource {
  /// The tensor, float32 on the CPU, in its checkpoint shape.
  func tensor(_ name: String) throws -> Tensor<Float>
  /// Reads layer `layer`'s weights into a compiled, not yet run set of the denoiser's pieces
  /// (`ReCaVSRDenoiser.pieces()`, whose parameters are `slots`).
  func load(_ pieces: [Model], slots: [ReCaVSRDenoiser.Slot], layer: Int) throws
}

nonisolated extension ReCaVSRWeightSource {
  /// The feed-forward's second bias, scaled down by 8 with its input (`ReCaVSRDenoiser.pieces`).
  func scaledDownBias(layer: Int) throws -> Tensor<FloatType> {
    var bias = try tensor("blocks.\(layer).ffn.net.2.bias")
    bias.withUnsafeMutableBytes { raw in
      let values = raw.bindMemory(to: Float.self)
      for i in values.indices { values[i] /= 8 }
    }
    return Tensor<FloatType>(from: bias)
  }
}

nonisolated extension ReCaVSRCheckpoint: ReCaVSRWeightSource {
  func load(_: [Model], slots: [ReCaVSRDenoiser.Slot], layer: Int) throws {
    for slot in slots {
      if slot.name == "ffn.net.2.bias" {
        slot.parameter.copy(from: try scaledDownBias(layer: layer))
        continue
      }
      let tensor = try tensor("blocks.\(layer).\(slot.name)")
      if slot.isFloat {
        slot.parameter.copy(from: tensor)
      } else {
        slot.parameter.copy(from: Tensor<FloatType>(from: tensor))
      }
    }
  }
}

/// The 8-bit copy, open for reading while the denoiser loads. Layers are read into the pieces
/// with `.jit`, so their matrices stay 8-bit and are multiplied that way (as the engine reads
/// its `_i8x.ckpt` models); everything else decodes to float.
nonisolated struct ReCaVSRQuantizedSource: ReCaVSRWeightSource {
  enum Failure: LocalizedError {
    case missing(String)

    var errorDescription: String? {
      switch self {
      case .missing(let name): "The ReCaVSR 8-bit copy has no \(name). Make the copy again."
      }
    }
  }

  let store: DynamicGraph.Store

  func tensor(_ name: String) throws -> Tensor<Float> {
    try autoreleasepool {
      guard let tensor = store.read(name, kind: .CPU, codec: [.ezm7, .i8x]) else { throw Failure.missing(name) }
      return Tensor<Float>(from: tensor)
    }
  }

  func load(_ pieces: [Model], slots: [ReCaVSRDenoiser.Slot], layer: Int) throws {
    for piece in pieces {
      try autoreleasepool {
        try store.read("", model: piece, strict: true, codec: [.jit, .i8x, .ezm7]) { key, _, _, _ in
          guard let name = ReCaVSRDenoiser.checkpointName(key, layer: layer) else { return .fail }
          return .continue(name)
        }
      }
    }
    for slot in slots where slot.name == "ffn.net.2.bias" {
      slot.parameter.copy(from: try scaledDownBias(layer: layer))
    }
  }
}

/// Writes ReCaVSR's 8-bit copy of the DiT, in the style of `MOSSImporter.quantize`: one tensor at
/// a time from the published safetensors into an s4nnc store under the checkpoint's names. The
/// layers' matrices row-wise 8-bit ("8-bit S", `[.i8x, .ezm7]`, as the engine's `_i8x.ckpt`
/// files), the modulation tables and the layers' norms float32, everything else (source projection, embedders, head,
/// vectors) half precision, vectors compressed (ezm7). It writes to a `.part` file and keeps
/// what an interrupted copy wrote, so it resumes; the finished file is renamed into place.
nonisolated enum ReCaVSRQuantizer {
  /// Where the .part records the size of the transformer it's copying.
  static let sourceKey = "__recavsr_source_bytes__"

  /// Whether `name` is a layer matrix the copy stores 8-bit: those the denoiser multiplies by
  /// (`ReCaVSRDenoiser.matrices`) and the cross-attention keys' and values' projections.
  static func isEightBit(_ name: String) -> Bool {
    guard name.hasPrefix("blocks."), name.hasSuffix(".weight") else { return false }
    return (ReCaVSRDenoiser.matrices + ["attn2.to_k", "attn2.to_v"]).contains { name.hasSuffix(".\($0).weight") }
  }

  /// Writes the copy of `files`' transformer, calling `progress` with the fraction done.
  /// Returns false when `shouldContinue` stopped it (what's written is kept for next time).
  static func quantize(
    _ files: ReCaVSRFiles, progress: (Double) -> Void, shouldContinue: () -> Bool
  ) throws -> Bool {
    let source = try ReCaVSRCheckpoint(files.transformer)
    let names = source.names
    let part = files.eightBitTransformer.path + ".part"
    let graph = DynamicGraph()
    // The source's size is recorded in the .part, so a copy started from other weights (a
    // replaced or partly downloaded transformer) starts over instead of resuming.
    let sourceBytes = ((try? FileManager.default.attributesOfItem(atPath: files.transformer.path)[.size] as? Int64) ?? nil) ?? 0
    let marker = Tensor<Int32>([Int32(sourceBytes >> 31), Int32(sourceBytes & 0x7fff_ffff)], .CPU, .C(2))
    if FileManager.default.fileExists(atPath: part) {
      var matches = false
      graph.openStore(part, flags: .readOnly) { store in
        if let recorded = store.read(sourceKey, kind: .CPU) {
          let values = Tensor<Int32>(recorded)
          matches = values.shape == [2] && values[0] == marker[0] && values[1] == marker[1]
        }
      }
      if !matches {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: part + suffix) }
      }
    }
    var failure: Error?
    var finished = true
    graph.openStore(part) { out in
      if out.read(sourceKey, kind: .CPU) == nil { out.write(sourceKey, tensor: marker) }
      let written = Set(out.keys)
      for (index, name) in names.enumerated() {
        guard shouldContinue() else {
          finished = false
          return
        }
        defer { progress(Double(index + 1) / Double(names.count)) }
        guard !written.contains(name) else { continue }
        do {
          try autoreleasepool {
            let tensor = try source.tensor(name)
            // Float32 as the pieces use them: the modulation tables and the layers' norms.
            if name.hasSuffix("scale_shift_table") || (name.hasPrefix("blocks.") && name.contains("norm")) {
              out.write(name, tensor: tensor)
              return
            }
            let half = Tensor<Float16>(from: tensor)
            if isEightBit(name) {
              out.write(name, tensor: half, codec: [.i8x, .ezm7])
            } else if half.shape.filter({ $0 > 1 }).count > 1 {
              out.write(name, tensor: half)
            } else {
              out.write(name, tensor: half, codec: .ezm7)
            }
          }
        } catch {
          failure = error
          return
        }
      }
    }
    if let failure { throw failure }
    guard finished else { return false }
    try? FileManager.default.removeItem(at: files.eightBitTransformer)
    try FileManager.default.moveItem(atPath: part, toPath: files.eightBitTransformer.path)
    return true
  }
}
