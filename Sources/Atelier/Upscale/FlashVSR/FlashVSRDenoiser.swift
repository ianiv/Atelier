import Diffusion
import Foundation
import NNC

/// FlashVSR+'s denoiser: Wan 2.1-T2V-1.3B's transformer driven as FlashVSR drives it. One step
/// at t = 1000 on noise, with the source projection's rows added to its input and a fixed
/// prompt, a chunk of 4 latent frames at a time. Each block attends its chunk and a few windows
/// (2 latent frames each) of the chunks before, which it keeps, so the clip streams through
/// without restarting.
///
/// Attention is block-sparse (the reference's LCSA): tokens are grouped into blocks of 2 frames ×
/// 8×8, each query block scored against every key block by their means, and a query block reads
/// only the key blocks in a spatial band around it whose scores clear a threshold shared by the
/// chunk. Turbo makes 25 of the 30 layers read a 3×3 band and keep one window.
final class FlashVSRDenoiser {
  enum Failure: LocalizedError {
    case badCheckpoint(String)

    var errorDescription: String? {
      switch self {
      case .badCheckpoint(let detail): "The FlashVSR+ checkpoint isn't as expected (\(detail))."
      }
    }
  }

  static let hidden = 1536
  static let heads = 12
  static let headDimension = 128
  static let layers = 30
  /// Latent frames a chunk denoises.
  static let chunkFrames = 4

  let variant: FlashVSRFiles.Variant
  /// The latent size (the output over 8) and the token grid (over 16).
  let latentHeight: Int
  let latentWidth: Int
  var gridHeight: Int { latentHeight / 2 }
  var gridWidth: Int { latentWidth / 2 }
  /// Spatial blocks per window.
  var blocksPerWindow: Int { (gridHeight / 8) * (gridWidth / 8) }
  var tokensPerFrame: Int { gridHeight * gridWidth }
  var sequence: Int { Self.chunkFrames * tokensPerFrame }

  private let graph: DynamicGraph
  private let embed: Model
  private let head: Model
  /// One block's layers, compiled once and shared by every block: each block's weights are
  /// copied in before it runs (`blockSlots`, `blockWeights`), so activations are held once.
  private let preAttention: Model
  private let postAttention: Model
  private var blockSlots: [Model.Parameters] = []
  private var blockWeights: [[AnyTensor]] = []
  /// Folded at load: each block's 6 modulation rows, the head's 2, and each block's cross
  /// attention keys and values over the fixed prompt.
  private var modulations: [[DynamicGraph.Tensor<Float>]] = []
  private var headModulation: [DynamicGraph.Tensor<Float>] = []
  private var crossKeys: [DynamicGraph.Tensor<FloatType>] = []
  private var crossValues: [DynamicGraph.Tensor<FloatType>] = []
  /// Per block, the windows kept from earlier chunks, oldest first: keys (after norm and RoPE)
  /// and values, `[S, 128, 12, 128]` in block order.
  private var cache: [[(keys: DynamicGraph.Tensor<FloatType>, values: DynamicGraph.Tensor<FloatType>)]] = []
  /// Chunks denoised in this stream.
  private(set) var chunk = 0

  /// Turbo's hybrid layers: all but every sixth.
  func isSliding(_ layer: Int) -> Bool { variant == .turbo && layer % 6 != 0 }
  /// Windows a layer keeps after each chunk.
  func keptWindows(_ layer: Int) -> Int { isSliding(layer) ? 1 : 3 }
  /// The spatial band a layer's query blocks may read, in blocks.
  func band(_ layer: Int) -> Int { isSliding(layer) ? 3 : 11 }
  /// FlashVSR+'s top-k ratio.
  static let sparseRatio = 2.5

  init(
    graph: DynamicGraph, checkpoint: FlashVSRCheckpoint, prompt: FlashVSRCheckpoint,
    variant: FlashVSRFiles.Variant, height: Int, width: Int
  ) throws {
    precondition(height % 128 == 0 && width % 128 == 0)
    self.graph = graph
    self.variant = variant
    latentHeight = height / 8
    latentWidth = width / 8
    let D = Self.hidden
    let seq = Self.chunkFrames * (height / 16) * (width / 16)
    var loaders: [(Model.Parameters, String, TensorShape, Float)] = []
    // Norms that run in float32 take float32 weights.
    var floatLoaders: [(Model.Parameters, String, TensorShape)] = []

    // Patch embedding plus the source rows.
    do {
      let patches = Input()
      let rows = Input()
      let patch = Dense(count: D, name: "patch_embedding")
      loaders.append((patch.weight, "patch_embedding.weight", [D, 64], 1))
      loaders.append((patch.bias, "patch_embedding.bias", [D], 1))
      embed = Model([patches, rows], [patch(patches).to(.Float32) + rows.to(.Float32)])
    }
    // The head.
    do {
      let x = Input()
      let shift = Input()
      let scale = Input()
      let norm = LayerNorm(epsilon: 1e-6, axis: [1], elementwiseAffine: false)
      let headName = checkpoint.contains("head.proj.weight") ? "head.proj" : "head.head"
      let proj = Dense(count: 64, name: "head")
      loaders.append((proj.weight, "\(headName).weight", [64, D], 1))
      loaders.append((proj.bias, "\(headName).bias", [64], 1))
      let y = (norm(x) .* (1 + scale) + shift).to(.Float16)
      head = Model([x, shift, scale], [proj(y).to(.Float32)])
    }
    // "#" stands for the block's index in the checkpoint's names.
    var preAttentionModel: Model?
    var postAttentionModel: Model?
    do {
      let prefix = "blocks.#."
      // Before attention: modulated norm, q/k/v, q/k RMS norm over the whole width, RoPE.
      do {
        let x = Input()
        let rot = Input()
        let shift = Input()
        let scale = Input()
        let norm = LayerNorm(epsilon: 1e-6, axis: [1], elementwiseAffine: false)
        let y = (norm(x) .* (1 + scale) + shift).to(.Float16)
        var outs: [Model.IO] = []
        for name in ["q", "k", "v"] {
          let dense = Dense(count: D, name: "\(prefix)self_attn.\(name)")
          loaders.append((dense.weight, "\(prefix)self_attn.\(name).weight", [D, D], 1))
          loaders.append((dense.bias, "\(prefix)self_attn.\(name).bias", [D], 1))
          var out = dense(y)
          if name != "v" {
            let rms = RMSNorm(epsilon: 1e-6, axis: [1], name: "\(prefix)self_attn.norm_\(name)")
            floatLoaders.append((rms.weight, "\(prefix)self_attn.norm_\(name).weight", [D]))
            out = rms(out.to(.Float32)).to(.Float16)
              .reshaped([1, seq, Self.heads, Self.headDimension])
            out = Functional.cmul(left: out, right: rot)
          } else {
            out = out.reshaped([1, seq, Self.heads, Self.headDimension])
          }
          outs.append(out)
        }
        preAttentionModel = Model([x, rot, shift, scale], outs)
      }
      // After attention: output projection and gate, cross attention to the prompt (ungated),
      // the feed-forward and its gate.
      do {
        let x = Input()
        let attention = Input()
        let gate = Input()
        let ffnShift = Input()
        let ffnScale = Input()
        let ffnGate = Input()
        let crossKeys = Input()
        let crossValues = Input()
        let o = Dense(count: D, name: "\(prefix)self_attn.o")
        loaders.append((o.weight, "\(prefix)self_attn.o.weight", [D, D], 1))
        loaders.append((o.bias, "\(prefix)self_attn.o.bias", [D], 1))
        var out = x + gate .* o(attention).to(.Float32)
        let norm3 = LayerNorm(epsilon: 1e-6, axis: [1], name: "\(prefix)norm3")
        floatLoaders.append((norm3.weight, "\(prefix)norm3.weight", [D]))
        floatLoaders.append((norm3.bias, "\(prefix)norm3.bias", [D]))
        let crossQ = Dense(count: D, name: "\(prefix)cross_attn.q")
        loaders.append((crossQ.weight, "\(prefix)cross_attn.q.weight", [D, D], 1))
        loaders.append((crossQ.bias, "\(prefix)cross_attn.q.bias", [D], 1))
        let crossNorm = RMSNorm(epsilon: 1e-6, axis: [1], name: "\(prefix)cross_attn.norm_q")
        floatLoaders.append((crossNorm.weight, "\(prefix)cross_attn.norm_q.weight", [D]))
        let queries = crossNorm(crossQ(norm3(out).to(.Float16)).to(.Float32))
          .to(.Float16).reshaped([1, seq, Self.heads, Self.headDimension])
        let crossAttention = ScaledDotProductAttention(
          scale: 1 / Float(Self.headDimension).squareRoot(), flags: [.Float16])
        let crossOut = crossAttention(queries, crossKeys, crossValues).reshaped([seq, D])
        let crossO = Dense(count: D, name: "\(prefix)cross_attn.o")
        loaders.append((crossO.weight, "\(prefix)cross_attn.o.weight", [D, D], 1))
        loaders.append((crossO.bias, "\(prefix)cross_attn.o.bias", [D], 1))
        out = out + crossO(crossOut).to(.Float32)
        let ffnNorm = LayerNorm(epsilon: 1e-6, axis: [1], elementwiseAffine: false)
        let y = (ffnNorm(out) .* (1 + ffnScale) + ffnShift).to(.Float16)
        let ffn0 = Dense(count: 8960, name: "\(prefix)ffn.0")
        loaders.append((ffn0.weight, "\(prefix)ffn.0.weight", [8960, D], 1))
        loaders.append((ffn0.bias, "\(prefix)ffn.0.bias", [8960], 1))
        let ffn2 = Dense(count: D, name: "\(prefix)ffn.2")
        loaders.append((ffn2.weight, "\(prefix)ffn.2.weight", [D, 8960], 1))
        // Scaled down by 8 around the second projection (its bias too), so its sums stay in
        // half-float range; scaled back in float32.
        loaders.append((ffn2.bias, "\(prefix)ffn.2.bias", [D], 1.0 / 8))
        let hiddenOut = (1.0 / 8) * ffn0(y).GELU(approximate: .tanh)
        out = out + ffnGate .* (8 * ffn2(hiddenOut).to(.Float32))
        postAttentionModel = Model(
          [x, attention, gate, ffnShift, ffnScale, ffnGate, crossKeys, crossValues], [out])
      }
    }

    // Compile with this size's shapes, then read the weights in.
    func zeros<T: TensorNumeric>(_ shape: TensorShape, _ type: T.Type) -> DynamicGraph.Tensor<T> {
      let tensor = graph.variable(.GPU(0), format: .NHWC, shape: shape, of: T.self)
      tensor.full(0)
      return tensor
    }
    let row = zeros([1, D], Float.self)
    embed.compile(inputs: zeros([seq, 64], FloatType.self), zeros([seq, D], FloatType.self))
    head.compile(inputs: zeros([seq, D], Float.self), row, row)
    let rot = zeros([1, seq, 1, Self.headDimension], FloatType.self)
    let promptKeys = zeros([1, 512, Self.heads, Self.headDimension], FloatType.self)
    preAttention = preAttentionModel!
    postAttention = postAttentionModel!
    preAttention.compile(inputs: zeros([seq, D], Float.self), rot, row, row)
    postAttention.compile(
      inputs: zeros([seq, D], Float.self), zeros([seq, D], FloatType.self), row, row, row, row,
      promptKeys, promptKeys)
    func read(_ name: String, scale: Float) throws -> Tensor<Float> {
      var tensor = try checkpoint.tensor(name)
      if scale != 1 {
        tensor.withUnsafeMutableBytes { raw in
          let values = raw.bindMemory(to: Float.self)
          for i in values.indices { values[i] *= scale }
        }
      }
      return tensor
    }
    // The blocks' weights, kept on the GPU for copying into the shared layers.
    var slots: [(Model.Parameters, String, TensorShape, Float, Bool)] = []
    for (parameters, name, shape, scale) in loaders where name.contains("#") {
      slots.append((parameters, name, shape, scale, false))
    }
    for (parameters, name, shape) in floatLoaders where name.contains("#") {
      slots.append((parameters, name, shape, 1, true))
    }
    blockSlots = slots.map(\.0)
    for layer in 0..<Self.layers {
      var weights: [AnyTensor] = []
      for (_, name, shape, scale, isFloat) in slots {
        let tensor = try read(name.replacingOccurrences(of: "#", with: "\(layer)"), scale: scale)
        if isFloat {
          weights.append(tensor.reshaped(format: .NCHW, shape: shape).toGPU(0))
        } else {
          weights.append(Tensor<FloatType>(from: tensor).reshaped(format: .NCHW, shape: shape).toGPU(0))
        }
      }
      blockWeights.append(weights)
    }
    for (parameters, name, shape, scale) in loaders where !name.contains("#") {
      var tensor = try checkpoint.tensor(name)
      if scale != 1 {
        tensor.withUnsafeMutableBytes { raw in
          let values = raw.bindMemory(to: Float.self)
          for i in values.indices { values[i] *= scale }
        }
      }
      parameters.copy(
        from: Tensor<FloatType>(from: tensor).reshaped(format: .NCHW, shape: shape))
    }
    for (parameters, name, shape) in floatLoaders where !name.contains("#") {
      parameters.copy(from: try checkpoint.tensor(name).reshaped(format: .NCHW, shape: shape))
    }
    try fold(checkpoint: checkpoint, prompt: prompt)
    reset()
  }

  // MARK: - Folding the constants

  /// The timestep (always 1000) and the prompt (always the same) folded once, in float32: the
  /// blocks' modulations, the head's, and each block's cross-attention keys and values.
  private func fold(checkpoint: FlashVSRCheckpoint, prompt: FlashVSRCheckpoint) throws {
    let D = Self.hidden
    func load(_ dense: Dense, _ name: String) throws {
      dense.weight.copy(from: try checkpoint.tensor("\(name).weight"))
      dense.bias.copy(from: try checkpoint.tensor("\(name).bias"))
    }
    // The time embedding at t = 1000: sinusoid (cos first, then sin), MLP, projection.
    var sinusoid = Tensor<Float>(.CPU, .WC(1, 256))
    for i in 0..<128 {
      let frequency = pow(10_000.0, -Double(i) / 128)
      sinusoid[0, i] = Float(cos(1_000 * frequency))
      sinusoid[0, 128 + i] = Float(sin(1_000 * frequency))
    }
    let time0 = Dense(count: D)
    let time2 = Dense(count: D)
    let projection = Dense(count: 6 * D)
    let timeInput = Input()
    let timeVector = time2(time0(timeInput).swish())
    let timeModel = Model([timeInput], [timeVector, projection(timeVector.swish())])
    let sinusoidVariable = graph.variable(sinusoid.toGPU(0))
    timeModel.compile(inputs: sinusoidVariable)
    try load(time0, "time_embedding.0")
    try load(time2, "time_embedding.2")
    try load(projection, "time_projection.1")
    let time = timeModel(inputs: sinusoidVariable).map { $0.as(of: Float.self) }
    let headParameters = graph.variable(try checkpoint.tensor("head.modulation").toGPU(0))
      .reshaped(.WC(2, D))
    headModulation = (0..<2).map { row in
      (headParameters[row..<(row + 1), 0..<D].copied() + time[0]).copied()
    }
    // The prompt through the text embedding.
    let raw = try prompt.tensor("posi_prompt")
    let tokens = raw.shape.reduce(1, *) / 4096
    let context = graph.variable(raw.toGPU(0)).reshaped(.WC(tokens, 4096))
    let text0 = Dense(count: D)
    let text2 = Dense(count: D)
    let textInput = Input()
    let textModel = Model([textInput], [text2(text0(textInput).GELU(approximate: .tanh))])
    textModel.compile(inputs: context)
    try load(text0, "text_embedding.0")
    try load(text2, "text_embedding.2")
    let embedded = textModel(inputs: context)[0].as(of: Float.self)
    // Each block's prompt keys (RMS-normed over the whole width) and values.
    let crossK = Dense(count: D)
    let crossV = Dense(count: D)
    let crossNorm = RMSNorm(epsilon: 1e-6, axis: [1])
    let crossInput = Input()
    let crossModel = Model([crossInput], [crossNorm(crossK(crossInput)), crossV(crossInput)])
    crossModel.compile(inputs: embedded)
    modulations = []
    crossKeys = []
    crossValues = []
    for layer in 0..<Self.layers {
      let prefix = "blocks.\(layer)."
      let parameters = graph.variable(try checkpoint.tensor("\(prefix)modulation").toGPU(0))
        .reshaped(.WC(1, 6 * D))
      let sum = (parameters + time[1]).copied()
      modulations.append((0..<6).map { row in sum[0..<1, (row * D)..<((row + 1) * D)].copied() })
      try load(crossK, "\(prefix)cross_attn.k")
      try load(crossV, "\(prefix)cross_attn.v")
      crossNorm.weight.copy(from: try checkpoint.tensor("\(prefix)cross_attn.norm_k.weight"))
      let keysAndValues = crossModel(inputs: embedded).map { $0.as(of: Float.self) }
      crossKeys.append(
        DynamicGraph.Tensor<FloatType>(from: keysAndValues[0])
          .reshaped(.NHWC(1, tokens, Self.heads, Self.headDimension)))
      crossValues.append(
        DynamicGraph.Tensor<FloatType>(from: keysAndValues[1])
          .reshaped(.NHWC(1, tokens, Self.heads, Self.headDimension)))
    }
  }

  // MARK: - Streaming

  /// Back to the start of a stream.
  func reset() {
    cache = Array(repeating: [], count: Self.layers)
    chunk = 0
  }

  /// Denoises the stream's next chunk: `noise` `[4, h, w, 16]` (h, w the latent size) and the
  /// source rows for its 4 latent frames `[4 * tokens, 1536]`. Returns the clean latent,
  /// `noise - prediction`, `[4, h, w, 16]`.
  func next(
    noise: DynamicGraph.Tensor<Float>, rows: DynamicGraph.Tensor<FloatType>,
    shouldContinue: () -> Bool
  ) throws -> DynamicGraph.Tensor<Float>? {
    let D = Self.hidden
    let T = Self.chunkFrames
    let h = latentHeight, w = latentWidth
    let gh = gridHeight, gw = gridWidth
    let seq = sequence
    // Patchify: column c * 4 + ky * 2 + kx.
    let patches = DynamicGraph.Tensor<FloatType>(from: noise)
      .reshaped(.NHWC(T * gh, 2, gw, 2 * 16)).reshaped(format: .NHWC, shape: [T, gh, 2, gw, 2, 16])
      .permuted(0, 1, 3, 5, 2, 4).copied().reshaped(.WC(seq, 64))
    var x = embed(inputs: patches, rows)[0].as(of: Float.self)
    let rot = graph.variable(rotary(offset: chunk * T).toGPU(0))
    for layer in 0..<Self.layers {
      guard shouldContinue() else { return nil }
      let m = modulations[layer]
      for (slot, weight) in zip(blockSlots, blockWeights[layer]) { slot.copy(from: weight) }
      let qkv = preAttention(inputs: x, rot, m[0], m[1]).map { $0.as(of: FloatType.self) }
      Profile.mark("pre")
      let attention = try attend(
        layer: layer, queries: qkv[0], keys: qkv[1], values: qkv[2])
      Profile.mark("attend")
      x = postAttention(
        inputs: x, attention, m[2], m[3], m[4], m[5], crossKeys[layer], crossValues[layer]
      )[0].as(of: Float.self)
      Profile.mark("post")
      graph.garbageCollect()
    }
    let prediction = head(inputs: x, headModulation[0], headModulation[1])[0].as(of: Float.self)
    // Unpatchify: column (ky * 2 + kx) * 16 + c.
    let latent = prediction.reshaped(format: .NHWC, shape: [T, gh, gw, 2, 2, 16])
      .permuted(0, 1, 3, 2, 4, 5).copied().reshaped(.NHWC(T, h, w, 16))
    chunk += 1
    return noise - latent
  }

  /// RoPE for a chunk whose first latent frame is `offset` in the stream: per head, 22 pairs for
  /// time, 21 for rows, 21 for columns, interleaved (cos, sin); angles as float products, as
  /// FlashVSR+ computes them.
  private func rotary(offset: Int) -> Tensor<FloatType> {
    let gh = gridHeight, gw = gridWidth
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, sequence, 1, Self.headDimension))
    let axes: [(pairs: Int, dimension: Int)] = [(22, 44), (21, 42), (21, 42)]
    let frequencies = axes.map { axis in
      (0..<axis.pairs).map { i in powf(10_000, -(Float(i) / Float(axis.dimension / 2))) }
    }
    tensor.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: FloatType.self)
      for f in 0..<Self.chunkFrames {
        for y in 0..<gh {
          for x in 0..<gw {
            let token = (f * gh + y) * gw + x
            var pair = 0
            for (axis, position) in [offset + f, y, x].enumerated() {
              for frequency in frequencies[axis] {
                let angle = Double(Float(position) * frequency)
                out[token * Self.headDimension + pair * 2] = FloatType(Float(cos(angle)))
                out[token * Self.headDimension + pair * 2 + 1] = FloatType(Float(sin(angle)))
                pair += 1
              }
            }
          }
        }
      }
    }
    return tensor
  }

  // MARK: - Block-sparse attention

  /// Tokens in natural order `[1, 4 * gh * gw, 12, 128]` regrouped into blocks of 2 frames × 8×8
  /// tokens, `[2S, 128, 12, 128]`: block (window, row, column), token (frame, y, x) inside.
  private func blocked(_ x: DynamicGraph.Tensor<FloatType>) -> DynamicGraph.Tensor<FloatType> {
    let nh = gridHeight / 8, nw = gridWidth / 8
    let HD = Self.heads * Self.headDimension
    return x.reshaped(format: .NHWC, shape: [2, 2, nh, 8, nw, 8, HD])
      .permuted(0, 2, 4, 1, 3, 5, 6).copied()
      .reshaped(format: .NHWC, shape: [2 * nh * nw, 128, Self.heads, Self.headDimension])
  }

  /// The inverse of `blocked`, to `[4 * gh * gw, 1536]`.
  private func unblocked(_ x: DynamicGraph.Tensor<FloatType>) -> DynamicGraph.Tensor<FloatType> {
    let nh = gridHeight / 8, nw = gridWidth / 8
    let HD = Self.heads * Self.headDimension
    return x.reshaped(format: .NHWC, shape: [2, nh, nw, 2, 8, 8, HD])
      .permuted(0, 3, 1, 4, 2, 5, 6).copied().reshaped(.WC(sequence, HD))
  }

  private func attend(
    layer: Int, queries: DynamicGraph.Tensor<FloatType>, keys: DynamicGraph.Tensor<FloatType>,
    values: DynamicGraph.Tensor<FloatType>
  ) throws -> DynamicGraph.Tensor<FloatType> {
    let S = blocksPerWindow
    let H = Self.heads, HD = Self.headDimension
    let q = blocked(queries)
    let k = blocked(keys)
    let v = blocked(values)
    // This chunk's two windows join the kept ones.
    var windows = cache[layer]
    windows.append((k[0..<S, 0..<128, 0..<H, 0..<HD].copied(), v[0..<S, 0..<128, 0..<H, 0..<HD].copied()))
    windows.append(
      (k[S..<(2 * S), 0..<128, 0..<H, 0..<HD].copied(), v[S..<(2 * S), 0..<128, 0..<H, 0..<HD].copied()))
    let allKeys = concatenated(windows.map(\.keys))
    let allValues = concatenated(windows.map(\.values))
    let queryBlocks = 2 * S
    let keyBlocks = windows.count * S

    // Score each query block against each key block by their means.
    let queryMeans = DynamicGraph.Tensor<Float>(from: q.reduced(.mean, axis: [1]))
      .reshaped(.NHWC(queryBlocks, 1, H, HD)).permuted(2, 0, 1, 3).copied()
      .reshaped(.HWC(H, queryBlocks, HD))
    let keyMeans = DynamicGraph.Tensor<Float>(from: allKeys.reduced(.mean, axis: [1]))
      .reshaped(.NHWC(keyBlocks, 1, H, HD)).permuted(2, 0, 1, 3).copied()
      .reshaped(.HWC(H, keyBlocks, HD))
    let scores = Functional.matmul(left: queryMeans, right: keyMeans, rightTranspose: (1, 2))
      .rawValue.toCPU()
    Profile.mark("scores")
    let kept = select(scores: scores, layer: layer, queryBlocks: queryBlocks, keyBlocks: keyBlocks)
    Profile.mark("select")
    if Profile.enabled && chunk >= 1 && (layer == 0 || layer == 1) {
      let total = kept.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
      print("KEPT layer \(layer): \(total) of \(Self.heads * queryBlocks * keyBlocks) block pairs, \(Double(total) / Double(Self.heads * queryBlocks)) per row")
    }

    // Attend a row of query blocks at a time.
    let output = stripAttention(
      queries: q, keys: allKeys, values: allValues, kept: kept, keyBlocks: keyBlocks,
      span: isSliding(layer) && gridWidth / 8 >= 12 ? 3 : gridWidth / 8)
    // Wait for the GPU here: otherwise the queued strips' temporaries pile up and press on memory.
    _ = output[0..<1, 0..<1, 0..<1, 0..<1].copied().rawValue.toCPU()
    Profile.mark(isSliding(layer) ? "attention-narrow" : "attention-wide")

    // Keep the newest windows for the next chunk.
    let keep = keptWindows(layer)
    cache[layer] = Array(windows.suffix(keep))
    return unblocked(output)
  }

  /// Which key blocks each (head, query block) reads, as FlashVSR+ routes them: the softmax of
  /// the block scores inside the layer's spatial band, kept where it beats the chunk's
  /// (k + 1)-th largest (k = S² × 2.5 - 1), or the first in-band block of the oldest window
  /// when nothing does. `kept[h][i]` lists key block indices ascending.
  private func select(scores: Tensor<Float>, layer: Int, queryBlocks: Int, keyBlocks: Int)
    -> [[[Int32]]]
  {
    let S = blocksPerWindow
    let nw = gridWidth / 8
    let L = band(layer)
    let half = L / 2
    let scale = 1 / Float(Self.headDimension).squareRoot()
    let topK = Int(Double(S * S) * Self.sparseRatio) - 1
    let apply = min(queryBlocks * keyBlocks - 1, topK)
    // In-band key spatial blocks for each query spatial block.
    let neighbors: [[Int]] = (0..<S).map { s in
      let ry = s / nw, rx = s % nw
      var list: [Int] = []
      for j in 0..<S {
        let cy = j / nw, cx = j % nw
        if cy >= ry - half && cy <= ry - half + L - 1 && cx >= rx - half && cx <= rx - half + L - 1 {
          list.append(j)
        }
      }
      return list
    }
    var result: [[[Int32]]] = []
    let windows = keyBlocks / S
    scores.withUnsafeBytes { raw in
      let values = raw.bindMemory(to: Float.self)
      for head in 0..<Self.heads {
        // Softmax over each row's in-band blocks (the rest are exactly 0).
        var probabilities: [[Float]] = []
        var candidates: [[Int]] = []
        var all: [Float] = []
        all.reserveCapacity(queryBlocks * neighbors[0].count * windows)
        for i in 0..<queryBlocks {
          let base = (head * queryBlocks + i) * keyBlocks
          var columns: [Int] = []
          for window in 0..<windows {
            for j in neighbors[i % S] { columns.append(window * S + j) }
          }
          let logits = columns.map { values[base + $0] * scale }
          let peak = logits.max() ?? 0
          var exps = logits.map { exp($0 - peak) }
          let sum = exps.reduce(0, +)
          exps = exps.map { $0 / sum }
          probabilities.append(exps)
          candidates.append(columns)
          all.append(contentsOf: exps)
        }
        // The (apply + 1)-th largest over the chunk; out-of-band zeros count too.
        let zeros = queryBlocks * keyBlocks - all.count
        var threshold: Float = 0
        if apply < all.count {
          threshold = Self.largest(all, rank: apply)
        } else if apply >= all.count + zeros {
          threshold = 0
        }
        _ = zeros
        var rows: [[Int32]] = []
        for i in 0..<queryBlocks {
          var keep: [Int32] = []
          for (index, p) in probabilities[i].enumerated() where p > threshold {
            keep.append(Int32(candidates[i][index]))
          }
          if keep.isEmpty, let first = neighbors[i % S].first {
            // The oldest window's first in-band block.
            keep = [Int32(first)]
          }
          rows.append(keep.sorted())
        }
        result.append(rows)
      }
    }
    return result
  }

  /// The value at 0-based rank `rank` of `values` sorted descending.
  static func largest(_ values: [Float], rank: Int) -> Float {
    var values = values
    var low = 0, high = values.count - 1
    let target = rank
    while low < high {
      let pivot = values[(low + high) / 2]
      var i = low, j = high
      while i <= j {
        while values[i] > pivot { i += 1 }
        while values[j] < pivot { j -= 1 }
        if i <= j {
          values.swapAt(i, j)
          i += 1
          j -= 1
        }
      }
      if target <= j {
        high = j
      } else if target >= i {
        low = i
      } else {
        return values[target]
      }
    }
    return values[target]
  }

  /// Attention a strip of query blocks (part of one block row of one window) at a time, over
  /// the key blocks any of them reads, with each head's block mask spread over the tokens. A
  /// strip whose heads' masks agree (nothing in the band pruned, as in Turbo's narrow layers)
  /// takes one call for all heads; otherwise each head goes alone, its keys head-major. Narrow
  /// layers take strips 3 blocks wide, so their keys are mostly ones they read; wide layers
  /// take whole rows, since every block reads nearly everything.
  private func stripAttention(
    queries: DynamicGraph.Tensor<FloatType>, keys: DynamicGraph.Tensor<FloatType>,
    values: DynamicGraph.Tensor<FloatType>, kept: [[[Int32]]], keyBlocks: Int, span: Int
  ) -> DynamicGraph.Tensor<FloatType> {
    let H = Self.heads, HD = Self.headDimension
    let S = blocksPerWindow
    let nw = gridWidth / 8, nh = gridHeight / 8
    let scale = 1 / Float(HD).squareRoot()
    var output = graph.variable(.GPU(0), .NHWC(2 * S, 128, H, HD), of: FloatType.self)
    let keyRows = keys.reshaped(.WC(keyBlocks, 128 * H * HD))
    let valueRows = values.reshaped(.WC(keyBlocks, 128 * H * HD))
    // Head-major copies, made when a strip first needs them: [H * blocks, 128 * HD].
    var keysByHead: DynamicGraph.Tensor<FloatType>?
    var valuesByHead: DynamicGraph.Tensor<FloatType>?
    var queriesByHead: DynamicGraph.Tensor<FloatType>?
    for window in 0..<2 {
      for row in 0..<nh {
        for column in stride(from: 0, to: nw, by: span) {
          let first = window * S + row * nw + column
          let count = min(span, nw - column)
          let strip = first..<(first + count)
          // The key blocks any head of any block in the strip reads.
          var union = Set<Int32>()
          for head in 0..<H {
            for i in strip { union.formUnion(kept[head][i]) }
          }
          let columns = union.sorted()
          let position = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, $0) })
          let masks: [[Bool]] = (0..<H).map { head in
            var mask = [Bool](repeating: false, count: count * columns.count)
            for (r, i) in strip.enumerated() {
              for j in kept[head][i] { mask[r * columns.count + position[j]!] = true }
            }
            return mask
          }
          let shared = masks.allSatisfy { $0 == masks[0] }
          let result: DynamicGraph.Tensor<FloatType>
          if shared {
            let stripKeys: DynamicGraph.Tensor<FloatType>
            let stripValues: DynamicGraph.Tensor<FloatType>
            if columns.count == keyBlocks {
              stripKeys = keys.reshaped(.NHWC(1, keyBlocks * 128, H, HD))
              stripValues = values.reshaped(.NHWC(1, keyBlocks * 128, H, HD))
            } else {
              let index = graph.variable(Tensor<Int32>(columns, .CPU, .C(columns.count)).toGPU(0))
              stripKeys = Functional.indexSelect(input: keyRows, index: index)
                .reshaped(.NHWC(1, columns.count * 128, H, HD))
              stripValues = Functional.indexSelect(input: valueRows, index: index)
                .reshaped(.NHWC(1, columns.count * 128, H, HD))
            }
            let stripQueries = queries[strip, 0..<128, 0..<H, 0..<HD].copied()
              .reshaped(.NHWC(1, count * 128, H, HD))
            result = attention(
              stripQueries, stripKeys, stripValues, mask: masks[0], rows: count,
              columns: columns.count, scale: scale
            ).reshaped(.NHWC(count, 128, H, HD))
          } else {
            if keysByHead == nil {
              keysByHead = keys.copied().permuted(2, 0, 1, 3).copied()
                .reshaped(.WC(H * keyBlocks, 128 * HD))
              valuesByHead = values.copied().permuted(2, 0, 1, 3).copied()
                .reshaped(.WC(H * keyBlocks, 128 * HD))
              queriesByHead = queries.copied().permuted(2, 0, 1, 3).copied()
                .reshaped(.WC(H * 2 * S, 128 * HD))
            }
            // Each head reads its own key blocks: gathered per head, padded to the widest
            // (padding masked), all heads in one call.
            let headColumns: [[Int32]] = (0..<H).map { head in
              var set = Set<Int32>()
              for i in strip { set.formUnion(kept[head][i]) }
              return set.sorted()
            }
            let width = headColumns.map(\.count).max() ?? 1
            let maskBytes = H * count * 128 * width * 128 * MemoryLayout<FloatType>.size
            if maskBytes > 768 * 1_024 * 1_024 {
              // Too large to batch: one head at a time.
              var heads: [DynamicGraph.Tensor<FloatType>] = []
              for head in 0..<H {
                let cols = headColumns[head]
                let at = Dictionary(uniqueKeysWithValues: cols.enumerated().map { ($1, $0) })
                var mask = [Bool](repeating: false, count: count * cols.count)
                for (r, i) in strip.enumerated() {
                  for j in kept[head][i] { mask[r * cols.count + at[j]!] = true }
                }
                let index = graph.variable(
                  Tensor<Int32>(cols.map { Int32(head * keyBlocks) + $0 }, .CPU, .C(cols.count)).toGPU(0))
                let headKeys = Functional.indexSelect(input: keysByHead!, index: index)
                  .reshaped(.NHWC(1, cols.count * 128, 1, HD))
                let headValues = Functional.indexSelect(input: valuesByHead!, index: index)
                  .reshaped(.NHWC(1, cols.count * 128, 1, HD))
                let headQueries = queriesByHead![
                  (head * 2 * S + first)..<(head * 2 * S + first + count), 0..<(128 * HD)
                ].copied().reshaped(.NHWC(1, count * 128, 1, HD))
                heads.append(
                  attention(
                    headQueries, headKeys, headValues, mask: mask, rows: count,
                    columns: cols.count, scale: scale
                  ).reshaped(.NHWC(count, 128, 1, HD)))
              }
              output[strip, 0..<128, 0..<H, 0..<HD] = concatenated(heads, axis: 2)
              continue
            }
            var index: [Int32] = []
            var headMasks: [[Bool]] = []
            for head in 0..<H {
              let cols = headColumns[head]
              let at = Dictionary(uniqueKeysWithValues: cols.enumerated().map { ($1, $0) })
              index.append(contentsOf: cols.map { Int32(head * keyBlocks) + $0 })
              index.append(
                contentsOf: Array(repeating: Int32(head * keyBlocks) + cols[0], count: width - cols.count))
              var mask = [Bool](repeating: false, count: count * width)
              for (r, i) in strip.enumerated() {
                for j in kept[head][i] { mask[r * width + at[j]!] = true }
              }
              headMasks.append(mask)
            }
            let indexVariable = graph.variable(Tensor<Int32>(index, .CPU, .C(index.count)).toGPU(0))
            let headKeys = Functional.indexSelect(input: keysByHead!, index: indexVariable)
              .reshaped(.NHWC(H, width * 128, 1, HD))
            let headValues = Functional.indexSelect(input: valuesByHead!, index: indexVariable)
              .reshaped(.NHWC(H, width * 128, 1, HD))
            var queryIndex: [Int32] = []
            for head in 0..<H { queryIndex.append(contentsOf: strip.map { Int32(head * 2 * S + $0) }) }
            let headQueries = Functional.indexSelect(
              input: queriesByHead!,
              index: graph.variable(Tensor<Int32>(queryIndex, .CPU, .C(queryIndex.count)).toGPU(0))
            ).reshaped(.NHWC(H, count * 128, 1, HD))
            let out = attention(
              headQueries, headKeys, headValues, masks: headMasks, rows: count, columns: width,
              scale: scale)
            result = out.reshaped(.HWC(H, count * 128, HD)).permuted(1, 0, 2).copied()
              .reshaped(.NHWC(count, 128, H, HD))
          }
          output[strip, 0..<128, 0..<H, 0..<HD] = result
        }
      }
    }
    return output
  }

  /// Attention batched over the first dimension, each entry with its own block mask.
  private func attention(
    _ q: DynamicGraph.Tensor<FloatType>, _ k: DynamicGraph.Tensor<FloatType>,
    _ v: DynamicGraph.Tensor<FloatType>, masks: [[Bool]], rows: Int, columns: Int, scale: Float
  ) -> DynamicGraph.Tensor<FloatType> {
    let batch = masks.count
    var blocks = Tensor<FloatType>(.CPU, .WC(batch * rows, columns))
    for (b, mask) in masks.enumerated() {
      for r in 0..<rows {
        for c in 0..<columns {
          blocks[b * rows + r, c] = mask[r * columns + c] ? 0 : -FloatType.infinity
        }
      }
    }
    let rowIndex = graph.variable(
      Tensor<Int32>(
        (0..<(batch * rows * 128)).map { Int32(($0 / (rows * 128)) * rows + ($0 % (rows * 128)) / 128) },
        .CPU, .C(batch * rows * 128)
      ).toGPU(0))
    let columnIndex = graph.variable(
      Tensor<Int32>((0..<(columns * 128)).map { Int32($0 / 128) }, .CPU, .C(columns * 128)).toGPU(0))
    let byRow = Functional.indexSelect(input: graph.variable(blocks.toGPU(0)), index: rowIndex)
    let transposed = byRow.transposed(0, 1).copied()
    let tokenMask = Functional.indexSelect(input: transposed, index: columnIndex)
      .transposed(0, 1).copied().reshaped(.NHWC(batch, 1, rows * 128, columns * 128))
    return ScaledDotProductAttention(scale: scale, hasAttentionMask: true, flags: [.Float16])(
      queries: q, keys: k, values: v, attentionMask: tokenMask)
  }

  /// Attention with a block mask (`rows` query blocks × `columns` key blocks, true where read),
  /// spread to the tokens on the GPU; no mask when every block is read.
  private func attention(
    _ q: DynamicGraph.Tensor<FloatType>, _ k: DynamicGraph.Tensor<FloatType>,
    _ v: DynamicGraph.Tensor<FloatType>, mask: [Bool], rows: Int, columns: Int, scale: Float
  ) -> DynamicGraph.Tensor<FloatType> {
    if mask.allSatisfy({ $0 }) {
      return ScaledDotProductAttention(scale: scale, flags: [.Float16])(queries: q, keys: k, values: v)
    }
    var blocks = Tensor<FloatType>(.CPU, .WC(rows, columns))
    for r in 0..<rows {
      for c in 0..<columns { blocks[r, c] = mask[r * columns + c] ? 0 : -FloatType.infinity }
    }
    // Rows to query tokens, then columns to key tokens.
    let rowIndex = graph.variable(
      Tensor<Int32>((0..<(rows * 128)).map { Int32($0 / 128) }, .CPU, .C(rows * 128)).toGPU(0))
    let columnIndex = graph.variable(
      Tensor<Int32>((0..<(columns * 128)).map { Int32($0 / 128) }, .CPU, .C(columns * 128)).toGPU(0))
    let byRow = Functional.indexSelect(input: graph.variable(blocks.toGPU(0)), index: rowIndex)
    let transposed = byRow.transposed(0, 1).copied()
    let tokenMask = Functional.indexSelect(input: transposed, index: columnIndex)
      .transposed(0, 1).copied().reshaped(.NHWC(1, 1, rows * 128, columns * 128))
    return ScaledDotProductAttention(scale: scale, hasAttentionMask: true, flags: [.Float16])(
      queries: q, keys: k, values: v, attentionMask: tokenMask)
  }
}

/// Temporary timing (FLASHVSR_PROFILE=1): seconds per named step, synchronizing the GPU.
enum Profile {
  nonisolated(unsafe) static var enabled = ProcessInfo.processInfo.environment["FLASHVSR_PROFILE"] != nil
  nonisolated(unsafe) static var last = Date()
  nonisolated(unsafe) static var totals: [String: Double] = [:]
  static func mark(_ name: String, graph: DynamicGraph? = nil) {
    guard enabled else { return }
    let now = Date()
    totals[name, default: 0] += now.timeIntervalSince(last)
    last = now
  }
  static func report() {
    guard enabled else { return }
    print("PROFILE", totals.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " "))
    totals = [:]
  }
}
