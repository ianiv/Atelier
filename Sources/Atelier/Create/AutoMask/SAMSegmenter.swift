import CoreGraphics
import CoreML
import Foundation

/// Segment Anything (SAM 2.1, `SAMFiles`) on a canvas image: points and a box in, a mask out.
/// The image encoder is the slow part (seconds), so its output is kept for the last couple of
/// images (`SAMEmbeddingCache`) and each click after the first runs only the prompt encoder and
/// the mask decoder (milliseconds). The cache goes on a memory-pressure warning, as an iPad's
/// memory warning raises one.
///
/// The packages' interface, read from their specs: the encoder takes `image` (color, 1024 × 1024)
/// and gives `image_embedding` (1 × 256 × 64 × 64), `feats_s0` (1 × 32 × 256 × 256) and
/// `feats_s1` (1 × 64 × 128 × 128); the prompt encoder takes `points` (1 × N × 2, N up to 16)
/// and `labels` (1 × N) and gives `sparse_embeddings` (1 × N+1 × 256: it adds SAM's padding point
/// itself) and `dense_embeddings`; the decoder takes all of those (`sparse_embedding` with 2 to
/// 15 tokens) and gives `low_res_masks` (1 × 3 × 256 × 256 logits) and `scores` (1 × 3). Points
/// are in the 1024 input's pixels, the image stretched to fill it, as huggingface/sam2-studio
/// (the conversion's demo app) feeds them; labels are SAM's: 1 positive, 0 negative, 2 and 3 a
/// box's top-left and bottom-right corners.
actor SAMSegmenter {
  static let shared = SAMSegmenter()

  /// A click, in the image's pixels from its top left.
  struct Point: Sendable, Equatable, Codable {
    var location: CGPoint
    var positive: Bool
  }

  struct Prompt: Sendable, Equatable {
    var points: [Point] = []
    /// A box around what to select, image pixels from the top left.
    var box: CGRect?

    var isEmpty: Bool { points.isEmpty && box == nil }
  }

  struct Result: Sendable {
    /// One byte per image pixel, top row first: 255 selected, 0 not.
    var coverage: [UInt8]
    var width: Int
    var height: Int
    /// The decoder's own estimate of the mask's quality (its IoU prediction).
    var score: Float
    /// How long encoding the image took; nil when it was already encoded.
    var encodeTime: Duration?
    /// The prompt encoder and the mask decoder, with reading the mask back.
    var decodeTime: Duration
  }

  enum Failure: LocalizedError {
    case unreadableImage, unexpectedOutput

    var errorDescription: String? {
      switch self {
      case .unreadableImage: "Couldn't prepare the image for SAM."
      case .unexpectedOutput: "SAM gave an unexpected result."
      }
    }
  }

  /// One image's encoding. Holds the image, so its identity (the cache key) can't be reused by
  /// another image while it's cached.
  private struct Embedding {
    var image: CGImage
    var imageEmbedding: MLMultiArray
    var highResFeatures0: MLMultiArray
    var highResFeatures1: MLMultiArray
  }

  private struct Models {
    var files: SAMFiles
    var encoder: MLModel
    var promptEncoder: MLModel
    var decoder: MLModel
  }

  private var models: Models?
  private var cache = SAMEmbeddingCache<Embedding>(capacity: 2)
  private let memoryPressure: DispatchSourceMemoryPressure

  init() {
    memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
    memoryPressure.setEventHandler { [weak self] in
      Task { await self?.dropCache() }
    }
    memoryPressure.activate()
  }

  /// Forgets the encoded images (and the loaded models, which are the larger part).
  func dropCache() {
    cache.removeAll()
    models = nil
  }

  /// Whether `image` is encoded already for `size`, so a segment would skip the encoder.
  func isEncoded(_ image: CGImage, size: SAMFiles.Size) -> Bool {
    cache.contains(SAMEmbeddingCache<Embedding>.Key(image: image, size: size))
  }

  /// The mask `prompt` selects in `image`, at the image's size.
  func segment(_ image: CGImage, prompt: Prompt, files: SAMFiles) async throws -> Result {
    let clock = ContinuousClock()
    let models = try await load(files)
    let key = SAMEmbeddingCache<Embedding>.Key(image: image, size: files.size)
    var encodeTime: Duration?
    let embedding: Embedding
    if let cached = cache.value(for: key) {
      embedding = cached
    } else {
      let start = clock.now
      embedding = try encode(image, with: models.encoder)
      try Task.checkCancellation()
      cache.insert(embedding, for: key)
      encodeTime = clock.now - start
    }
    let start = clock.now
    let sourceSize = CGSize(width: image.width, height: image.height)
    let inputs = SAMGeometry.promptInputs(prompt, sourceSize: sourceSize)
    let points = try MLMultiArray(shape: [1, NSNumber(value: inputs.points.count), 2], dataType: .float32)
    let labels = try MLMultiArray(shape: [1, NSNumber(value: inputs.labels.count)], dataType: .float32)
    for (index, point) in inputs.points.enumerated() {
      points[[0, index, 0] as [NSNumber]] = NSNumber(value: Float(point.x))
      points[[0, index, 1] as [NSNumber]] = NSNumber(value: Float(point.y))
      labels[[0, index] as [NSNumber]] = NSNumber(value: inputs.labels[index])
    }
    let encoded = try Self.predict(
      models.promptEncoder, MLDictionaryFeatureProvider(dictionary: ["points": points, "labels": labels]))
    guard let sparse = encoded.featureValue(for: "sparse_embeddings"),
          let dense = encoded.featureValue(for: "dense_embeddings")
    else { throw Failure.unexpectedOutput }
    let decoded = try Self.predict(
      models.decoder, MLDictionaryFeatureProvider(dictionary: [
        "image_embedding": embedding.imageEmbedding, "sparse_embedding": sparse, "dense_embedding": dense,
        "feats_s0": embedding.highResFeatures0, "feats_s1": embedding.highResFeatures1,
      ]))
    guard let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue,
          let scores = decoded.featureValue(for: "scores")?.multiArrayValue,
          masks.shape.count == 4, scores.count == masks.shape[1].intValue
    else { throw Failure.unexpectedOutput }
    // Three candidates (part, whole, larger whole); take the one the decoder rates best, as
    // sam2-studio does.
    let scoreValues = (0..<scores.count).map { scores[$0].floatValue }
    let best = SAMGeometry.bestMask(scores: scoreValues)
    let logits = Self.plane(masks, channel: best)
    let side = masks.shape[3].intValue
    let upsampled = SAMGeometry.upsample(logits, side: side, width: image.width, height: image.height)
    return Result(
      coverage: SAMGeometry.threshold(upsampled), width: image.width, height: image.height, score: scoreValues[best],
      encodeTime: encodeTime, decodeTime: clock.now - start)
  }

  private func load(_ files: SAMFiles) async throws -> Models {
    if let models, models.files.root == files.root, models.files.size == files.size { return models }
    func model(_ part: SAMFiles.Part) async throws -> MLModel {
      let compiled = files.compiled(part)
      if !FileManager.default.fileExists(atPath: compiled.appending(path: "coremldata.bin").path) {
        // Compiled once and kept: compiling the encoder takes a few seconds.
        let temporary = try await MLModel.compileModel(at: files.package(part))
        try FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: temporary, to: compiled)
      }
      let configuration = MLModelConfiguration()
      // As sam2-studio runs them: the Neural Engine's first compile of the encoder is slow.
      configuration.computeUnits = .cpuAndGPU
      return try MLModel(contentsOf: compiled, configuration: configuration)
    }
    let loaded = try await Models(
      files: files, encoder: model(.imageEncoder), promptEncoder: model(.promptEncoder), decoder: model(.maskDecoder))
    // Encodings from another size don't fit this one's decoder; the key keeps them apart, but
    // they'd only take memory.
    cache.removeAll()
    models = loaded
    return loaded
  }

  /// Synchronous predictions, here and below: the actor is where they run, and Core ML's async
  /// ones would send the models out of it.
  private func encode(_ image: CGImage, with encoder: MLModel) throws -> Embedding {
    guard let constraint = encoder.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
          let stretched = SAMGeometry.stretched(image, side: SAMGeometry.inputSide)
    else { throw Failure.unreadableImage }
    let input = try MLFeatureValue(cgImage: stretched, constraint: constraint, options: nil)
    let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
    guard let embedding = output.featureValue(for: "image_embedding")?.multiArrayValue,
          let features0 = output.featureValue(for: "feats_s0")?.multiArrayValue,
          let features1 = output.featureValue(for: "feats_s1")?.multiArrayValue
    else { throw Failure.unexpectedOutput }
    return Embedding(image: image, imageEmbedding: embedding, highResFeatures0: features0, highResFeatures1: features1)
  }

  /// Core ML's synchronous prediction: in an async context Swift picks the async overload, which
  /// would send the model out of the actor.
  private static func predict(_ model: MLModel, _ input: MLFeatureProvider) throws -> MLFeatureProvider {
    try model.prediction(from: input)
  }

  /// One channel of a 1 × C × H × W array, as floats, top row first.
  private static func plane(_ array: MLMultiArray, channel: Int) -> [Float] {
    let height = array.shape[2].intValue, width = array.shape[3].intValue
    let strides = array.strides.map(\.intValue)
    var values = [Float](repeating: 0, count: width * height)
    func fill<T: MLShapedArrayScalar>(_: T.Type, _ convert: (T) -> Float) {
      array.withUnsafeBufferPointer(ofType: T.self) { buffer in
        for y in 0..<height {
          for x in 0..<width {
            values[y * width + x] = convert(buffer[channel * strides[1] + y * strides[2] + x * strides[3]])
          }
        }
      }
    }
    switch array.dataType {
    case .float16: fill(Float16.self) { Float($0) }
    case .float32: fill(Float.self) { $0 }
    case .double: fill(Double.self) { Float($0) }
    default:
      for y in 0..<height {
        for x in 0..<width {
          values[y * width + x] = array[[0, channel, y, x] as [NSNumber]].floatValue
        }
      }
    }
    return values
  }
}

/// The last few images' encodings, newest first: `capacity` of them at most. An image is told
/// apart by its object identity (a new canvas image is a new object, even with the same pixels)
/// and its size, and by the SAM size that encoded it.
nonisolated struct SAMEmbeddingCache<Value> {
  struct Key: Hashable {
    var image: ObjectIdentifier
    var width: Int
    var height: Int
    var size: SAMFiles.Size

    init(image: CGImage, size: SAMFiles.Size) {
      self.image = ObjectIdentifier(image)
      width = image.width
      height = image.height
      self.size = size
    }
  }

  let capacity: Int
  private(set) var entries: [(key: Key, value: Value)] = []

  init(capacity: Int) {
    self.capacity = max(capacity, 1)
  }

  func contains(_ key: Key) -> Bool { entries.contains { $0.key == key } }

  /// The value for `key`, which becomes the newest.
  mutating func value(for key: Key) -> Value? {
    guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
    let entry = entries.remove(at: index)
    entries.insert(entry, at: 0)
    return entry.value
  }

  mutating func insert(_ value: Value, for key: Key) {
    entries.removeAll { $0.key == key }
    entries.insert((key, value), at: 0)
    if entries.count > capacity { entries.removeLast(entries.count - capacity) }
  }

  mutating func removeAll() {
    entries.removeAll()
  }
}

/// The arithmetic between the canvas image and SAM's fixed input: pure, so it's unit-tested.
nonisolated enum SAMGeometry {
  /// SAM's input is a 1024-pixel square; the image is stretched to fill it.
  static let inputSide = 1024
  /// The decoder takes at most 15 sparse tokens, one of which is the padding point the prompt
  /// encoder adds: so 14 prompt points, a box counting as two.
  static let maxPromptPoints = 14

  /// An image point (pixels from the top left) in the stretched 1024 input.
  static func modelPoint(_ point: CGPoint, sourceSize: CGSize) -> CGPoint {
    CGPoint(
      x: point.x * Double(inputSide) / max(sourceSize.width, 1),
      y: point.y * Double(inputSide) / max(sourceSize.height, 1))
  }

  /// The prompt encoder's points and labels: the box's corners first (labels 2 and 3), as SAM 2
  /// orders them (`SAM2ImagePredictor._prep_prompts`), then the clicks (1 positive, 0 negative).
  /// Past the decoder's limit, the earliest clicks go.
  static func promptInputs(_ prompt: SAMSegmenter.Prompt, sourceSize: CGSize) -> (points: [CGPoint], labels: [Float]) {
    var points: [CGPoint] = []
    var labels: [Float] = []
    if let box = prompt.box?.standardized {
      points += [
        modelPoint(CGPoint(x: box.minX, y: box.minY), sourceSize: sourceSize),
        modelPoint(CGPoint(x: box.maxX, y: box.maxY), sourceSize: sourceSize),
      ]
      labels += [2, 3]
    }
    let clicks = prompt.points.suffix(maxPromptPoints - points.count)
    points += clicks.map { modelPoint($0.location, sourceSize: sourceSize) }
    labels += clicks.map { $0.positive ? 1 : 0 }
    return (points, labels)
  }

  static func bestMask(scores: [Float]) -> Int {
    scores.indices.max { scores[$0] < scores[$1] } ?? 0
  }

  /// `logits` (a `side` × `side` grid over the whole stretched image) resampled to `width` ×
  /// `height` bilinearly, sample centers aligned as `F.interpolate(align_corners=False)` does,
  /// SAM's own upsampling (`SAM2Transforms.postprocess_masks`).
  static func upsample(_ logits: [Float], side: Int, width: Int, height: Int) -> [Float] {
    guard side > 0, width > 0, height > 0, logits.count == side * side else { return [] }
    var output = [Float](repeating: 0, count: width * height)
    let scaleX = Double(side) / Double(width), scaleY = Double(side) / Double(height)
    // Each output column's two source columns and weight, worked out once.
    let columns = (0..<width).map { x -> (Int, Int, Float) in
      let u = max((Double(x) + 0.5) * scaleX - 0.5, 0)
      let x0 = min(Int(u), side - 1)
      return (x0, min(x0 + 1, side - 1), Float(u - Double(x0)))
    }
    logits.withUnsafeBufferPointer { source in
      output.withUnsafeMutableBufferPointer { destination in
        for y in 0..<height {
          let v = max((Double(y) + 0.5) * scaleY - 0.5, 0)
          let y0 = min(Int(v), side - 1), y1 = min(y0 + 1, side - 1)
          let wy = Float(v - Double(y0))
          let row0 = y0 * side, row1 = y1 * side
          for x in 0..<width {
            let (x0, x1, wx) = columns[x]
            let top = source[row0 + x0] + (source[row0 + x1] - source[row0 + x0]) * wx
            let bottom = source[row1 + x0] + (source[row1 + x1] - source[row1 + x0]) * wx
            destination[y * width + x] = top + (bottom - top) * wy
          }
        }
      }
    }
    return output
  }

  /// Selected where the logit is above zero (SAM's `mask_threshold`).
  static func threshold(_ logits: [Float]) -> [UInt8] {
    logits.map { $0 > 0 ? 255 : 0 }
  }

  /// `coverage` (one byte per pixel, top row first) as an opaque gray image, the form
  /// `CanvasMask.Stroke.bitmap` reads.
  static func grayImage(_ coverage: [UInt8], width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, coverage.count == width * height,
          let provider = CGDataProvider(data: Data(coverage) as CFData)
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// `image` stretched to a `side` square over black (a transparent part reads as black), the
  /// encoder's input.
  static func stretched(_ image: CGImage, side: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()
  }
}

extension CanvasPlacement {
  /// The image pixel (from the image's top left) under a frame pixel (from the frame's top left):
  /// the frame may show the image zoomed or moved.
  nonisolated func sourcePoint(fromFrame point: CGPoint) -> CGPoint {
    let zoom = zoom
    return CGPoint(x: (point.x - imageRect.minX) / zoom.x, y: (point.y - imageRect.minY) / zoom.y)
  }

  /// The frame pixel showing an image pixel.
  nonisolated func framePoint(fromSource point: CGPoint) -> CGPoint {
    let zoom = zoom
    return CGPoint(x: point.x * zoom.x + imageRect.minX, y: point.y * zoom.y + imageRect.minY)
  }
}
