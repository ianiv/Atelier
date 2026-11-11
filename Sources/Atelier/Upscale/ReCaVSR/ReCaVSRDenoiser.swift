@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// ReCaVSR's DiT: Wan2.2-TI2V-5B's transformer driven as ReCaVSR drives it
/// (runtime/transformer.py `TransformerSession.step`). One step at t = 1000 on noise, a block of
/// latents at a time (6 for the first, then 2), with the source projection's rows and the
/// previous block's last two clean latents ("recycled") added to its input. Each layer attends
/// its block and the earlier latents its learned router kept (`ReCaVSRRouter`), inside a
/// spatial window around each token.
///
/// The 30 layers share one compiled set of models, whose activations are held once; each layer's
/// weights are copied in before it runs (see `holders`).
final nonisolated class ReCaVSRDenoiser {
  enum Failure: LocalizedError {
    case badCheckpoint(String)

    var errorDescription: String? {
      switch self {
      case .badCheckpoint(let detail): "The ReCaVSR checkpoint isn't as expected (\(detail))."
      }
    }
  }

  static let D = ReCaVSRConfig.hidden
  static let heads = ReCaVSRConfig.heads
  static let headDimension = ReCaVSRConfig.headDimension
  static let layers = ReCaVSRConfig.layers

  /// The token grid (the padded output over 32) and the latent grid (over 16).
  let gridHeight: Int
  let gridWidth: Int
  var latentHeight: Int { 2 * gridHeight }
  var latentWidth: Int { 2 * gridWidth }
  var tokensPerLatent: Int { gridHeight * gridWidth }
  /// The spatial window in tokens; when it covers the grid, attention is plain.
  let window: (height: Int, width: Int)
  var isWindowed: Bool { gridHeight > window.height || gridWidth > window.width }

  private let graph: DynamicGraph
  private let embed: Model
  private let head: Model
  /// One layer's three pieces, shared by every layer: before self-attention (modulated norm,
  /// q/k/v, q/k RMS norms), between it and cross-attention (output projection, gate, cross
  /// query), and after (cross output, feed-forward). Attention runs outside them, so they take
  /// any number of tokens.
  private let preAttention: Model
  private let crossQuery: Model
  private let postAttention: Model
  private var pieces: [Model] { [preAttention, crossQuery, postAttention] }
  /// Each layer's weights, held by a copy of the pieces that is compiled but never run (so it
  /// has weights and no activations), and copied into the pieces before the layer runs: copying
  /// keeps the tensors the pieces' compiled graph is bound to, which moving weights in and out
  /// (`attach` / `detach`) doesn't, and it copies 8-bit weights as they are.
  private var holders: [[Model]] = []
  /// Folded at load: each layer's 6 modulation rows, the head's 2, and each layer's cross
  /// attention keys and values over the fixed prompt.
  private var modulations: [[DynamicGraph.Tensor<Float>]] = []
  private var headModulation: [DynamicGraph.Tensor<Float>] = []
  private var crossKeys: [DynamicGraph.Tensor<FloatType>] = []
  private var crossValues: [DynamicGraph.Tensor<FloatType>] = []
  /// Per layer, the latents it kept from earlier blocks, oldest first, with their keys (normed,
  /// rotated at their absolute latent index) and values, `[1, tokens, 24, 128]` each.
  private var kept: [[(latent: Int, keys: DynamicGraph.Tensor<FloatType>, values: DynamicGraph.Tensor<FloatType>)]] = []
  /// The next block's first latent.
  private(set) var latentOffset = 0
  /// The last block's last two clean latents, `[2, h, w, 48]`, half precision as the reference
  /// keeps them; nil before the first block.
  private var recycled: DynamicGraph.Tensor<FloatType>?
  private let windowedAttention: ReCaVSRLocalAttention?

  /// Builds the DiT for a `height`×`width` frame (padded, multiples of 32).
  init(
    graph: DynamicGraph, checkpoint: ReCaVSRWeightSource, prompt: ReCaVSRCheckpoint, height: Int,
    width: Int, window: (height: Int, width: Int) = ReCaVSRConfig.window
  ) throws {
    precondition(height % 32 == 0 && width % 32 == 0)
    self.graph = graph
    gridHeight = height / 32
    gridWidth = width / 32
    self.window = window
    let D = Self.D
    let C = ReCaVSRConfig.latentChannels

    var outer: [(Model.Parameters, String, Bool)] = []
    func dense(_ count: Int, _ name: String) -> Dense {
      let layer = Dense(count: count, name: name)
      outer.append((layer.weight, "\(name).weight", false))
      outer.append((layer.bias, "\(name).bias", false))
      return layer
    }

    // Patch embedding of the noise and of the recycled latents (one shared conv (1,2,2) as a
    // matrix over column c * 4 + ky * 2 + kx), the recycled through sr_proj, plus the source
    // rows (transformer.py:285-292). Also hands out the two terms for the check.
    do {
      let noise = Input()
      let recycle = Input()
      let rows = Input()
      let patch = dense(D, "patch_embedding")
      let sr = dense(D, "sr_proj")
      let noiseTerm = patch(noise).to(.Float32)
      let srTerm = sr(patch(recycle)).to(.Float32)
      embed = Model([noise, recycle, rows], [noiseTerm + rows.to(.Float32) + srTerm, noiseTerm, srTerm])
    }
    // The head: norm, modulation, proj_out (transformer.py:275-281).
    do {
      let x = Input()
      let shift = Input()
      let scale = Input()
      let norm = LayerNorm(epsilon: 1e-6, axis: [1], elementwiseAffine: false)
      let proj = dense(4 * C, "proj_out")
      head = Model([x, shift, scale], [proj((norm(x) .* (1 + scale) + shift).to(.Float16)).to(.Float32)])
    }
    let template = Self.pieces()
    (preAttention, crossQuery, postAttention) = (template.models[0], template.models[1], template.models[2])
    windowedAttention =
      gridHeight > window.height || gridWidth > window.width
        ? ReCaVSRLocalAttention(
          graph: graph, gridHeight: gridHeight, gridWidth: gridWidth, windowHeight: window.height,
          windowWidth: window.width)
        : nil

    func zeros<T: TensorNumeric>(_ shape: TensorShape, _: T.Type) -> DynamicGraph.Tensor<T> {
      let tensor = graph.variable(.GPU(0), format: .NHWC, shape: shape, of: T.self)
      tensor.full(0)
      return tensor
    }
    let seq = ReCaVSRConfig.prefixLatents * gridHeight * gridWidth
    let row = zeros([1, D], Float.self)
    embed.compile(
      inputs: zeros([seq, 4 * C], FloatType.self), zeros([seq, 4 * C], FloatType.self),
      zeros([seq, D], FloatType.self))
    head.compile(inputs: zeros([seq, D], Float.self), row, row)
    Self.compile(pieces, tokens: seq, graph: graph)
    // Each layer's holder, read in; the pieces start with layer 0's.
    for layer in 0..<Self.layers {
      let holder = Self.pieces()
      Self.compile(holder.models, tokens: 1, graph: graph)
      try checkpoint.load(holder.models, slots: holder.slots, layer: layer)
      holders.append(holder.models)
    }
    try checkpoint.load(pieces, slots: template.slots, layer: 0)
    // Weights outside the layers, read straight into place.
    for (parameter, name, isFloat) in outer {
      parameter.copy(from: try Self.outerWeight(name, isFloat: isFloat, source: checkpoint))
    }
    try fold(checkpoint: checkpoint, prompt: prompt)
    reset()
  }

  /// A layer's parameter, its checkpoint name relative to "blocks.N.", and whether it's float32
  /// (the norms, which run in float32).
  typealias Slot = (parameter: Model.Parameters, name: String, isFloat: Bool)

  /// One layer's pieces (before self-attention, before cross-attention, after), their
  /// parameters named as the checkpoint's modules.
  static func pieces() -> (models: [Model], slots: [Slot]) {
    let D = Self.D
    var slots: [Slot] = []
    func Dense(count: Int, name: String) -> NNC.Dense {
      let layer = NNC.Dense(count: count, name: name)
      slots.append((layer.weight, "\(name).weight", false))
      slots.append((layer.bias, "\(name).bias", false))
      return layer
    }
    func RMSNorm(epsilon: Float, axis: [Int], name: String) -> NNC.RMSNorm {
      let norm = NNC.RMSNorm(epsilon: epsilon, axis: axis, name: name)
      slots.append((norm.weight, "\(name).weight", true))
      return norm
    }
    // Before self-attention (transformer.py:78-92): q and k come out RMS-normed over the whole
    // width in float32, for RoPE in float32 outside.
    let preAttention: Model
    do {
      let x = Input()
      let shift = Input()
      let scale = Input()
      let norm = LayerNorm(epsilon: 1e-6, axis: [1], elementwiseAffine: false)
      let y = (norm(x) .* (1 + scale) + shift).to(.Float16)
      let q = Dense(count: D, name: "attn1.to_q")
      let k = Dense(count: D, name: "attn1.to_k")
      let v = Dense(count: D, name: "attn1.to_v")
      let normQ = RMSNorm(epsilon: 1e-6, axis: [1], name: "attn1.norm_q")
      let normK = RMSNorm(epsilon: 1e-6, axis: [1], name: "attn1.norm_k")
      preAttention = Model([x, shift, scale], [normQ(q(y).to(.Float32)), normK(k(y).to(.Float32)), v(y)])
    }
    // Output projection and gate in float32, then the cross-attention query: affine norm2,
    // to_q, RMS norm (transformer.py:107-112).
    let crossQuery: Model
    do {
      let x = Input()
      let attention = Input()
      let gate = Input()
      let o = Dense(count: D, name: "attn1.to_out.0")
      let out = x + gate .* o(attention).to(.Float32)
      let norm2 = LayerNorm(epsilon: 1e-6, axis: [1], name: "norm2")
      slots.append((norm2.weight, "norm2.weight", true))
      slots.append((norm2.bias, "norm2.bias", true))
      let q = Dense(count: D, name: "attn2.to_q")
      let normQ = RMSNorm(epsilon: 1e-6, axis: [1], name: "attn2.norm_q")
      crossQuery = Model([x, attention, gate], [out, normQ(q(norm2(out).to(.Float16)).to(.Float32)).to(.Float16)])
    }
    // Cross output (ungated), then the feed-forward and its gate (transformer.py:113-130).
    let postAttention: Model
    do {
      let x = Input()
      let cross = Input()
      let shift = Input()
      let scale = Input()
      let gate = Input()
      let o = Dense(count: D, name: "attn2.to_out.0")
      var out = x + o(cross).to(.Float32)
      let norm3 = LayerNorm(epsilon: 1e-6, axis: [1], elementwiseAffine: false)
      let y = (norm3(out) .* (1 + scale) + shift).to(.Float16)
      let up = Dense(count: ReCaVSRConfig.feedForward, name: "ffn.net.0.proj")
      let down = Dense(count: D, name: "ffn.net.2")
      // Scaled down by 8 around the second projection (its bias too, at load), so its sums
      // stay in half-float range; scaled back in float32 (as FlashVSRDenoiser does).
      let hidden = (1.0 / 8) * up(y).GELU(approximate: .tanh)
      out = out + gate .* (8 * down(hidden).to(.Float32))
      postAttention = Model([x, cross, shift, scale, gate], [out])
    }
    return ([preAttention, crossQuery, postAttention], slots)
  }

  /// Compiles a layer's pieces for `tokens` tokens.
  static func compile(_ pieces: [Model], tokens: Int, graph: DynamicGraph) {
    func zeros<T: TensorNumeric>(_ shape: TensorShape, _: T.Type) -> DynamicGraph.Tensor<T> {
      let tensor = graph.variable(.GPU(0), format: .NHWC, shape: shape, of: T.self)
      tensor.full(0)
      return tensor
    }
    let row = zeros([1, D], Float.self)
    pieces[0].compile(inputs: zeros([tokens, D], Float.self), row, row)
    pieces[1].compile(inputs: zeros([tokens, D], Float.self), zeros([tokens, D], FloatType.self), row)
    pieces[2].compile(inputs: zeros([tokens, D], Float.self), zeros([tokens, D], FloatType.self), row, row, row)
  }

  /// The layer weights the copy stores 8-bit and the pieces multiply by.
  static let matrices = [
    "attn1.to_q", "attn1.to_k", "attn1.to_v", "attn1.to_out.0", "attn2.to_q", "attn2.to_out.0", "ffn.net.0.proj",
    "ffn.net.2",
  ]

  /// The checkpoint name for a piece's parameter `key` (s4nnc names it `t-<layer>-<n>-<i>`, i = 0
  /// the weight, 1 the bias; reads may wrap it as `__name__[…]`) in layer `layer`.
  static func checkpointName(_ key: String, layer: Int) -> String? {
    var key = Substring(key)
    if let open = key.firstIndex(of: "["), key.hasSuffix("]") { key = key[key.index(after: open)..<key.index(before: key.endIndex)] }
    let parts = key.split(separator: "-")
    guard parts.count >= 4, parts[0] == "t", let index = Int(parts[parts.count - 1]) else { return nil }
    let module = parts[1..<(parts.count - 2)].joined(separator: "-")
    return "blocks.\(layer).\(module)" + (index == 0 ? ".weight" : ".bias")
  }

  /// The outer weight `name`, half precision (float32 for `isFloat`), conv weights
  /// (`[3072, 48, 1, 2, 2]`) as the matrix over the patch.
  static func outerWeight(_ name: String, isFloat: Bool, source: ReCaVSRWeightSource) throws -> AnyTensor {
    let tensor = try source.tensor(name)
    let count = tensor.shape.reduce(1, *)
    let rows = tensor.shape[0]
    let shaped = tensor.reshaped(format: .NCHW, shape: tensor.shape.count > 1 ? [rows, count / rows] : [count])
    return isFloat ? shaped : Tensor<FloatType>(from: shaped)
  }

  // MARK: - Folding the constants

  /// The timestep (always 1000) and the prompt (always the same) folded once, in float32: the
  /// layers' modulations (`scale_shift_table + timestep_proj`, transformer.py:45-48), the head's
  /// (`scale_shift_table + temb`, :275-277), and each layer's cross-attention keys
  /// (`norm_k(to_k(context))`) and values (transformer_wan.py:613-626).
  private func fold(checkpoint: ReCaVSRWeightSource, prompt: ReCaVSRCheckpoint) throws {
    let D = Self.D
    func load(_ dense: Dense, _ name: String) throws {
      dense.weight.copy(from: try checkpoint.tensor("\(name).weight"))
      dense.bias.copy(from: try checkpoint.tensor("\(name).bias"))
    }
    // Timesteps(256, flip_sin_to_cos, shift 0) at 1000: cos first, then sin; the time MLP;
    // the projection to 6 rows (transformer_wan.py:648-688).
    var sinusoid = Tensor<Float>(.CPU, .WC(1, 256))
    for i in 0..<128 {
      let frequency = exp(-log(10_000.0) * Double(i) / 128)
      sinusoid[0, i] = Float(cos(ReCaVSRConfig.timestep * frequency))
      sinusoid[0, 128 + i] = Float(sin(ReCaVSRConfig.timestep * frequency))
    }
    let time1 = Dense(count: D)
    let time2 = Dense(count: D)
    let projection = Dense(count: 6 * D)
    let timeInput = Input()
    let temb = time2(time1(timeInput).swish())
    let timeModel = Model([timeInput], [temb, projection(temb.swish())])
    let sinusoidVariable = graph.variable(sinusoid.toGPU(0))
    timeModel.compile(inputs: sinusoidVariable)
    try load(time1, "condition_embedder.time_embedder.linear_1")
    try load(time2, "condition_embedder.time_embedder.linear_2")
    try load(projection, "condition_embedder.time_proj")
    let time = timeModel(inputs: sinusoidVariable).map { $0.as(of: Float.self) }
    let headTable = graph.variable(try checkpoint.tensor("scale_shift_table").toGPU(0)).reshaped(.WC(2, D))
    headModulation = (0..<2).map { row in (headTable[row..<(row + 1), 0..<D].copied() + time[0]).copied() }
    // The prompt through the text embedder (linear, GELU tanh, linear).
    let raw = try prompt.tensor("positive")
    let tokens = raw.shape.reduce(1, *) / 4096
    let context = graph.variable(raw.toGPU(0)).reshaped(.WC(tokens, 4096))
    let text1 = Dense(count: D)
    let text2 = Dense(count: D)
    let textInput = Input()
    let textModel = Model([textInput], [text2(text1(textInput).GELU(approximate: .tanh))])
    textModel.compile(inputs: context)
    try load(text1, "condition_embedder.text_embedder.linear_1")
    try load(text2, "condition_embedder.text_embedder.linear_2")
    let embedded = textModel(inputs: context)[0].as(of: Float.self)
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
      let table = graph.variable(try checkpoint.tensor("\(prefix)scale_shift_table").toGPU(0))
        .reshaped(.WC(1, 6 * D))
      let sum = (table + time[1]).copied()
      modulations.append((0..<6).map { row in sum[0..<1, (row * D)..<((row + 1) * D)].copied() })
      try load(crossK, "\(prefix)attn2.to_k")
      try load(crossV, "\(prefix)attn2.to_v")
      crossNorm.weight.copy(from: try checkpoint.tensor("\(prefix)attn2.norm_k.weight"))
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
    kept = Array(repeating: [], count: Self.layers)
    latentOffset = 0
    recycled = nil
  }

  /// Denoises the stream's next block: `noise` `[F, h, w, 48]` (F = 6 for the first block, then
  /// 2; h, w the latent grid) and the source rows for its latents `[F * tokens, 3072]`. Returns
  /// the clean latents, `noise - prediction`, `[F, h, w, 48]` (transformer.py:256-305).
  /// `inspect` sees the intermediates the reference check compares, by the reference's names.
  func next(
    noise: DynamicGraph.Tensor<Float>, rows: DynamicGraph.Tensor<FloatType>,
    shouldContinue: () -> Bool,
    inspect: ((String, DynamicGraph.Tensor<Float>) -> Void)? = nil
  ) throws -> DynamicGraph.Tensor<Float>? {
    let F = latentOffset == 0 ? ReCaVSRConfig.prefixLatents : ReCaVSRConfig.bodyLatents
    let C = ReCaVSRConfig.latentChannels
    let h = latentHeight, w = latentWidth
    let gh = gridHeight, gw = gridWidth
    let tokens = tokensPerLatent
    let seq = F * tokens
    let H = Self.heads, HD = Self.headDimension
    precondition(noise.shape[0] == F)

    // Patchify: column c * 4 + ky * 2 + kx.
    func patches(_ latents: DynamicGraph.Tensor<FloatType>) -> DynamicGraph.Tensor<FloatType> {
      let frames = latents.shape[0]
      return latents.reshaped(format: .NHWC, shape: [frames, gh, 2, gw, 2, C])
        .permuted(0, 1, 3, 5, 2, 4).copied().reshaped(.WC(frames * tokens, 4 * C))
    }
    // The first block recycles zeros (its biases still flow, transformer.py:280-283).
    let recycle: DynamicGraph.Tensor<FloatType>
    if let recycled {
      recycle = recycled
    } else {
      recycle = graph.variable(.GPU(0), .NHWC(F, h, w, C), of: FloatType.self)
      recycle.full(0)
    }
    let embedded = embed(inputs: patches(DynamicGraph.Tensor<FloatType>(from: noise)), patches(recycle), rows)
      .map { $0.as(of: Float.self) }
    var x = embedded[0]
    inspect?("patch_embed_noise", embedded[1])
    inspect?("sr_term", embedded[2])
    inspect?("embed", x)
    let rot = graph.variable(rotary(start: latentOffset, frames: F).toGPU(0))
    let current = Array(latentOffset..<(latentOffset + F))
    for layer in 0..<Self.layers {
      guard shouldContinue() else { return nil }
      let m = modulations[layer]
      Profile.mark("copy", wait: x)
      for (piece, holder) in zip(pieces, holders[layer]) { piece.parameters.copy(from: holder.parameters) }
      let qkv = preAttention(inputs: x, m[0], m[1])
      // RoPE on q and k in float32: time (at the absolute latent; only differences of
      // positions matter), rows, columns.
      func rotated(_ t: DynamicGraph.AnyTensor) -> DynamicGraph.Tensor<FloatType> {
        DynamicGraph.Tensor<FloatType>(
          from: Functional.cmul(left: t.as(of: Float.self).reshaped(.NHWC(1, seq, H, HD)), right: rot))
      }
      let q = rotated(qkv[0])
      let k = rotated(qkv[1])
      let v = qkv[2].as(of: FloatType.self).reshaped(.NHWC(1, seq, H, HD))
      if let inspect { inspect("layer_\(layer)_v", DynamicGraph.Tensor<Float>(from: v)) }
      let past = kept[layer]
      // Attention keeps float32 intermediates (no `.Float16` flag): half-precision softmax
      // sums cost about 5× the error against the reference, which the recycled latents carry on.
      let attention: DynamicGraph.Tensor<FloatType>
      if let windowedAttention {
        attention = windowedAttention(
          queries: q, keys: past.map(\.keys) + [k], values: past.map(\.values) + [v], frames: F)
      } else {
        let keys = concatenated(past.map(\.keys) + [k], axis: 1)
        let values = concatenated(past.map(\.values) + [v], axis: 1)
        attention = ScaledDotProductAttention(scale: 1 / Float(HD).squareRoot())(
          queries: q, keys: keys, values: values)
      }
      Profile.mark("self-attention", wait: attention)
      let mid = crossQuery(inputs: x, attention.reshaped(.WC(seq, Self.D)), m[2])
      let crossOut = ScaledDotProductAttention(scale: 1 / Float(HD).squareRoot())(
        queries: mid[1].as(of: FloatType.self).reshaped(.NHWC(1, seq, H, HD)), keys: crossKeys[layer],
        values: crossValues[layer]
      ).reshaped(.WC(seq, Self.D))
      Profile.mark("cross", wait: crossOut)
      x = postAttention(inputs: mid[0], crossOut, m[3], m[4], m[5])[0].as(of: Float.self)
      Profile.mark("ffn", wait: x)
      inspect?("layer_\(layer)_out", x)

      // Keep what the router says for the blocks after (cache.py:100-134).
      let action = ReCaVSRRouter.actions[layer]
      if action.capacity > 0 {
        let keep = ReCaVSRRouter.retained(past.map(\.latent) + current, action: action)
        var next = past.filter { keep.contains($0.latent) }
        for latent in keep where latent >= latentOffset {
          let offset = latent - latentOffset
          let range = (offset * tokens)..<((offset + 1) * tokens)
          next.append(
            (latent, k[0..<1, range, 0..<H, 0..<HD].copied(), v[0..<1, range, 0..<H, 0..<HD].copied()))
        }
        kept[layer] = next
      }
      graph.garbageCollect()
    }
    let prediction = head(inputs: x, headModulation[0], headModulation[1])[0].as(of: Float.self)
    inspect?("proj_out", prediction)
    // Unpatchify: column (ky * 2 + kx) * 48 + c.
    let latent = prediction.reshaped(format: .NHWC, shape: [F, gh, gw, 2, 2, C])
      .permuted(0, 1, 3, 2, 4, 5).copied().reshaped(.NHWC(F, h, w, C))
    inspect?("pred", latent)
    let x0 = noise - latent
    recycled = DynamicGraph.Tensor<FloatType>(
      from: x0[(F - ReCaVSRConfig.bodyLatents)..<F, 0..<h, 0..<w, 0..<C].copied())
    if latentOffset == 0 { windowedAttention?.forget(frames: F) }
    latentOffset += F
    return x0
  }

  /// RoPE for a block of `frames` latents from `start`, `[1, frames * tokens, 1, 128]` float32:
  /// per head 22 pairs for time, 21 for rows, 21 for columns, interleaved (cos, sin); frequencies
  /// and angles in float64 (rope.py:11-30, get_1d_rotary_pos_embed with freqs_dtype float64).
  private func rotary(start: Int, frames: Int) -> Tensor<Float> {
    let gh = gridHeight, gw = gridWidth
    let HD = Self.headDimension
    var tensor = Tensor<Float>(.CPU, .NHWC(1, frames * gh * gw, 1, HD))
    let axes = [44, 42, 42]
    let frequencies = axes.map { dimension in
      (0..<(dimension / 2)).map { i in 1 / pow(10_000.0, Double(2 * i) / Double(dimension)) }
    }
    tensor.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: Float.self)
      for f in 0..<frames {
        for y in 0..<gh {
          for x in 0..<gw {
            let token = (f * gh + y) * gw + x
            var pair = 0
            for (axis, position) in [start + f, y, x].enumerated() {
              for frequency in frequencies[axis] {
                let angle = Double(position) * frequency
                out[token * HD + pair * 2] = Float(cos(angle))
                out[token * HD + pair * 2 + 1] = Float(sin(angle))
                pair += 1
              }
            }
          }
        }
      }
    }
    return tensor
  }
}
