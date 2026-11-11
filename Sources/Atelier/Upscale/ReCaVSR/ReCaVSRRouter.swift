import Foundation

/// ReCaVSR's streaming bookkeeping, kept free of tensors so it can be tested alone: which RGB
/// frames each block reads, which latents each DiT layer keeps for the blocks after it (its
/// learned "static KV router"), where the rolling temporal RoPE starts, and the spatial window
/// each query token reads.
nonisolated enum ReCaVSRRouter {
  /// What a layer keeps after each block: its most recent `recent` latents, plus the last two
  /// anchors when `anchors` (runtime/cache.py:11-19).
  struct Action: Equatable, Sendable {
    var recent: Int
    var anchors: Bool

    static let none = Action(recent: 0, anchors: false)
    static let recent1 = Action(recent: 1, anchors: false)
    static let recent2 = Action(recent: 2, anchors: false)
    static let recent4 = Action(recent: 4, anchors: false)
    static let anchor = Action(recent: 0, anchors: true)
    static let recent2Anchor = Action(recent: 2, anchors: true)
    static let recent4Anchor = Action(recent: 4, anchors: true)

    /// Latents the layer can hold (`FixedKVCache.capacity`, cache.py:61-62).
    var capacity: Int { recent + (anchors ? ReCaVSRRouter.anchorCapacity : 0) }
  }

  /// The anchors: latents 5, 11, 17, … (model_config.json `static_kv_router.anchor`).
  static let anchorInitial = 5
  static let anchorStride = 6
  static let anchorCapacity = 2

  /// Each DiT layer's action (model_config.json `layer_actions`).
  static let actions: [Action] = [
    .none, .none, .recent1, .none, .recent2, .none, .recent2, .recent4, .none, .recent2Anchor,
    .recent4, .recent4Anchor, .recent2, .recent4Anchor, .anchor, .recent4Anchor, .recent2,
    .recent4Anchor, .recent2Anchor, .recent4, .recent2, .none, .recent2Anchor, .recent2, .none,
    .recent2, .none, .recent1, .none, .none,
  ]

  static func isAnchor(_ latent: Int) -> Bool {
    latent >= anchorInitial && (latent - anchorInitial) % anchorStride == 0
  }

  /// The latents a layer keeps out of `candidates` (what it kept before, then the block just
  /// run, ascending): the last `recent` and the last two anchors, in order
  /// (`retained_frames`, cache.py:31-41). A latent left out is never kept again.
  static func retained(_ candidates: [Int], action: Action) -> [Int] {
    var keep = Set(action.recent > 0 ? candidates.suffix(action.recent) : [])
    if action.anchors {
      keep.formUnion(candidates.filter(isAnchor).suffix(anchorCapacity))
    }
    return candidates.filter(keep.contains)
  }

  // MARK: - Blocks

  /// A block of the stream: RGB frames `start ..< start + valid` of the clip, padded to
  /// `frames` by repeating the last (`block_schedule`, video.py:106-116).
  struct Block: Equatable, Sendable {
    var index: Int
    var start: Int
    var valid: Int
    var frames: Int
    /// Its first latent and how many it makes.
    var latentStart: Int { index == 0 ? 0 : ReCaVSRConfig.prefixLatents + ReCaVSRConfig.bodyLatents * (index - 1) }
    var latents: Int { index == 0 ? ReCaVSRConfig.prefixLatents : ReCaVSRConfig.bodyLatents }
  }

  /// The blocks a clip of `count` frames streams through: 21 frames, then 8 at a time.
  static func blocks(_ count: Int) -> [Block] {
    precondition(count > 0)
    var blocks: [Block] = []
    var start = 0
    while start < count {
      let frames = blocks.isEmpty ? ReCaVSRConfig.prefixFrames : ReCaVSRConfig.bodyFrames
      let valid = min(frames, count - start)
      blocks.append(Block(index: blocks.count, start: start, valid: valid, frames: frames))
      start += valid
    }
    return blocks
  }

  /// Blocks for `count` frames: 1 + ⌈(count − 21) / 8⌉.
  static func blockCount(_ count: Int) -> Int {
    1 + (max(0, count - ReCaVSRConfig.prefixFrames) + ReCaVSRConfig.bodyFrames - 1) / ReCaVSRConfig.bodyFrames
  }

  // MARK: - RoPE

  /// The rolling temporal RoPE's origin for a block of `frames` latents from `start`: positions
  /// are latent − origin, kept inside the 22 it was trained on (`RollingRoPE.positions`,
  /// rope.py:85-101). Only differences of positions reach attention, so the DiT can rotate by
  /// the absolute latent instead.
  static func ropeOrigin(start: Int, frames: Int) -> Int {
    max(0, start + frames - ReCaVSRConfig.ropeWindow)
  }

  // MARK: - Source projection

  /// The source frames (clip indices, before clamping at 0) the strided causal convolution's
  /// output `output` reads: 2j − 3 … 2j, the clip's start padded with frame 0
  /// (`CausalConv3d.forward_streaming`, models/lq_proj.py:75-139).
  static func convolutionInputs(_ output: Int) -> ClosedRange<Int> {
    (2 * output - 3)...(2 * output)
  }

  // MARK: - Spatial window

  /// The first row (or column) of the window a query at `position` reads on a grid of `size`
  /// tokens, the window `window` wide: centered, clamped inside the grid
  /// (kernels/local_attention.py:98-101, window = min(size, window) per local_attention.py:213).
  static func windowStart(_ position: Int, size: Int, window: Int) -> Int {
    let window = min(size, window)
    return min(max(position - window / 2, 0), size - window)
  }

  // MARK: - Sizes

  /// The output size for a `width`×`height` source at `scale`: each side rounded half up
  /// (`scaled_size`, video.py:33-44). The network runs it padded to multiples of 32.
  static func outputSize(width: Int, height: Int, scale: Int) -> (width: Int, height: Int) {
    (width * scale, height * scale)
  }

  /// `value` padded up to a multiple of 32 (inference.py:202-206).
  static func padded(_ value: Int) -> Int {
    (value + ReCaVSRConfig.tokenStride - 1) / ReCaVSRConfig.tokenStride * ReCaVSRConfig.tokenStride
  }
}
