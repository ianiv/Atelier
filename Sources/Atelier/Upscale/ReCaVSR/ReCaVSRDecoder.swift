@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// ReCaVSR's FlashDecoder-S (models/flashdecoder/flashdecoder_wan22.py, driven as
/// runtime/flashdecoder.py drives it): a small streaming transformer that turns each latent
/// frame of the DiT into 4 RGB frames at 16× its size (the stream's first into 1), reading the
/// source frames it covers. Runs in float32 but for attention (half precision with float32
/// sums): it's small next to the DiT, and that leaves the DiT nearly the only source of rounding.
///
/// Per latent: the latent (un-normalized, `x0 * std + mean`) projected to 512 plus the source's
/// early features, 12 backbone blocks attending this latent and the one before, a temporal
/// projection to 4 frames plus the source's late features, 2 refinement blocks attending these
/// 4 frames and the 4 before, then a projection to 16×16 pixels per token. Attention is grouped
/// (8 query heads, 2 key/value heads), local (±12 tokens, not clamped at the edges) and keeps
/// keys normed but unrotated in the reference; here they're kept rotated at their absolute
/// frame, since only differences of positions reach attention.
final nonisolated class ReCaVSRDecoder {
  static let dim = 512
  static let heads = 8
  static let kvHeads = 2
  static let headDimension = 64
  static let hidden = 2048
  static let backboneDepth = 12
  static let refinementDepth = 2
  /// The spatial window, ±12 tokens (flashdecoder_config.json `spatial_window_size`).
  static let window = 24

  let latentHeight: Int
  let latentWidth: Int
  var tokens: Int { latentHeight * latentWidth }
  private let graph: DynamicGraph
  /// The source path (flashdecoder_wan22.py:703-724): lr_stem per frame, then early (4 frames
  /// grouped, channel f * 48 + c) and late (per frame) projections.
  private let stem: Model
  private let early: Model
  private let late: Model
  /// latent_projection, plus the early features.
  private let input: Model
  private let temporal: Model
  private let spatial: Model
  /// A block before attention (norm, q/k/v, k/v norms) and after (output, SwiGLU), compiled
  /// once for the backbone (1 frame) and once for the refinement (4), each block's weights
  /// copied in before it runs: one set of activations rather than 14.
  private var templates: [(pre: Model, post: Model, slots: [Model.Parameters])] = []
  private var blockWeights: [[AnyTensor]] = []
  private var blockCount: Int { Self.backboneDepth + Self.refinementDepth }
  /// Per block, the keys (rotated) and values of the frames it keeps: the backbone's last latent,
  /// the refinement's last 4 frames. `[1, n * tokens, 2, 64]`.
  private var caches: [(keys: DynamicGraph.Tensor<Float>, values: DynamicGraph.Tensor<Float>)?] = []
  /// Latents decoded so far in the stream.
  private(set) var frameIndex = 0
  private let attention: ReCaVSRLocalAttention
  private let mean: DynamicGraph.Tensor<Float>
  private let std: DynamicGraph.Tensor<Float>

  init(graph: DynamicGraph, checkpoint: ReCaVSRCheckpoint, latentHeight: Int, latentWidth: Int) throws {
    self.graph = graph
    self.latentHeight = latentHeight
    self.latentWidth = latentWidth
    let n = latentHeight * latentWidth
    let D = Self.dim
    var loaders: [(Model.Parameters, String)] = []
    func dense(_ count: Int, _ name: String, bias: Bool = true) -> Dense {
      let layer = Dense(count: count, noBias: !bias, name: name)
      loaders.append((layer.weight, "\(name).weight"))
      if bias { loaders.append((layer.bias, "\(name).bias")) }
      return layer
    }
    func rmsNorm(_ name: String, axis: Int) -> RMSNorm {
      let norm = RMSNorm(epsilon: 1e-5, axis: [axis], name: name)
      loaders.append((norm.weight, "\(name).weight"))
      return norm
    }
    do {
      let x = Input()
      stem = Model([x], [dense(48, "lr_stem")(x)])
      let grouped = Input()
      early = Model([grouped], [dense(D, "lr_early_projection", bias: false)(grouped)])
      let frames = Input()
      late = Model([frames], [dense(D, "lr_late_projection", bias: false)(frames)])
      let latent = Input()
      let earlyFeatures = Input()
      input = Model([latent, earlyFeatures], [dense(D, "latent_projection")(latent) + earlyFeatures])
      let backbone = Input()
      temporal = Model([backbone], [dense(4 * D, "temporal_projection")(backbone)])
      let refined = Input()
      let spatial0 = dense(Self.hidden, "spatial_projection.0")
      let spatial2 = dense(768, "spatial_projection.2")
      spatial = Model([refined], [spatial2(spatial0(refined).swish())])
    }
    var templateNames: [[String]] = []
    for frames in [1, 4] {
      var slots: [(Model.Parameters, String)] = []
      func blockDense(_ count: Int, _ name: String) -> Dense {
        let layer = Dense(count: count, name: name)
        slots.append((layer.weight, "\(name).weight"))
        slots.append((layer.bias, "\(name).bias"))
        return layer
      }
      func blockNorm(_ name: String, axis: Int) -> RMSNorm {
        let norm = RMSNorm(epsilon: 1e-5, axis: [axis], name: name)
        slots.append((norm.weight, "\(name).weight"))
        return norm
      }
      let x = Input()
      let normed = blockNorm("attention_norm", axis: 1)(x)
      let q = blockDense(D, "attention.query")(normed).reshaped([1, frames * n, Self.heads, Self.headDimension])
      let k = blockNorm("attention.key_norm", axis: 3)(
        blockDense(Self.kvHeads * Self.headDimension, "attention.key")(normed)
          .reshaped([1, frames * n, Self.kvHeads, Self.headDimension]))
      let v = blockNorm("attention.value_norm", axis: 3)(
        blockDense(Self.kvHeads * Self.headDimension, "attention.value")(normed)
          .reshaped([1, frames * n, Self.kvHeads, Self.headDimension]))
      let pre = Model([x], [q, k, v])
      let residual = Input()
      let attended = Input()
      var out = residual + blockDense(D, "attention.output")(attended)
      let ffn = blockNorm("feed_forward_norm", axis: 1)(out)
      let gate = blockDense(Self.hidden, "feed_forward.gate")(ffn)
      let up = blockDense(Self.hidden, "feed_forward.up")(ffn)
      out = out + blockDense(D, "feed_forward.down")(gate.swish() .* up)
      templates.append((pre, Model([residual, attended], [out]), slots.map(\.0)))
      templateNames.append(slots.map(\.1))
    }

    func zeros(_ shape: TensorShape) -> DynamicGraph.Tensor<Float> {
      let tensor = graph.variable(.GPU(0), format: .NHWC, shape: shape, of: Float.self)
      tensor.full(0)
      return tensor
    }
    stem.compile(inputs: zeros([4 * n, 768]))
    early.compile(inputs: zeros([n, 192]))
    late.compile(inputs: zeros([4 * n, 48]))
    input.compile(inputs: zeros([n, 48]), zeros([n, D]))
    temporal.compile(inputs: zeros([n, D]))
    spatial.compile(inputs: zeros([4 * n, D]))
    for (template, rows) in zip(templates, [n, 4 * n]) {
      template.pre.compile(inputs: zeros([rows, D]))
      template.post.compile(inputs: zeros([rows, D]), zeros([rows, D]))
    }
    for (parameters, name) in loaders {
      parameters.copy(from: try checkpoint.tensor(name))
    }
    for index in 0..<(Self.backboneDepth + Self.refinementDepth) {
      let prefix =
        index < Self.backboneDepth
          ? "backbone.blocks.\(index)" : "temporal_refinement.blocks.\(index - Self.backboneDepth)"
      blockWeights.append(
        try templateNames[index < Self.backboneDepth ? 0 : 1].map { try checkpoint.tensor("\(prefix).\($0)").toGPU(0) })
    }
    attention = ReCaVSRLocalAttention(
      graph: graph, gridHeight: latentHeight, gridWidth: latentWidth, windowHeight: Self.window,
      windowWidth: Self.window, mode: .relative, tileHeight: 8, tileWidth: 8, heads: Self.heads,
      headDimension: Self.headDimension)
    mean = graph.variable(Tensor<Float>(ReCaVSRConfig.latentMean, .CPU, .WC(1, 48)).toGPU(0))
    std = graph.variable(Tensor<Float>(ReCaVSRConfig.latentStd, .CPU, .WC(1, 48)).toGPU(0))
    reset()
  }

  /// Back to the start of a stream.
  func reset() {
    caches = Array(repeating: nil, count: blockCount)
    frameIndex = 0
  }

  /// RoPE for `frames` frames from absolute frame `start`, `[1, frames * tokens, 1, 64]`: 8 pairs
  /// for time, 12 for rows, 12 for columns, interleaved; float32 frequencies and angles
  /// (`_RotaryEmbedding3D`, flashdecoder_wan22.py:158-246).
  private func rotary(start: Int, frames: Int) -> DynamicGraph.Tensor<Float> {
    let h = latentHeight, w = latentWidth
    let HD = Self.headDimension
    var tensor = Tensor<Float>(.CPU, .NHWC(1, frames * h * w, 1, HD))
    let frequencies = [16, 24, 24].map { dimension in
      (0..<(dimension / 2)).map { i in 1 / powf(10_000, Float(2 * i) / Float(dimension)) }
    }
    tensor.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: Float.self)
      for f in 0..<frames {
        for y in 0..<h {
          for x in 0..<w {
            let token = (f * h + y) * w + x
            var pair = 0
            for (axis, position) in [start + f, y, x].enumerated() {
              for frequency in frequencies[axis] {
                let angle = Float(position) * frequency
                out[token * HD + pair * 2] = cos(angle)
                out[token * HD + pair * 2 + 1] = sin(angle)
                pair += 1
              }
            }
          }
        }
      }
    }
    return graph.variable(tensor.toGPU(0))
  }

  /// The 2 key/value heads spread to the 8 query heads (query head h reads kv head h / 4).
  private static func expanded(_ x: DynamicGraph.Tensor<Float>) -> DynamicGraph.Tensor<Float> {
    let rows = x.shape[1]
    let grouped = x.reshaped(.NHWC(rows, kvHeads, 1, headDimension))
    return Functional.concat(axis: 2, grouped, grouped, grouped, grouped)
      .reshaped(.NHWC(1, rows, heads, headDimension))
  }

  private func run(
    _ index: Int, _ x: DynamicGraph.Tensor<Float>, frames: Int, keep: Int,
    queryRot: DynamicGraph.Tensor<Float>
  ) -> DynamicGraph.Tensor<Float> {
    let n = tokens
    let template = templates[index < Self.backboneDepth ? 0 : 1]
    for (slot, weight) in zip(template.slots, blockWeights[index]) { slot.copy(from: weight) }
    let qkv = template.pre(inputs: x).map { $0.as(of: Float.self) }
    let q = Functional.cmul(left: qkv[0], right: queryRot)
    let k = Functional.cmul(left: qkv[1], right: queryRot)
    let v = qkv[2]
    var keyPlanes: [DynamicGraph.Tensor<Float>] = []
    var valuePlanes: [DynamicGraph.Tensor<Float>] = []
    if let cache = caches[index] {
      keyPlanes.append(cache.keys)
      valuePlanes.append(cache.values)
    }
    keyPlanes.append(k)
    valuePlanes.append(v)
    let allKeys = concatenated(keyPlanes, axis: 1)
    let allValues = concatenated(valuePlanes, axis: 1)
    // Keep the newest `keep` frames (flashdecoder_wan22.py:401-454).
    let total = allKeys.shape[1] / n
    let from = max(0, total - keep) * n
    caches[index] = (
      allKeys[0..<1, from..<(total * n), 0..<Self.kvHeads, 0..<Self.headDimension].copied(),
      allValues[0..<1, from..<(total * n), 0..<Self.kvHeads, 0..<Self.headDimension].copied()
    )
    Profile.mark("decoder-pre", wait: allValues)
    // Attention in half precision (float32 intermediates): its gathered keys and masks are the
    // decoder's largest tensors, and the output stays far inside the reference check's bounds.
    let attended = DynamicGraph.Tensor<Float>(
      from: attention(
        queries: DynamicGraph.Tensor<FloatType>(from: q),
        keys: [DynamicGraph.Tensor<FloatType>(from: Self.expanded(allKeys))],
        values: [DynamicGraph.Tensor<FloatType>(from: Self.expanded(allValues))], frames: frames))
    Profile.mark("decoder-attention", wait: attended)
    let out = template.post(inputs: x, attended.reshaped(.WC(frames * n, Self.dim)))[0].as(of: Float.self)
    Profile.mark("decoder-post", wait: out)
    return out
  }

  /// Decodes the stream's next latent `[1, h, w, 48]` (the DiT's clean latent, normalized) with
  /// the source frames it covers (`[1 or 4, 16h, 16w, 3]` in [-1, 1]: 1 for the stream's first
  /// latent, 4 after). Returns its RGB frames `[1 or 4, 16h, 16w, 3]`, clamped to [-1, 1].
  func decode(latent: DynamicGraph.Tensor<Float>, source: DynamicGraph.Tensor<Float>) -> DynamicGraph.Tensor<Float> {
    let h = latentHeight, w = latentWidth, n = tokens
    let first = frameIndex == 0
    let sourceFrames = source.shape[0]
    precondition(sourceFrames == (first ? 1 : 4))
    // Source features: unshuffled, stem, the first frame repeated to 4 on the first latent.
    let unshuffled = source.reshaped(format: .NHWC, shape: [sourceFrames, h, 16, w, 16, 3])
      .permuted(0, 1, 3, 5, 2, 4).copied().reshaped(.WC(sourceFrames * n, 768))
    let packed = first ? concatenated(Array(repeating: unshuffled, count: 4)) : unshuffled
    let features = stem(inputs: packed)[0].as(of: Float.self)
    let grouped = features.reshaped(.NHWC(4, h, w, 48)).permuted(1, 2, 0, 3).copied().reshaped(.WC(n, 192))
    let earlyFeatures = early(inputs: grouped)[0].as(of: Float.self)
    let lateFeatures = late(inputs: features)[0].as(of: Float.self)

    let raw = latent.reshaped(.WC(n, 48)) .* std + mean
    var x = input(inputs: raw, earlyFeatures)[0].as(of: Float.self)
    let backboneRot = rotary(start: frameIndex, frames: 1)
    for index in 0..<Self.backboneDepth {
      x = run(index, x, frames: 1, keep: 1, queryRot: backboneRot)
    }
    // To 4 frames: column f * 512 + d.
    x = temporal(inputs: x)[0].as(of: Float.self).reshaped(.NHWC(h, w, 4, Self.dim)).permuted(2, 0, 1, 3).copied()
      .reshaped(.WC(4 * n, Self.dim)) + lateFeatures
    let refinementRot = rotary(start: 4 * frameIndex, frames: 4)
    for index in Self.backboneDepth..<blockCount {
      x = run(index, x, frames: 4, keep: 4, queryRot: refinementRot)
    }
    // Pixel shuffle: channel c * 256 + i * 16 + j to pixel (16y + i, 16x + j), channel c.
    var pixels = spatial(inputs: x)[0].as(of: Float.self).reshaped(format: .NHWC, shape: [4, h, w, 3, 16, 16])
      .permuted(0, 1, 4, 2, 5, 3).copied().reshaped(.NHWC(4, 16 * h, 16 * w, 3))
    if first { pixels = pixels[3..<4, 0..<(16 * h), 0..<(16 * w), 0..<3].copied() }
    frameIndex += 1
    return pixels.clamped(-1...1)
  }
}
