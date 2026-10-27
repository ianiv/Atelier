import CoreGraphics
import DataModels
import Diffusion
import Foundation
import ModelZoo
import NNC

/// Upscales a clip with SeedVR2 over many frames at once, so the model sees motion and the result
/// doesn't shimmer. The engine's own path (`LocalImageGenerator`) runs SeedVR2 one frame at a
/// time, so this builds the same networks from Diffusion's public pieces instead:
///
/// 1. The 3D VAE encodes the frames, resized to the output size, into latents: one for the first
///    frame, then one per four frames. It runs a few frames at a time; each chunk after the first
///    starts with the frame before it, whose latent is dropped, so the causal convolutions see the
///    frames they would have seen in one pass.
/// 2. The DiT restores overlapping windows of latents in one step (noise minus its velocity) and
///    the windows are cross-faded where they overlap.
/// 3. The 3D VAE decodes the latents back four at a time, after reading the two before (whose
///    frames are dropped), in overlapping spatial tiles.
///
/// Runs on the calling thread; call it on the engine's queue.
struct SeedVR2Restorer {
  enum Phase {
    case encoding, restoring, decoding
  }

  enum Failure: LocalizedError {
    case notSeedVR2, tooFewFrames, missingEmbedding

    var errorDescription: String? {
      switch self {
      case .notSeedVR2: "That model isn't SeedVR2."
      case .tooFewFrames: "SeedVR2 needs a clip of at least 5 frames."
      case .missingEmbedding: "The SeedVR2 model file has no prompt embedding."
      }
    }
  }

  /// The SeedVR2 checkpoint (`seedvr2_*.ckpt`).
  var model: String
  /// Output size in pixels, multiples of 16.
  var width: Int
  var height: Int
  var seed: UInt32
  /// Pixels the VAE takes in one pass, summed over its frames.
  var vaePixelBudget = 6_000_000
  /// DiT tokens (2x2 latent patches, summed over frames) in one window.
  var tokenBudget = 48_000

  /// Restores `count` frames, each read with `frame(i)` at any size, and returns them at the
  /// output size as `[1, height, width, 3]` tensors in [-1, 1]. `progress(phase, done, total)` is
  /// called as work completes; returning false from `shouldContinue` cancels.
  func run(
    count: Int, frame: (Int) -> CGImage?,
    progress: (Phase, Int, Int) -> Void, shouldContinue: () -> Bool
  ) throws -> [Tensor<FloatType>] {
    let version = ModelZoo.versionForModel(model)
    guard version == .seedvr2_3b || version == .seedvr2_7b else { throw Failure.notSeedVR2 }
    guard count >= 5 else { throw Failure.tooFewFrames }
    precondition(width % 16 == 0 && height % 16 == 0)
    let modelPath = ModelZoo.filePathForModelDownloaded(model)
    let vaePath = ModelZoo.filePathForModelDownloaded(
      ModelZoo.autoencoderForModel(model) ?? "seedvr2_vae_f16.ckpt")
    let scaling = ModelZoo.latentsScalingForModel(model)
    let externalData: DynamicGraph.Store.Codec = .externalData(
      DeviceCapability.deviceProperties.isFreadPreferred ? .fread : .mmap)
    let usesFlashAttention = DeviceCapability.isMFAEnabled.load(ordering: .acquiring) > 0

    // The causal VAE maps 4n + 1 frames to n + 1 latents; pad with the last frame to fit.
    let latentCount = (count - 1 + 3) / 4 + 1
    let latentHeight = height / 8
    let latentWidth = width / 8
    let channels = 16
    let vaeGroups = max(1, vaePixelBudget / (4 * width * height))
    let windowLength = min(
      latentCount, max(2, min(12, tokenBudget / ((latentHeight / 2) * (latentWidth / 2)))))
    let windowOverlap = windowLength >= 4 ? 2 : (windowLength >= 2 ? 1 : 0)
    let windows = Self.windowStarts(count: latentCount, length: windowLength, overlap: windowOverlap)
    let encodeChunks = Self.chunks(latents: latentCount, groups: vaeGroups)
    let decodeChunks = Self.decodeChunks(
      latents: latentCount, length: Self.decodeLength, context: Self.decodeContext)
    let total = encodeChunks.count + windows.count + decodeChunks.count
    var done = 0

    let graph = DynamicGraph()
    var results: [Tensor<FloatType>] = []
    var failure: Error?
    graph.withNoGrad {
      // 1. Encode.
      var latents = graph.variable(
        .GPU(0), .NHWC(latentCount, latentHeight, latentWidth, channels), of: FloatType.self)
      var encoders: [Int: Model] = [:]
      for (start, end) in encodeChunks {
        guard shouldContinue() else {
          failure = CancellationError()
          return
        }
        // Frames 4 * start ... 4 * end; the first is context unless the chunk starts the clip.
        let depth = 4 * (end - start) + 1
        var pixels = Tensor<FloatType>(.CPU, .NHWC(depth, height, width, 3))
        for i in 0..<depth {
          let index = min(4 * start + i, count - 1)
          guard let image = frame(index), let tensor = Self.resized(image, width: width, height: height)
          else {
            failure = ProjectError.badImage
            return
          }
          pixels[i..<(i + 1), 0..<height, 0..<width, 0..<3] = tensor
        }
        let x = graph.variable(pixels.toGPU(0))
        let encoder: Model
        if let cached = encoders[depth] {
          encoder = cached
        } else {
          encoder = SeedVR2Encoder3D(
            startDepth: depth, startHeight: height, startWidth: width,
            usesFlashAttention: usesFlashAttention && width * height >= 256 * 176)
          encoder.maxConcurrency = .limit(4)
          encoder.compile(inputs: x)
          graph.openStore(vaePath, flags: .readOnly, externalStore: vaePath + "-tensordata") {
            $0.read("encoder", model: encoder, codec: [.jit, externalData])
          }
          encoders[depth] = encoder
        }
        let parameters = encoder(inputs: x)[0].as(of: FloatType.self)
        let mean = parameters[0..<(end - start + 1), 0..<latentHeight, 0..<latentWidth, 0..<channels]
          .copied()
        let scaled = Self.scale(mean, scaling)
        let first = start == 0 ? 0 : 1
        latents[(start + first)..<(end + 1), 0..<latentHeight, 0..<latentWidth, 0..<channels] =
          scaled[first..<(end - start + 1), 0..<latentHeight, 0..<latentWidth, 0..<channels]
        done += 1
        progress(.encoding, done, total)
      }
      encoders = [:]

      // 2. Restore, one step per window.
      guard let text = Self.positiveEmbedding(graph: graph, path: modelPath, externalData: externalData)
      else {
        failure = Failure.missingEmbedding
        return
      }
      let textLength = text.shape[0]
      let configuration: SeedVR2DiTConfiguration = version == .seedvr2_7b ? ._7B : ._3B
      let dit = SeedVR2DiT(
        configuration: configuration, frames: windowLength, latentHeight: latentHeight,
        latentWidth: latentWidth, textLength: textLength,
        usesFlashAttention: usesFlashAttention ? .scaleMerged : .none)
      let timestep = graph.variable(
        Tensor<FloatType>(
          from: SeedVR2TimeEmbedding(
            timestep: 1_000, batchSize: 1, embeddingSize: 256, maxPeriod: 10_000)
        ).toGPU(0))
      var conditions: [DynamicGraph.AnyTensor] = [timestep, text]
      for shifted in [false, true] {
        conditions.append(
          graph.variable(
            Tensor<FloatType>(
              from: SeedVR2RotaryPositionEmbedding(
                configuration: configuration, frames: windowLength, latentHeight: latentHeight,
                latentWidth: latentWidth, textLength: textLength, shifted: shifted)
            ).toGPU(0)))
      }
      let indexer = SeedVR2WindowAttentionIndexer(
        frames: windowLength, latentHeight: latentHeight, latentWidth: latentWidth,
        textLength: textLength)
      for index in [
        indexer.rasterToWindowIndex, indexer.windowToShiftedIndex, indexer.shiftedToWindowIndex,
        indexer.windowToRasterIndex, indexer.shiftedToRasterIndex, indexer.regularAttentionIndex,
        indexer.shiftedAttentionIndex, indexer.regularAttentionToVideoIndex,
        indexer.shiftedAttentionToVideoIndex, indexer.regularAttentionToTextIndex,
        indexer.shiftedAttentionToTextIndex, indexer.regularSequenceOffsets,
        indexer.shiftedSequenceOffsets,
      ] {
        conditions.append(graph.variable(index.toGPU(0)))
      }

      DynamicGraph.setSeed(seed)
      let noise = graph.variable(
        .GPU(0), .NHWC(latentCount, latentHeight, latentWidth, channels), of: FloatType.self)
      noise.randn(std: 1, mean: 0)
      let mask = graph.variable(
        .GPU(0), .NHWC(windowLength, latentHeight, latentWidth, 1), of: FloatType.self)
      mask.full(1)
      var restored = graph.variable(
        .GPU(0), .NHWC(latentCount, latentHeight, latentWidth, channels), of: FloatType.self)
      restored.full(0)
      var weights = [Float](repeating: 0, count: latentCount)
      var compiled = false
      for (windowIndex, start) in windows.enumerated() {
        guard shouldContinue() else {
          failure = CancellationError()
          return
        }
        let range = start..<(start + windowLength)
        let windowNoise = noise[range, 0..<latentHeight, 0..<latentWidth, 0..<channels].copied()
        var input = graph.variable(
          .GPU(0), .NHWC(windowLength, latentHeight, latentWidth, 2 * channels + 1),
          of: FloatType.self)
        input[0..<windowLength, 0..<latentHeight, 0..<latentWidth, 0..<channels] = windowNoise
        input[0..<windowLength, 0..<latentHeight, 0..<latentWidth, channels..<(2 * channels)] =
          latents[range, 0..<latentHeight, 0..<latentWidth, 0..<channels]
        input[
          0..<windowLength, 0..<latentHeight, 0..<latentWidth, (2 * channels)..<(2 * channels + 1)] =
          mask
        let x = input.reshaped(.WC(windowLength * latentHeight * latentWidth, 2 * channels + 1))
        if !compiled {
          dit.maxConcurrency = .limit(4)
          dit.compile(inputs: [x] + conditions)
          graph.openStore(modelPath, flags: .readOnly, externalStore: modelPath + "-tensordata") {
            $0.read("dit", model: dit, codec: [.jit, .q6p, .q8p, .ezm7, .i8x, externalData])
          }
          compiled = true
        }
        let velocity = dit(inputs: x, conditions)[0].as(of: FloatType.self)
          .reshaped(.NHWC(windowLength, latentHeight, latentWidth, channels))
        // Rectified flow at sigma 1: the clean latent is the noise minus the predicted velocity.
        let clean = windowNoise - velocity
        let ramp = Self.ramp(
          length: windowLength, overlap: windowOverlap, isFirst: windowIndex == 0,
          isLast: windowIndex == windows.count - 1)
        for (offset, weight) in ramp.enumerated() {
          let frameIndex = start + offset
          restored[frameIndex..<(frameIndex + 1), 0..<latentHeight, 0..<latentWidth, 0..<channels] =
            restored[frameIndex..<(frameIndex + 1), 0..<latentHeight, 0..<latentWidth, 0..<channels]
            + weight * clean[offset..<(offset + 1), 0..<latentHeight, 0..<latentWidth, 0..<channels]
          weights[frameIndex] += weight
        }
        done += 1
        progress(.restoring, done, total)
      }
      for (frameIndex, weight) in weights.enumerated() where weight > 0 && weight != 1 {
        restored[frameIndex..<(frameIndex + 1), 0..<latentHeight, 0..<latentWidth, 0..<channels] =
          (1 / weight)
          * restored[frameIndex..<(frameIndex + 1), 0..<latentHeight, 0..<latentWidth, 0..<channels]
      }
      latents = Self.unscale(restored, scaling)
      graph.garbageCollect()

      // 3. Decode, in overlapping spatial tiles of one size: past about a megapixel a whole chunk
      // overflows NNC's 32-bit tensor sizes (5 frames of 256-channel features at half the output
      // size), and the 3D decoder is built for one input size.
      let tileHeight = min(latentHeight, Self.decodeTile)
      let tileWidth = min(latentWidth, Self.decodeTile)
      let tileRows = Self.windowStarts(
        count: latentHeight, length: tileHeight, overlap: Self.decodeTileOverlap)
      let tileColumns = Self.windowStarts(
        count: latentWidth, length: tileWidth, overlap: Self.decodeTileOverlap)
      var decoders: [Int: Model] = [:]
      for (context, start, end) in decodeChunks {
        guard shouldContinue() else {
          failure = CancellationError()
          return
        }
        let depth = end - context + 1
        let frames = 4 * (depth - 1) + 1
        let decoder: Model
        if let cached = decoders[depth] {
          decoder = cached
        } else {
          // Chunks at the clip's ends are shorter; keep one decoder's weights loaded at a time.
          decoders = [:]
          graph.garbageCollect()
          decoder = SeedVR2Decoder3D(
            startDepth: depth, startHeight: tileHeight, startWidth: tileWidth,
            usesFlashAttention: usesFlashAttention && tileWidth * tileHeight >= 256 * 176)
          decoder.maxConcurrency = .limit(4)
          decoder.compile(
            inputs: latents[0..<depth, 0..<tileHeight, 0..<tileWidth, 0..<channels].copied())
          graph.openStore(vaePath, flags: .readOnly, externalStore: vaePath + "-tensordata") { store in
            store.read("decoder", model: decoder, codec: [.jit, externalData]) {
              name, dataType, _, shape in
              Self.paddedOutputChannels(
                name: name, dataType: dataType, shape: shape, store: store,
                externalData: externalData)
            }
          }
          decoders[depth] = decoder
        }
        var sum = [Float](repeating: 0, count: frames * height * width * 3)
        var weightSum = [Float](repeating: 0, count: height * width)
        for (row, y) in tileRows.enumerated() {
          let rowRamp = Self.ramp(
            length: tileHeight * 8, overlap: Self.decodeTileOverlap * 8, isFirst: row == 0,
            isLast: row == tileRows.count - 1)
          for (column, x) in tileColumns.enumerated() {
            let columnRamp = Self.ramp(
              length: tileWidth * 8, overlap: Self.decodeTileOverlap * 8, isFirst: column == 0,
              isLast: column == tileColumns.count - 1)
            let z = latents[
              context..<(end + 1), y..<(y + tileHeight), x..<(x + tileWidth), 0..<channels
            ].copied()
            let tile = Tensor<Float>(
              from: decoder(inputs: z)[0].as(of: FloatType.self).rawValue.toCPU())
            Self.accumulate(
              tile, into: &sum, weights: &weightSum, at: (y * 8, x * 8), size: (height, width),
              ramps: (rowRamp, columnRamp))
          }
        }
        var pixels = Tensor<FloatType>(.CPU, .NHWC(frames, height, width, 3))
        pixels.withUnsafeMutableBytes { raw in
          let values = raw.bindMemory(to: FloatType.self)
          for i in 0..<(frames * height * width) {
            let weight = weightSum[i % (height * width)]
            for c in 0..<3 { values[i * 3 + c] = FloatType(sum[i * 3 + c] / weight) }
          }
        }
        // The context latents' frames (the first latent makes one frame, the rest four each).
        let dropped = start == 0 ? 0 : 1 + 4 * (start - 1 - context)
        for i in dropped..<frames where results.count < count {
          results.append(pixels[i..<(i + 1), 0..<height, 0..<width, 0..<3].copied())
        }
        done += 1
        progress(.decoding, done, total)
      }
    }
    if let failure { throw failure }
    return results
  }

  /// Decoder tiles, in latents (384 pixels), and how much neighbors overlap (64 pixels). Small
  /// enough that 21 frames of one fit in a few gigabytes.
  static let decodeTile = 48
  static let decodeTileOverlap = 8
  /// Latents the decoder makes frames for in one pass, and the ones before them it reads first
  /// (and drops): with only one, the causal decoder starts each pass afresh and the clip jumps
  /// every four frames.
  static let decodeLength = 4
  static let decodeContext = 2

  /// Latent ranges the decoder takes in one pass: frames for `start...end`, reading from
  /// `context` (up to `context` latents before `start`).
  static func decodeChunks(latents: Int, length: Int, context: Int) -> [(
    context: Int, start: Int, end: Int
  )] {
    var chunks: [(context: Int, start: Int, end: Int)] = []
    var start = 0
    while start < latents {
      let end = min(start + length, latents) - 1
      chunks.append((max(0, start - context), start, end))
      start = end + 1
    }
    return chunks
  }

  /// Adds a decoded tile (`[frames, h, w, channels]`, at pixel `origin`) into `sum` and its blend
  /// weights (`rows[y] * columns[x]`) into `weights`, both over the whole `size`.
  private static func accumulate(
    _ tile: Tensor<Float>, into sum: inout [Float], weights: inout [Float],
    at origin: (y: Int, x: Int), size: (height: Int, width: Int),
    ramps: (rows: [Float], columns: [Float])
  ) {
    let shape = tile.shape
    let (frames, tileHeight, tileWidth, tileChannels) = (shape[0], shape[1], shape[2], shape[3])
    tile.withUnsafeBytes { raw in
      let values = raw.bindMemory(to: Float.self)
      for y in 0..<tileHeight {
        for x in 0..<tileWidth {
          let weight = ramps.rows[y] * ramps.columns[x]
          let pixel = (origin.y + y) * size.width + origin.x + x
          weights[pixel] += weight
          for f in 0..<frames {
            let source = ((f * tileHeight + y) * tileWidth + x) * tileChannels
            let target = (f * size.height * size.width + pixel) * 3
            for c in 0..<3 { sum[target + c] += weight * values[source + c] }
          }
        }
      }
    }
  }

  /// Latent ranges `start...end` the VAE takes in one pass; consecutive ranges share their ends.
  static func chunks(latents: Int, groups: Int) -> [(Int, Int)] {
    var chunks: [(Int, Int)] = []
    var start = 0
    while start < latents - 1 {
      let end = min(start + groups, latents - 1)
      chunks.append((start, end))
      start = end
    }
    return chunks
  }

  /// Where each DiT window starts: `length` latents, overlapping by at least `overlap`, the last
  /// ending at the clip's end.
  static func windowStarts(count: Int, length: Int, overlap: Int) -> [Int] {
    guard count > length else { return [0] }
    var starts: [Int] = []
    var start = 0
    while start + length < count {
      starts.append(start)
      start += max(length - overlap, 1)
    }
    starts.append(count - length)
    return starts
  }

  /// A window's blend weights: rising over the overlap at its start, falling over the end.
  static func ramp(length: Int, overlap: Int, isFirst: Bool, isLast: Bool) -> [Float] {
    (0..<length).map { i in
      var weight: Float = 1
      if !isFirst, i < overlap { weight = min(weight, Float(i + 1) / Float(overlap + 1)) }
      if !isLast, i >= length - overlap {
        weight = min(weight, Float(length - i) / Float(overlap + 1))
      }
      return weight
    }
  }

  private typealias Scaling = (
    mean: [Float]?, std: [Float]?, scalingFactor: Float, shiftFactor: Float?, audioMean: [Float]?,
    audioStd: [Float]?
  )

  /// VAE latent to the DiT's scale, as `FirstStage.scale` (SeedVR2 has no mean or std).
  private static func scale(_ x: DynamicGraph.Tensor<FloatType>, _ scaling: Scaling)
    -> DynamicGraph.Tensor<FloatType>
  {
    if let shift = scaling.shiftFactor { return (x - shift) * scaling.scalingFactor }
    return x * scaling.scalingFactor
  }

  private static func unscale(_ x: DynamicGraph.Tensor<FloatType>, _ scaling: Scaling)
    -> DynamicGraph.Tensor<FloatType>
  {
    if let shift = scaling.shiftFactor { return x / scaling.scalingFactor + shift }
    return x / scaling.scalingFactor
  }

  /// The prompt embedding SeedVR2 checkpoints carry in place of a text encoder.
  private static func positiveEmbedding(
    graph: DynamicGraph, path: String, externalData: DynamicGraph.Store.Codec
  ) -> DynamicGraph.Tensor<FloatType>? {
    var embedding: DynamicGraph.Tensor<FloatType>?
    graph.openStore(path, flags: .readOnly, externalStore: path + "-tensordata") { store in
      guard let shape = store.read(like: "positive_embedding")?.shape, shape.count == 2 else {
        return
      }
      let variable = graph.variable(.GPU(0), .WC(shape[0], shape[1]), of: FloatType.self)
      if store.read(
        "positive_embedding", variable: variable, codec: [.q6p, .q8p, .ezm7, externalData])
      {
        embedding = variable
      }
    }
    return embedding
  }

  /// The decoder's last convolution has a fourth (alpha) output the checkpoint may not hold, as
  /// the engine's single-frame loader pads (`SeedVR2Conv3DToConv2D`): zero-fill what's missing.
  private static func paddedOutputChannels(
    name: String, dataType: DataType, shape: TensorShape, store: DynamicGraph.Store,
    externalData: DynamicGraph.Store.Codec
  ) -> DynamicGraph.Store.ModelReaderResult {
    guard name.hasPrefix("__decoder__[t-conv_out-"),
      let stored = store.read(name, kind: .CPU, codec: [.jit, externalData])
    else { return .continue(name) }
    let source = Tensor<FloatType>(from: stored)
    let sourceCount = source.shape.reduce(1, *)
    let targetCount = shape.reduce(1, *)
    guard sourceCount < targetCount else { return .continue(name) }
    // Output channels come first in both the weights and the bias, so the missing ones are the
    // tail of the flat array.
    var values = [FloatType](repeating: 0, count: targetCount)
    source.withUnsafeBytes { raw in
      let floats = raw.bindMemory(to: FloatType.self)
      for i in 0..<sourceCount { values[i] = floats[i] }
    }
    let padded = Tensor<FloatType>(values, kind: .CPU, format: .NCHW, shape: shape)
    return dataType == .Float16 ? .final(padded) : .final(Tensor<Float>(from: padded))
  }

  /// The image at the output size, as a `[1, height, width, 3]` tensor in [-1, 1].
  static func resized(_ image: CGImage, width: Int, height: Int) -> Tensor<FloatType>? {
    guard image.width != width || image.height != height else {
      return ImageTensor.tensor(from: image)
    }
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage().flatMap(ImageTensor.tensor(from:))
  }
}
