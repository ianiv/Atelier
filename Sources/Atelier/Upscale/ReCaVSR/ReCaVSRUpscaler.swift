import CoreGraphics
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// Upscales a clip with ReCaVSR as one stream (inference.py's loop over `block_schedule`): the
/// source stretched to the output size as the reference does (OpenCV bilinear) and padded to
/// multiples of 32, its projection, the DiT a block at a time (21 frames, then 8) against what
/// its layers keep, FlashDecoder, the crop back and the wavelet color fix. Frames are read on
/// demand, in order, and handed out as each block is decoded, so a long clip needs no more
/// memory than a short one.
///
/// Runs on the calling thread; call it on the engine's queue.
nonisolated struct ReCaVSRUpscaler {
  enum Phase {
    case loading, upscaling
  }

  var files: ReCaVSRFiles
  /// The output size: the source's times the scale, any size (the network runs it padded).
  var width: Int
  var height: Int
  var seed: UInt64 = 0
  /// The wavelet color fix against the source (color_fix.py `wavelet_color_fix`).
  var colorFix = true

  var paddedWidth: Int { ReCaVSRRouter.padded(width) }
  var paddedHeight: Int { ReCaVSRRouter.padded(height) }

  /// The output size for a `width`×`height` source at `scale` (video.py:33-44).
  static func outputSize(width: Int, height: Int, scale: Int) -> (width: Int, height: Int) {
    ReCaVSRRouter.outputSize(width: width, height: height, scale: scale)
  }

  /// Blocks the stream runs for `count` frames.
  static func chunks(_ count: Int) -> Int { ReCaVSRRouter.blockCount(count) }

  /// Restores `count` frames, each read with `frame(i)` (in order, at any size), handing each
  /// to `output` as `[1, height, width, 3]` in [-1, 1]. `progress(phase, done, total)` counts
  /// blocks; returning false from `shouldContinue` cancels.
  func run(
    count: Int, frame: (Int) -> CGImage?,
    progress: (Phase, Int, Int) -> Void, shouldContinue: () -> Bool,
    output: (Tensor<FloatType>) throws -> Void
  ) throws {
    precondition(width > 0 && height > 0 && count > 0)
    let blocks = ReCaVSRRouter.blocks(count)
    let Hp = paddedHeight, Wp = paddedWidth
    let h = Hp / 16, w = Wp / 16
    let graph = DynamicGraph()
    var failure: Error?
    ReCaVSRConfig.withAttentionWorkaround {
      graph.withNoGrad {
        do {
          progress(.loading, 0, blocks.count)
          let (projection, denoiser) = try Self.load(files, graph: graph, height: Hp, width: Wp)
          let decoder = try ReCaVSRDecoder(
            graph: graph, checkpoint: ReCaVSRCheckpoint(files.decoder), latentHeight: h, latentWidth: w)
          let fix = colorFix ? FlashVSRImages.ColorFix(graph: graph, width: width, height: height) : nil
          graph.garbageCollect()
          progress(.upscaling, 0, blocks.count)

          for block in blocks {
            guard shouldContinue() else { throw CancellationError() }
            // The block's source frames, the last repeated to fill it (video.py:119-142).
            var originals: [(pixels: [UInt8], width: Int, height: Int)] = []
            var prepared = Tensor<FloatType>(.CPU, .NHWC(block.frames, Hp, Wp, 3))
            for offset in 0..<block.frames {
              if offset < block.valid {
                guard let image = frame(block.start + offset), let rgb = FlashVSRImages.rgb(image) else {
                  throw ProjectError.badImage
                }
                originals.append(rgb)
              }
              let rgb = originals[min(offset, block.valid - 1)]
              Self.prepare(
                Self.bilinear(rgb.pixels, width: rgb.width, height: rgb.height, targetWidth: width, targetHeight: height),
                width: width, height: height, into: &prepared, frame: offset)
            }
            Profile.mark("read+resize")
            let lq = graph.variable(prepared.toGPU(0))
            let rows = projection.next(projection.unshuffled(lq))
            Profile.mark("projection", wait: rows)
            let noise = graph.variable(
              Self.noise(
                latents: block.latentStart..<(block.latentStart + block.latents), height: h, width: w, seed: seed
              ).toGPU(0))
            guard let x0 = try denoiser.next(noise: noise, rows: rows, shouldContinue: shouldContinue) else {
              throw CancellationError()
            }
            Profile.mark("dit", wait: x0)
            // Each latent with the source frames it covers: the stream's first 1, then 4.
            var next = 0
            for i in 0..<block.latents {
              let take = decoder.frameIndex == 0 ? 1 : 4
              let decoded = decoder.decode(
                latent: x0[i..<(i + 1), 0..<h, 0..<w, 0..<48].copied(),
                source: DynamicGraph.Tensor<Float>(from: lq[next..<(next + take), 0..<Hp, 0..<Wp, 0..<3].copied()))
              Profile.mark("decoder", wait: decoded)
              for f in 0..<take where next + f < block.valid {
                var rgb = DynamicGraph.Tensor<FloatType>(
                  from: decoded[f..<(f + 1), 0..<height, 0..<width, 0..<3].copied())
                if let fix {
                  let original = originals[next + f]
                  let reference = graph.variable(
                    FlashVSRImages.tensor(
                      FlashVSRImages.bicubic(
                        original.pixels, width: original.width, height: original.height, targetWidth: width,
                        targetHeight: height),
                      width: width, height: height
                    ).toGPU(0))
                  rgb = fix(rgb, reference: reference)
                }
                Profile.mark("color fix", wait: rgb)
                try output(rgb.rawValue.toCPU())
                Profile.mark("output")
              }
              next += take
            }
            graph.garbageCollect()
            Profile.report()
            progress(.upscaling, block.index + 1, blocks.count)
          }
        } catch {
          failure = error
        }
      }
    }
    if let failure { throw failure }
  }

  /// The source projection and the DiT for a padded `height`×`width`, from the published
  /// weights or the 8-bit copy as `files` says.
  static func load(_ files: ReCaVSRFiles, graph: DynamicGraph, height: Int, width: Int, window: (height: Int, width: Int) = ReCaVSRConfig.window) throws
    -> (ReCaVSRSourceProjection, ReCaVSRDenoiser)
  {
    let prompt = try ReCaVSRCheckpoint(files.prompt)
    func build(_ source: ReCaVSRWeightSource) throws -> (ReCaVSRSourceProjection, ReCaVSRDenoiser) {
      (
        try ReCaVSRSourceProjection(graph: graph, checkpoint: source, height: height, width: width),
        try ReCaVSRDenoiser(
          graph: graph, checkpoint: source, prompt: prompt, height: height, width: width, window: window)
      )
    }
    switch files.weights {
    case .full:
      return try build(ReCaVSRCheckpoint(files.transformer))
    case .eightBit:
      var result: Result<(ReCaVSRSourceProjection, ReCaVSRDenoiser), Error> = .failure(ReCaVSRFiles.Failure.missing)
      graph.openStore(files.eightBitTransformer.path, flags: .readOnly) { store in
        result = Result { try build(ReCaVSRQuantizedSource(store: store)) }
      }
      return try result.get()
    }
  }

  /// `rgb` (interleaved u8, `width`×`height`) stretched to `targetWidth`×`targetHeight` as
  /// OpenCV's `INTER_LINEAR` does for u8: source x = (x + 0.5) · scale − 0.5, clamped at the
  /// edges, weights rounded to 1/2048, rows then columns in integers (OpenCV's `HResizeLinear` and the vectorized
  /// `VResizeLinearVec_32s8u`).
  static func bilinear(_ rgb: [UInt8], width: Int, height: Int, targetWidth: Int, targetHeight: Int) -> [UInt8] {
    func taps(source: Int, target: Int) -> [(index: Int, weights: (Int32, Int32))] {
      let scale = Double(source) / Double(target)
      return (0..<target).map { d in
        var f = Float((Double(d) + 0.5) * scale - 0.5)
        var s = Int(f.rounded(.down))
        f -= Float(s)
        if s < 0 {
          f = 0
          s = 0
        }
        if s >= source - 1 {
          f = 0
          s = source - 1
        }
        // saturate_cast<short> rounds to nearest (cvRound).
        return (s, (Int32(((1 - f) * 2048).rounded(.toNearestOrEven)), Int32((f * 2048).rounded(.toNearestOrEven))))
      }
    }
    let xs = taps(source: width, target: targetWidth)
    let ys = taps(source: height, target: targetHeight)
    // Horizontal pass into integers (weights × 2048).
    var rows = [Int32](repeating: 0, count: height * targetWidth * 3)
    for y in 0..<height {
      for (x, tap) in xs.enumerated() {
        let a = (y * width + tap.index) * 3
        let b = (y * width + min(tap.index + 1, width - 1)) * 3
        for c in 0..<3 {
          rows[(y * targetWidth + x) * 3 + c] = Int32(rgb[a + c]) * tap.weights.0 + Int32(rgb[b + c]) * tap.weights.1
        }
      }
    }
    var out = [UInt8](repeating: 0, count: targetHeight * targetWidth * 3)
    for (y, tap) in ys.enumerated() {
      let a = tap.index * targetWidth * 3
      let b = min(tap.index + 1, height - 1) * targetWidth * 3
      for i in 0..<(targetWidth * 3) {
        // OpenCV's vectorized form (VResizeLinearVec_32s8u): each row's sum shifted down by 4,
        // multiplied keeping the high 16 bits, then rounded by 4.
        let value = (((Int(rows[a + i] >> 4) * Int(tap.weights.0)) >> 16) + ((Int(rows[b + i] >> 4) * Int(tap.weights.1)) >> 16) + 2) >> 2
        out[y * targetWidth * 3 + i] = UInt8(clamping: value)
      }
    }
    return out
  }

  /// A stretched frame into `tensor` (`[frames, Hp, Wp, 3]`) at `frame`: `u / 127.5 − 1`, padded
  /// right and bottom to the padded size by reflection (by repeating the edge when the pad is
  /// as large as the frame) (video.py:133-142).
  static func prepare(
    _ rgb: [UInt8], width: Int, height: Int, into tensor: inout Tensor<FloatType>, frame: Int
  ) {
    let Hp = tensor.shape[1], Wp = tensor.shape[2]
    func source(_ i: Int, size: Int, padded: Int) -> Int {
      guard i >= size else { return i }
      // The reference pads columns first, then rows, each its own way.
      if padded - size < size { return 2 * (size - 1) - i }
      return size - 1
    }
    tensor.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: FloatType.self)
      let base = frame * Hp * Wp * 3
      for y in 0..<Hp {
        let sy = source(y, size: height, padded: Hp)
        for x in 0..<Wp {
          let sx = source(x, size: width, padded: Wp)
          for c in 0..<3 {
            out[base + (y * Wp + x) * 3 + c] = FloatType(Float(rgb[(sy * width + sx) * 3 + c]) / 127.5 - 1)
          }
        }
      }
    }
  }

  /// Standard normal noise `[latents, h, w, 48]`, each latent from its own seed, so a latent gets
  /// the same noise however the stream is cut (as `FlashVSRUpscaler.noise`).
  static func noise(latents: Range<Int>, height: Int, width: Int, seed: UInt64) -> Tensor<Float> {
    let channels = ReCaVSRConfig.latentChannels
    var tensor = Tensor<Float>(.CPU, .NHWC(latents.count, height, width, channels))
    let perLatent = height * width * channels
    tensor.withUnsafeMutableBytes { raw in
      let values = raw.bindMemory(to: Float.self)
      for (slot, latent) in latents.enumerated() {
        var state = seed ^ (0x9e37_79b9_7f4a_7c15 &* UInt64(latent + 1))
        func next() -> UInt64 {
          state &+= 0x9e37_79b9_7f4a_7c15
          var z = state
          z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
          z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
          return z ^ (z >> 31)
        }
        func uniform() -> Double { (Double(next() >> 11) + 0.5) / Double(1 << 53) }
        var i = 0
        while i < perLatent {
          let r = (-2 * log(uniform())).squareRoot()
          let theta = 2 * Double.pi * uniform()
          values[slot * perLatent + i] = Float(r * cos(theta))
          if i + 1 < perLatent { values[slot * perLatent + i + 1] = Float(r * sin(theta)) }
          i += 2
        }
      }
    }
    return tensor
  }
}

nonisolated extension Profile {
  /// Marks a step, first waiting for the GPU to finish `tensor` when profiling
  /// (FLASHVSR_PROFILE=1), so the time lands on the step that queued the work.
  static func mark<T: TensorNumeric>(_ name: String, wait tensor: DynamicGraph.Tensor<T>) {
    guard enabled else { return }
    FlashVSRUpscaler.wait(tensor)
    mark(name)
  }
}
