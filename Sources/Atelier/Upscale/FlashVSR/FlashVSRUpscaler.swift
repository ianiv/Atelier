import CoreGraphics
import Diffusion
import Foundation
import NNC

/// Upscales a clip with FlashVSR+ as one stream: the source stretched to the output size, its
/// projection, the denoiser a chunk of 16 frames at a time against the windows it keeps, the
/// tiny decoder and the wavelet color fix. Frames are read on demand, in order, and handed out
/// as each chunk is decoded, so a long clip needs no more memory than a short one.
///
/// Runs on the calling thread; call it on the engine's queue.
struct FlashVSRUpscaler {
  enum Phase {
    case loading, upscaling
  }

  var files: FlashVSRFiles
  /// The output size: multiples of 128.
  var width: Int
  var height: Int
  var seed: UInt64 = 0

  /// The output size for a `width`×`height` source at 4×, to the 128-pixel grid (rounded to
  /// the nearest, so the aspect barely changes).
  static func outputSize(width: Int, height: Int, scale: Int = 4) -> (width: Int, height: Int) {
    func grid(_ value: Int) -> Int { max(128, Int((Double(value * scale) / 128).rounded()) * 128) }
    return (grid(width), grid(height))
  }

  /// Chunks the stream runs for `count` frames. Chunk c reads source frames through 16c + 16
  /// and restores them through 16c + 12 (the decoder looks 4 ahead), so the end is padded with
  /// the last frame until every frame is restored.
  static func chunks(_ count: Int) -> Int {
    count <= 13 ? 1 : 1 + (count - 13 + 15) / 16
  }

  /// Restores `count` frames, each read with `frame(i)` (in order, at any size), handing each
  /// to `output` as `[1, height, width, 3]` in [-1, 1]. `progress(phase, done, total)` counts
  /// chunks; returning false from `shouldContinue` cancels.
  func run(
    count: Int, frame: (Int) -> CGImage?,
    progress: (Phase, Int, Int) -> Void, shouldContinue: () -> Bool,
    output: (Tensor<FloatType>) throws -> Void
  ) throws {
    precondition(width % 128 == 0 && height % 128 == 0 && count > 0)
    let chunks = Self.chunks(count)
    let latentHeight = height / 8, latentWidth = width / 8
    let graph = DynamicGraph()
    var failure: Error?
    graph.withNoGrad {
      do {
        progress(.loading, 0, chunks)
        let projection = try FlashVSRSourceProjection(
          graph: graph, checkpoint: FlashVSRCheckpoint(files.sourceProjection),
          gridHeight: height / 16, gridWidth: width / 16)
        let denoiser = try FlashVSRDenoiser(
          graph: graph, checkpoint: FlashVSRCheckpoint(files.dit),
          prompt: FlashVSRCheckpoint(files.prompt), variant: files.variant, height: height,
          width: width)
        let decoder = try FlashVSRTinyDecoder(
          graph: graph, checkpoint: FlashVSRCheckpoint(files.tinyDecoder),
          latentHeight: latentHeight, latentWidth: latentWidth)
        let colorFix = FlashVSRImages.ColorFix(graph: graph, width: width, height: height)
        graph.garbageCollect()

        // The source at the output size, read once each, kept while something still needs it.
        var sources: [Int: [UInt8]] = [:]
        var readThrough = -1
        func source(_ index: Int) throws -> [UInt8] {
          let index = min(index, count - 1)
          if let cached = sources[index] { return cached }
          precondition(index > readThrough, "frames are read in order")
          guard let image = frame(index), let rgb = FlashVSRImages.rgb(image) else {
            throw ProjectError.badImage
          }
          Profile.mark("misc")
          defer { Profile.mark("bicubic") }
          let resized = FlashVSRImages.bicubic(
            rgb.pixels, width: rgb.width, height: rgb.height, targetWidth: width,
            targetHeight: height)
          sources[index] = resized
          readThrough = index
          return resized
        }
        func unshuffled(_ index: Int) throws -> DynamicGraph.Tensor<FloatType> {
          graph.variable(
            FlashVSRSourceProjection.unshuffled(try source(index), width: width, height: height)
              .toGPU(0))
        }

        projection.open(try unshuffled(0))
        var emitted = 0
        for chunk in 0..<chunks {
          guard shouldContinue() else { throw CancellationError() }
          // Rows for latent frames 4c ..< 4c + 4: each reads source frames 4t + 1 ... 4t + 4.
          var rows: [DynamicGraph.Tensor<FloatType>] = []
          for t in (4 * chunk)..<(4 * chunk + 4) {
            let frames = concatenated(try (1...4).map { try unshuffled(4 * t + $0) })
            Profile.mark("unshuffle")
            rows.append(projection.next(frames))
            // Wait for the GPU between steps, so queued work doesn't hold memory.
            FlashVSRUpscaler.wait(rows.last!)
            Profile.mark("projection")
          }
          let noise = graph.variable(
            Self.noise(
              frames: (4 * chunk)..<(4 * chunk + 4), height: latentHeight, width: latentWidth,
              seed: seed
            ).toGPU(0))
          Profile.mark("rows")
          guard
            let latent = try denoiser.next(
              noise: noise, rows: concatenated(rows), shouldContinue: shouldContinue)
          else { throw CancellationError() }
          let latents = DynamicGraph.Tensor<FloatType>(from: latent)
          // Decode each latent frame with the source frames it covers.
          for offset in 0..<4 {
            let k = 4 * chunk + offset
            let covered = try (0..<4).map { try source(max(0, 4 * k - 3 + $0)) }
            Profile.mark("misc")
            let packed = graph.variable(
              FlashVSRTinyDecoder.packed(
                covered, latentHeight: latentHeight, latentWidth: latentWidth
              ).toGPU(0))
            let z = latents[offset..<(offset + 1), 0..<latentHeight, 0..<latentWidth, 0..<16]
              .copied()
            Profile.mark("pack")
            let decodedFrames = decoder.decode(latent: z, source: packed)
            if let last = decodedFrames.last { FlashVSRUpscaler.wait(last) }
            Profile.mark("decode")
            for decoded in decodedFrames {
              defer { emitted += 1 }
              guard emitted < count else { continue }
              let reference = graph.variable(
                FlashVSRImages.tensor(try source(emitted), width: width, height: height).toGPU(0))
              let fixed = colorFix(decoded, reference: reference)
              let cpu = fixed.rawValue.toCPU()
              Profile.mark("colorfix")
              try output(cpu)
              Profile.mark("output")
            }
          }
          // Source frames before the next chunk's first are done with.
          let firstNeeded = max(0, 4 * (4 * chunk + 4) - 3)
          for index in sources.keys where index < min(firstNeeded, emitted) {
            sources[index] = nil
          }
          graph.garbageCollect()
          Profile.report()
          progress(.upscaling, chunk + 1, chunks)
        }
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
  }

  /// Waits for the GPU to finish `tensor` (and what was queued before it).
  static func wait<T: TensorNumeric>(_ tensor: DynamicGraph.Tensor<T>) {
    let shape = tensor.shape
    _ = tensor.reshaped(.C(shape.reduce(1, *)))[0..<1].copied().rawValue.toCPU()
  }

  /// Standard normal noise `[frames, h, w, 16]`, each latent frame from its own seed, so a frame
  /// gets the same noise however the stream is cut.
  static func noise(frames: Range<Int>, height: Int, width: Int, seed: UInt64) -> Tensor<Float> {
    var tensor = Tensor<Float>(.CPU, .NHWC(frames.count, height, width, 16))
    let perFrame = height * width * 16
    tensor.withUnsafeMutableBytes { raw in
      let values = raw.bindMemory(to: Float.self)
      for (slot, frame) in frames.enumerated() {
        var state = seed ^ (0x9e37_79b9_7f4a_7c15 &* UInt64(frame + 1))
        func next() -> UInt64 {
          state &+= 0x9e37_79b9_7f4a_7c15
          var z = state
          z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
          z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
          return z ^ (z >> 31)
        }
        func uniform() -> Double { (Double(next() >> 11) + 0.5) / Double(1 << 53) }
        var i = 0
        while i < perFrame {
          // Box–Muller: two normals per pair of uniforms.
          let r = (-2 * log(uniform())).squareRoot()
          let theta = 2 * Double.pi * uniform()
          values[slot * perFrame + i] = Float(r * cos(theta))
          if i + 1 < perFrame { values[slot * perFrame + i + 1] = Float(r * sin(theta)) }
          i += 2
        }
      }
    }
    return tensor
  }
}
