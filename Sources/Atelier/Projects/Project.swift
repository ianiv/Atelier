import CoreGraphics
import DataModels
import Dflat
import Diffusion
import Foundation
import ImageIO
import NNC
import ProjectFormat
import SQLiteDflat
import UniformTypeIdentifiers
import _MediaGenerationKit

/// A canvas layer (`tensordata`); the bare name clashes with another module's `TensorData`.
private typealias Layer = ProjectFormat.TensorData

/// A step in a project's history, keyed like Draw Things: the branch and the step number.
struct StepID: Hashable, Codable, Sendable {
  var lineage: Int64
  var logicalTime: Int64
}

/// One project file in Draw Things' format: a SQLite database holding dflat tables (history
/// steps, canvas layers, thumbnails) and an s4nnc tensor store (the full-resolution images).
/// Writes follow `ImageHistoryManager.pushHistory`/`addImage` in the engine's History library.
///
/// Atelier only appends to the newest branch, so its own projects have a single lineage. Reading
/// follows the general rule, so a branched project still lists its main line.
final class Project: @unchecked Sendable {
  let url: URL
  private let workspace: SQLiteWorkspace
  /// Only used to open the tensor store; no computation runs on it.
  private let graph = DynamicGraph()
  private let lock = NSLock()

  var name: String { url.deletingPathExtension().lastPathComponent }

  init(url: URL) {
    self.url = url
    workspace = SQLiteWorkspace(filePath: url.path, fileProtectionLevel: .noProtection)
  }

  private var isClosed = false

  deinit {
    guard !isClosed else { return }
    // Shutting down drains the connection pool synchronously, waiting on its default-QoS
    // threads. The last release is often on the main thread (switching projects), so shut down
    // from a background queue instead of blocking the UI behind lower-priority work.
    let workspace = workspace
    DispatchQueue.global(qos: .utility).async { workspace.shutdown(flags: [], completion: nil) }
  }

  /// Finishes pending writes and closes the database. The project can't be used afterwards.
  func close() async {
    let wasClosed = lock.withLock {
      let wasClosed = isClosed
      isClosed = true
      return wasClosed
    }
    guard !wasClosed else { return }
    await withCheckedContinuation { continuation in
      workspace.shutdown(flags: [.truncate]) { continuation.resume() }
    }
  }

  // MARK: - Reading

  /// Generated images on the main line (the ancestry of the newest step), newest first.
  func items() -> [HistoryItem] {
    let nodes = workspace.fetchWithinASnapshot {
      Array(workspace.fetch(for: TensorHistoryNode.self).all())
    }
    return Self.mainLine(nodes).compactMap { node in
      guard node.generated, let tensorId = imageTensorId(of: node) else { return nil }
      return HistoryItem(
        id: StepID(lineage: node.lineage, logicalTime: node.logicalTime), tensorId: tensorId,
        previewId: node.previewId, sidecar: Self.sidecar(for: node))
    }
  }

  /// The ancestry of the newest step: at each step number, the step with the greatest lineage
  /// not above the child's.
  static func mainLine(_ nodes: [TensorHistoryNode]) -> [TensorHistoryNode] {
    var byTime: [Int64: [TensorHistoryNode]] = [:]
    for node in nodes { byTime[node.logicalTime, default: []].append(node) }
    guard
      let newest = nodes.max(by: {
        ($0.lineage, $0.logicalTime) < ($1.lineage, $1.logicalTime)
      })
    else { return [] }
    var line: [TensorHistoryNode] = []
    var lineage = newest.lineage
    var time = newest.logicalTime
    while time >= 0 {
      if let node = byTime[time]?.filter({ $0.lineage <= lineage }).max(by: {
        $0.lineage < $1.lineage
      }) {
        line.append(node)
        lineage = node.lineage
      }
      time -= 1
    }
    return line
  }

  /// The image layer's tensor: from the canvas layers when stored, else the node's own field.
  private func imageTensorId(of node: TensorHistoryNode) -> Int64? {
    if node.dataStored > 0 {
      let layers = workspace.fetch(for: Layer.self).where(
        Layer.lineage == node.lineage && Layer.logicalTime == node.logicalTime,
        orderBy: [Layer.index.ascending])
      return layers.first(where: { $0.tensorId > 0 })?.tensorId
    }
    return node.tensorId > 0 ? node.tensorId : nil
  }

  static func sidecar(for node: TensorHistoryNode) -> HistoryStore.Sidecar {
    HistoryStore.Sidecar(
      createdAt: Date(timeIntervalSince1970: Double(node.wallClock) / 1_000_000),
      durationSeconds: node.generationTime,
      prompt: node.textPrompt ?? "",
      negativePrompt: node.negativeTextPrompt ?? "",
      model: node.model ?? "",
      seed: node.seed,
      width: Int(node.startWidth) * 64,
      height: Int(node.startHeight) * 64,
      steps: Int(node.steps),
      guidanceScale: node.guidanceScale,
      shift: node.shift,
      sampler: String(describing: DataModels.SamplerType(rawValue: node.sampler.rawValue) ?? .dPMPP2MKarras),
      resolutionDependentShift: node.resolutionDependentShift,
      hiresFix: node.hiresFix,
      configuration: ProjectMapping.dump(of: node)
    )
  }

  /// The JPEG preview Draw Things shows for a step; `half` is the smaller one used in grids.
  func thumbnail(previewId: Int64, half: Bool) -> CGImage? {
    let data: [UInt8]?
    if half {
      data = workspace.fetch(for: ThumbnailHistoryHalfNode.self).where(
        ThumbnailHistoryHalfNode.id == previewId
      ).first?.data
    } else {
      data = workspace.fetch(for: ThumbnailHistoryNode.self).where(
        ThumbnailHistoryNode.id == previewId
      ).first?.data
    }
    guard let data, !data.isEmpty,
      let source = CGImageSourceCreateWithData(Data(data) as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// The full-resolution image tensor.
  func tensor(id: Int64) -> Tensor<FloatType>? {
    lock.lock()
    defer { lock.unlock() }
    var tensor: Tensor<FloatType>?
    graph.openStore(url.path, flags: [.readOnly]) {
      tensor = $0.read("tensor_history_\(id)", codec: [.fpzip, .zip]).map {
        Tensor<FloatType>(from: $0)
      }
    }
    return tensor
  }

  func image(for item: HistoryItem) -> CGImage? {
    tensor(id: item.tensorId).flatMap(ImageTensor.cgImage(from:))
  }

  /// The full-resolution image of a step, if it has one.
  func image(at id: StepID) -> CGImage? {
    guard
      let node = workspace.fetch(for: TensorHistoryNode.self).where(
        TensorHistoryNode.lineage == id.lineage && TensorHistoryNode.logicalTime == id.logicalTime
      ).first,
      let tensorId = imageTensorId(of: node)
    else { return nil }
    return tensor(id: tensorId).flatMap(ImageTensor.cgImage(from:))
  }

  // MARK: - Writing

  /// Appends a generated image as a new step at the end of the newest branch: the tensor, the
  /// step, its canvas layer and both thumbnails.
  func append(
    tensor: Tensor<FloatType>, model: String, prompt: String, negativePrompt: String,
    seed: UInt32, settings: [String: JSONValue], createdAt: Date, duration: Double,
    reason: ProjectFormat.Reason = .generate
  ) async throws -> HistoryItem {
    guard let image = ImageTensor.cgImage(from: tensor) else { throw ProjectError.badImage }
    let tensorId = Int64.random(in: 100_000_000...299_999_999)
    try writeTensor(tensor, name: "tensor_history_\(tensorId)")

    let newest = workspace.fetch(for: TensorHistoryNode.self).all(
      limit: .limit(1),
      orderBy: [TensorHistoryNode.lineage.descending, TensorHistoryNode.logicalTime.descending]
    ).first
    let id = StepID(
      lineage: newest?.lineage ?? 0, logicalTime: newest.map { $0.logicalTime + 1 } ?? 0)
    // As in pushHistory: the preview id is the sum of the step's layer ids.
    let previewId = tensorId
    let step = ProjectMapping.Step(
      lineage: id.lineage, logicalTime: id.logicalTime, model: model, prompt: prompt,
      negativePrompt: negativePrompt, seed: seed, tensorId: tensorId, previewId: previewId,
      wallClock: Int64(createdAt.timeIntervalSince1970 * 1_000_000), generationTime: duration,
      reason: reason)
    let node = ProjectMapping.node(for: step, settings: settings)
    let layer = Layer(
      lineage: id.lineage, logicalTime: id.logicalTime, index: 0, x: 0, y: 0,
      width: Int32(image.width), height: Int32(image.height), scaleFactorBy120: 120,
      tensorId: tensorId)
    let full = ImageTensor.jpeg(image, quality: 0.75)
    let half = ImageTensor.downsampled(image).flatMap { ImageTensor.jpeg($0, quality: 0.5) }

    let succeeded = await withCheckedContinuation { continuation in
      workspace.performChanges([
        TensorHistoryNode.self, Layer.self, ThumbnailHistoryNode.self,
        ThumbnailHistoryHalfNode.self,
      ]) { transaction in
        transaction.try(submit: TensorHistoryNodeChangeRequest.upsertRequest(node))
        transaction.try(submit: ProjectFormat.TensorDataChangeRequest.upsertRequest(layer))
        if let full {
          transaction.try(
            submit: ThumbnailHistoryNodeChangeRequest.upsertRequest(
              ThumbnailHistoryNode(id: previewId, data: full)))
        }
        if let half {
          transaction.try(
            submit: ThumbnailHistoryHalfNodeChangeRequest.upsertRequest(
              ThumbnailHistoryHalfNode(id: previewId, data: half)))
        }
      } completionHandler: { continuation.resume(returning: $0) }
    }
    guard succeeded else {
      removeTensors(["tensor_history_\(tensorId)"])
      throw ProjectError.writeFailed
    }
    return HistoryItem(
      id: id, tensorId: tensorId, previewId: previewId, sidecar: Self.sidecar(for: node))
  }

  /// Deletes a step, its layers, thumbnails and tensors, and moves the later steps of its
  /// lineage down by one so step numbers stay contiguous (as Draw Things' deleteHistory does for
  /// a linear history).
  func delete(_ id: StepID) async throws {
    let (node, layers, later, laterLayers) = workspace.fetchWithinASnapshot {
      () -> (TensorHistoryNode?, [Layer], [TensorHistoryNode], [Layer]) in
      let node = workspace.fetch(for: TensorHistoryNode.self).where(
        TensorHistoryNode.lineage == id.lineage && TensorHistoryNode.logicalTime == id.logicalTime
      ).first
      let layers = Array(
        workspace.fetch(for: Layer.self).where(
          Layer.lineage == id.lineage && Layer.logicalTime == id.logicalTime))
      let later = Array(
        workspace.fetch(for: TensorHistoryNode.self).where(
          TensorHistoryNode.lineage == id.lineage && TensorHistoryNode.logicalTime > id.logicalTime,
          orderBy: [TensorHistoryNode.logicalTime.ascending]))
      let laterLayers = Array(
        workspace.fetch(for: Layer.self).where(
          Layer.lineage == id.lineage && Layer.logicalTime > id.logicalTime,
          orderBy: [Layer.logicalTime.ascending]))
      return (node, layers, later, laterLayers)
    }
    guard let node else { return }
    var tensorNames = layers.flatMap(Self.tensorNames(of:))
    if node.tensorId > 0 { tensorNames.append("tensor_history_\(node.tensorId)") }
    let previewId = node.previewId

    let succeeded = await withCheckedContinuation { continuation in
      workspace.performChanges([
        TensorHistoryNode.self, Layer.self, ThumbnailHistoryNode.self,
        ThumbnailHistoryHalfNode.self,
      ]) { transaction in
        if let request = TensorHistoryNodeChangeRequest.deletionRequest(node) {
          transaction.try(submit: request)
        }
        for layer in layers {
          if let request = ProjectFormat.TensorDataChangeRequest.deletionRequest(layer) {
            transaction.try(submit: request)
          }
        }
        // Ascending, so each step's new key was freed by the one before it.
        for step in later {
          if let request = TensorHistoryNodeChangeRequest.deletionRequest(step) {
            transaction.try(submit: request)
          }
          var builder = TensorHistoryNodeBuilder(from: step)
          builder.logicalTime -= 1
          transaction.try(submit: TensorHistoryNodeChangeRequest.upsertRequest(builder.build()))
          for layer in laterLayers where layer.logicalTime == step.logicalTime {
            if let request = ProjectFormat.TensorDataChangeRequest.deletionRequest(layer) {
              transaction.try(submit: request)
            }
            var builder = ProjectFormat.TensorDataBuilder(from: layer)
            builder.logicalTime -= 1
            transaction.try(submit: ProjectFormat.TensorDataChangeRequest.upsertRequest(builder.build()))
          }
        }
        if previewId != 0 {
          if let thumbnail = self.workspace.fetch(for: ThumbnailHistoryNode.self).where(
            ThumbnailHistoryNode.id == previewId
          ).first, let request = ThumbnailHistoryNodeChangeRequest.deletionRequest(thumbnail) {
            transaction.try(submit: request)
          }
          if let thumbnail = self.workspace.fetch(for: ThumbnailHistoryHalfNode.self).where(
            ThumbnailHistoryHalfNode.id == previewId
          ).first, let request = ThumbnailHistoryHalfNodeChangeRequest.deletionRequest(thumbnail) {
            transaction.try(submit: request)
          }
        }
      } completionHandler: { continuation.resume(returning: $0) }
    }
    guard succeeded else { throw ProjectError.writeFailed }
    removeTensors(tensorNames)
  }

  private static func tensorNames(of layer: Layer) -> [String] {
    [
      ("tensor_history", layer.tensorId), ("binary_mask", layer.maskId),
      ("depth_map", layer.depthMapId), ("scribble", layer.scribbleId), ("pose", layer.poseId),
      ("color_palette", layer.colorPaletteId), ("custom", layer.customId),
    ].compactMap { $0.1 > 0 ? "\($0.0)_\($0.1)" : nil }
  }

  private func writeTensor(_ tensor: Tensor<FloatType>, name: String) throws {
    lock.lock()
    defer { lock.unlock() }
    // Default flags would truncate the file on close; Draw Things opens it with none.
    let result = graph.openStore(url.path, flags: []) {
      $0.write(name, tensor: tensor, codec: [.fpzip, .zip])
    }
    if case .failure = result { throw ProjectError.writeFailed }
  }

  private func removeTensors(_ names: [String]) {
    guard !names.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    graph.openStore(url.path, flags: []) { store in
      for name in names { store.remove(name) }
    }
  }
}

enum ProjectError: LocalizedError {
  case badImage
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .badImage: "The image couldn't be converted."
    case .writeFailed: "The project file couldn't be written."
    }
  }
}

/// Conversion between Draw Things' image tensors (`[1, H, W, 3]` in [-1, 1]) and CGImages.
enum ImageTensor {
  static func cgImage(from tensor: Tensor<FloatType>) -> CGImage? {
    let shape = tensor.shape
    guard shape.count == 4, shape[0] >= 1, shape[3] >= 3 else { return nil }
    let height = shape[1]
    let width = shape[2]
    let channels = shape[3]
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    tensor.withUnsafeBytes { raw in
      let values = raw.bindMemory(to: FloatType.self)
      for pixel in 0..<(width * height) {
        for c in 0..<3 {
          let v = (Float(values[pixel * channels + c]) + 1) * 127.5
          rgba[pixel * 4 + c] = UInt8(clamping: Int(v.rounded()))
        }
      }
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  static func tensor(from image: CGImage) -> Tensor<FloatType>? {
    let width = image.width
    let height = image.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, height, width, 3))
    tensor.withUnsafeMutableBytes { raw in
      let values = raw.bindMemory(to: FloatType.self)
      for pixel in 0..<(width * height) {
        for c in 0..<3 {
          values[pixel * 3 + c] = FloatType(Float(rgba[pixel * 4 + c]) / 127.5 - 1)
        }
      }
    }
    return tensor
  }

  static func jpeg(_ image: CGImage, quality: Double) -> [UInt8]? {
    encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
  }

  static func png(_ image: CGImage) -> Data? {
    encode(image, type: .png, properties: [:]).map { Data($0) }
  }

  private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any])
    -> [UInt8]?
  {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, type.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return [UInt8](data as Data)
  }

  /// The grid thumbnail: at least half size, more until the short side is near 384 (the engine's
  /// downsampleImage).
  static func downsampled(_ image: CGImage) -> CGImage? {
    let scale = max(min(image.width, image.height) / 384, 2)
    let width = image.width / scale
    let height = image.height / scale
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
}
