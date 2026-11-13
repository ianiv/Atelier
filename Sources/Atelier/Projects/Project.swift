@preconcurrency import _MediaGenerationKit
import CoreGraphics
@preconcurrency import DataModels
@preconcurrency import Dflat
@preconcurrency import Diffusion
import Foundation
import ImageIO
@preconcurrency import NNC
import ProjectFormat
@preconcurrency import SQLiteDflat
import Synchronization
import UniformTypeIdentifiers

/// A canvas layer (`tensordata`); the bare name clashes with another module's `TensorData`.
private typealias Layer = ProjectFormat.TensorData

/// A step in a project's history, keyed like Draw Things: the branch and the step number.
nonisolated struct StepID: Hashable, Codable, Sendable {
  var lineage: Int64
  var logicalTime: Int64
}

/// A project's overrides of the output folder settings; nil follows Settings.
nonisolated struct ProjectOutput: Equatable, Sendable {
  var saves: Bool?
  var folder: String?

  var effectiveSaves: Bool { saves ?? AppSettings.savesToOutputFolder }
  var effectiveFolder: String { folder ?? AppSettings.outputFolder }
}

/// One project file in Draw Things' format: a SQLite database holding dflat tables (history
/// steps, canvas layers, thumbnails) and an s4nnc tensor store (the full-resolution images).
/// Writes follow `ImageHistoryManager.pushHistory`/`addImage` in the engine's History library.
///
/// A step can follow any earlier one, which branches the history as Draw Things does (see
/// `append`); `ProjectTree` reads the branches back.
final nonisolated class Project: Sendable {
  let url: URL
  private let workspace: SQLiteWorkspace
  /// Only used to open the tensor store; no computation runs on it.
  private let graph = DynamicGraph()
  /// One opening of the tensor store at a time.
  private let storeAccess = Mutex(())
  private let isClosed = Mutex(false)

  var name: String { url.deletingPathExtension().lastPathComponent }

  init(url: URL) {
    self.url = url
    #if os(iOS)
      // Readable while the iPad is locked, once it's been unlocked since starting, as the queue
      // needs when it runs in the background. Applies to files as they're created.
      let protection = SQLiteWorkspace.FileProtectionLevel.completeFileProtectionUntilFirstUserAuthentication
    #else
      let protection = SQLiteWorkspace.FileProtectionLevel.noProtection
    #endif
    workspace = SQLiteWorkspace(filePath: url.path, fileProtectionLevel: protection)
  }

  deinit {
    guard !isClosed.withLock({ $0 }) else { return }
    // Shutting down drains the connection pool synchronously, waiting on its default-QoS
    // threads. The last release is often on the main thread (switching projects), so shut down
    // from a background queue instead of blocking the UI behind lower-priority work.
    let workspace = workspace
    DispatchQueue.global(qos: .utility).async { workspace.shutdown(flags: [], completion: nil) }
  }

  /// False once `close` has run (a rename does, before moving the file).
  var isOpen: Bool { !isClosed.withLock { $0 } }

  /// Finishes pending writes and closes the database. The project can't be used afterwards.
  @concurrent func close() async {
    let wasClosed = isClosed.withLock {
      let wasClosed = $0
      $0 = true
      return wasClosed
    }
    guard !wasClosed else { return }
    await withCheckedContinuation { continuation in
      workspace.shutdown(flags: [.truncate]) { continuation.resume() }
    }
  }

  // MARK: - Reading

  /// Runs `body` on this project off the main actor: reads decode images and open the database.
  @concurrent func read<T: Sendable>(_ body: @Sendable (Project) -> T) async -> T {
    body(self)
  }

  /// Every generated step on every branch, newest first.
  func items() -> [HistoryItem] {
    tree().itemsNewestFirst
  }

  /// The steps and how they connect; `items` false leaves out History's items.
  func tree(items: Bool = true) -> ProjectTree {
    workspace.fetchWithinASnapshot {
      ProjectTree(
        nodes: Array(workspace.fetch(for: TensorHistoryNode.self).all()),
        layers: Array(workspace.fetch(for: Layer.self).all()),
        clips: items ? Array(workspace.fetch(for: Clip.self).all()) : [],
        moods: items ? Array(workspace.fetch(for: TensorMoodboardData.self).all()) : [], items: items)
    }
  }

  /// The input of an Edit step: its parent, when the parent's image is still the recorded input
  /// (`tensorId`). Nil once that step was deleted (the step now before it holds another image).
  func input(of id: StepID, tensorId: Int64) -> (id: StepID, image: CGImage)? {
    let tree = tree(items: false)
    guard let parent = tree.steps[id]?.parent, tree.steps[parent]?.tensorId == tensorId,
          let image = image(tensorId: tensorId)
    else { return nil }
    return (parent, image)
  }

  /// The current step as Draw Things records it (`image_seek_to`, plus `image_seek_to_lineage`
  /// when it isn't the greatest lineage at that step number), if it names a step.
  func storedCurrentStep(in tree: ProjectTree) -> StepID? {
    guard let time = workspace.dictionary["image_seek_to", Int.self] else { return nil }
    if let lineage = workspace.dictionary["image_seek_to_lineage", Int.self] {
      let id = StepID(lineage: Int64(lineage), logicalTime: Int64(time))
      if tree.steps[id] != nil { return id }
    }
    return tree.sacredStep(at: Int64(time))
  }

  /// Records the current step for the next open (and for Draw Things); nil means the newest.
  func setCurrentStep(_ id: StepID?) {
    workspace.dictionary["image_seek_to", Int.self] = id.map { Int($0.logicalTime) }
    workspace.dictionary["image_seek_to_lineage", Int.self] = id.map { Int($0.lineage) }
  }

  /// The project's own output folder settings, kept in the project file so they follow a rename.
  var output: ProjectOutput {
    get {
      ProjectOutput(
        saves: workspace.dictionary["atelier_output_save", Bool.self],
        folder: workspace.dictionary["atelier_output_folder", String.self])
    }
    set {
      workspace.dictionary["atelier_output_save", Bool.self] = newValue.saves
      workspace.dictionary["atelier_output_folder", String.self] =
        newValue.folder.flatMap { $0.isEmpty ? nil : $0 }
    }
  }

  /// The project's timelines as JSON (`TimelineStore`), kept in the project file so they follow
  /// a rename or a copy. Draw Things ignores the key.
  var timelinesJSON: String? {
    get { workspace.dictionary["atelier_timelines", String.self] }
    set { workspace.dictionary["atelier_timelines", String.self] = newValue }
  }

  /// Star ratings (1 to 5) by image tensor, which a fork or delete doesn't renumber; unrated
  /// images aren't listed. Kept as JSON in the project file, which Draw Things ignores.
  var ratings: [Int64: Int] {
    get {
      guard let json = workspace.dictionary["atelier_ratings", String.self],
            let stored = try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8))
      else { return [:] }
      return Dictionary(
        stored.compactMap { key, value in Int64(key).map { ($0, value) } },
        uniquingKeysWith: { a, _ in a })
    }
    set {
      let stored = Dictionary(newValue.map { (String($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
      workspace.dictionary["atelier_ratings", String.self] = stored.isEmpty
        ? nil : (try? JSONEncoder().encode(stored)).map { String(decoding: $0, as: UTF8.self) }
    }
  }

  /// The mask an image last had on the canvas (`HistoryStore.setMask`), under
  /// `atelier_mask_<image tensor id>` as `CanvasMask` JSON, the way ratings and timelines are kept:
  /// by tensor, which a fork or delete doesn't renumber, in the project file, which Draw Things
  /// ignores. An empty mask records one cleared on an image that has an older mask to fall back to
  /// (`HistoryStore.storedMask`); nil is no key.
  func storedMask(forImage tensorId: Int64) -> CanvasMask? {
    workspace.dictionary[Self.maskKey(tensorId), String.self]
      .flatMap { try? JSONDecoder().decode(CanvasMask.self, from: Data($0.utf8)) }
  }

  /// Keeps `mask` as the image's (`storedMask`); nil removes the key.
  func setStoredMask(_ mask: CanvasMask?, forImage tensorId: Int64) {
    workspace.dictionary[Self.maskKey(tensorId), String.self] =
      mask.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
  }

  /// The images with a kept mask, true when it paints anything (false for a cleared one). Reads
  /// every key (slow for a dictionary), so it's read once per opening (`HistoryStore.reload`).
  func storedMaskImages() -> [Int64: Bool] {
    let cleared = (try? JSONEncoder().encode(CanvasMask())).map { String(decoding: $0, as: UTF8.self) }
    var images: [Int64: Bool] = [:]
    for key in workspace.dictionary.keys where key.hasPrefix(Self.maskKeyPrefix) {
      guard let tensorId = Int64(key.dropFirst(Self.maskKeyPrefix.count)),
            let json = workspace.dictionary[key, String.self]
      else { continue }
      images[tensorId] = json != cleared
    }
    return images
  }

  /// Removes the kept masks of images no step shows any more (deleted), unless another step still
  /// has that image. Returns the images whose mask went.
  @discardableResult
  func pruneStoredMasks(keeping tree: ProjectTree) -> [Int64] {
    let gone = storedMaskImages().keys.filter { tree.step(tensorId: $0) == nil }
    for tensorId in gone { setStoredMask(nil, forImage: tensorId) }
    return Array(gone)
  }

  private static let maskKeyPrefix = "atelier_mask_"
  private static func maskKey(_ tensorId: Int64) -> String { maskKeyPrefix + String(tensorId) }

  /// A Draw Things canvas's painted mask, for the step whose image is `tensorId`, as one bitmap
  /// stroke in the composited image's pixels (`Self.paintedMask`); nil when no layer paints.
  /// Read-only: Atelier keeps its own masks as `storedMask`.
  func layerMask(tensorId: Int64) -> CanvasMask? {
    guard let layers = canvasLayers(imageTensorId: tensorId), layers.contains(where: { $0.maskId > 0 }),
          let drawn = compositeLayers(layers)
    else { return nil }
    return Self.paintedMask(drawn)
  }

  /// Where Draw Things' layers are painted with its inpainting brush, laid out as `composite` lays
  /// them out: a pixel is painted where any layer's mask code there is other than 0 or 3
  /// (`CanvasMask.Stored`; the brush writes 0xF9, code 1), the mask read nearest-neighbour at the
  /// layer's size as `masked` reads it. One bitmap stroke at the composite's size for `density`
  /// (`canvasSize`), nil when nothing is painted.
  static func paintedMask(_ layers: [CompositeLayer], density: Int = 120) -> CanvasMask? {
    guard let size = canvasSize(layers, density: density) else { return nil }
    let (union, density, width, height) = (size.union, size.scale, size.width, size.height)
    var painted = [UInt8](repeating: 0, count: width * height)
    for layer in layers {
      let rect = units(layer)
      let drawn = CGRect(
        x: (rect.minX - union.minX) * density, y: (rect.minY - union.minY) * density,
        width: rect.width * density, height: rect.height * density)
      let x0 = max(Int(drawn.minX.rounded()), 0), x1 = min(Int(drawn.maxX.rounded()), width)
      let y0 = max(Int(drawn.minY.rounded()), 0), y1 = min(Int(drawn.maxY.rounded()), height)
      guard x0 < x1, y0 < y1,
            let mask = layer.mask, layer.maskWidth > 0, layer.maskHeight > 0,
            mask.count >= layer.maskWidth * layer.maskHeight
      else { continue }
      for y in y0..<y1 {
        let my = min(max(Int((Double(y) + 0.5 - drawn.minY) / drawn.height * Double(layer.maskHeight)), 0), layer.maskHeight - 1)
        for x in x0..<x1 {
          let mx = min(max(Int((Double(x) + 0.5 - drawn.minX) / drawn.width * Double(layer.maskWidth)), 0), layer.maskWidth - 1)
          let code = mask[my * layer.maskWidth + mx] & 7
          if code != 0, code != 3 { painted[y * width + x] = 255 }
        }
      }
    }
    guard painted.contains(255), let png = CanvasMask.grayPNG(painted, width: width, height: height) else { return nil }
    return CanvasMask(strokes: [CanvasMask.Stroke(kind: .bitmap, points: [.zero], bitmap: png)])
  }

  /// The image layer's tensor: from the canvas layers when stored (the top one with a tensor), else
  /// the node's own field.
  private func imageTensorId(of node: TensorHistoryNode) -> Int64? {
    if node.dataStored > 0 {
      let layers = workspace.fetch(for: Layer.self).where(
        Layer.lineage == node.lineage && Layer.logicalTime == node.logicalTime,
        orderBy: [Layer.index.descending])
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
      configuration: ProjectMapping.dump(of: node),
      timings: ProjectMapping.Profile(node.profileData).flatMap(GenerationTimings.init(profile:)),
      refine: ProjectMapping.Profile(node.profileData)?.refine,
      colorMatch: ProjectMapping.Profile(node.profileData)?.colorMatch
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
    tensor(named: "tensor_history_\(id)")
  }

  /// Set for a read the canvas may stop wanting (`CreateModel.show`). Decoding a large image
  /// (fpzip, for an upscale) takes seconds and can't be stopped once it starts, so such a read
  /// opens the store on its own, outside `storeAccess`: the image clicked next doesn't wait for
  /// it. A read that's already cancelled skips the decode.
  @TaskLocal static var isCanvasRead = false

  private func tensor(named name: String) -> Tensor<FloatType>? {
    if Self.isCanvasRead {
      guard !Task.isCancelled else { return nil }
      var tensor: Tensor<FloatType>?
      DynamicGraph().openStore(url.path, flags: [.readOnly]) {
        tensor = $0.read(name, codec: [.fpzip, .zip]).map { Tensor<FloatType>(from: $0) }
      }
      return tensor
    }
    return storeAccess.withLock { _ in
      var tensor: Tensor<FloatType>?
      graph.openStore(url.path, flags: [.readOnly]) {
        tensor = $0.read(name, codec: [.fpzip, .zip]).map { Tensor<FloatType>(from: $0) }
      }
      return tensor
    }
  }

  /// A step's moodboard images and weights, in order.
  func moodboard(at id: StepID) -> [(image: CGImage, weight: Float)] {
    let rows = workspace.fetch(for: TensorMoodboardData.self).where(
      TensorMoodboardData.lineage == id.lineage && TensorMoodboardData.logicalTime == id.logicalTime,
      orderBy: [TensorMoodboardData.index.ascending])
    return rows.compactMap { row in
      tensor(named: "shuffle_\(row.shuffleId)").flatMap(ImageTensor.cgImage(from:)).map {
        ($0, row.weight)
      }
    }
  }

  func image(for item: HistoryItem) -> CGImage? {
    image(tensorId: item.tensorId)
  }

  /// The full-resolution image of a step, if it has one.
  func image(at id: StepID) -> CGImage? {
    imageTensorId(at: id).flatMap { image(tensorId: $0) }
  }

  /// The image of the step whose image layer is `tensorId`: for a step of several layers (a
  /// merged refine, or a Draw Things canvas), all of them composited (`Self.composite`) at
  /// `density` (`scale_factor_by_120`: 120 is one pixel per canvas unit, the image's own size;
  /// `Self.finestDensity` keeps its finest layer's detail). The canvas, masks and placement work
  /// at 120; full detail is for showing and exporting.
  func image(tensorId: Int64, density: Int = 120) -> CGImage? {
    if let layers = canvasLayers(imageTensorId: tensorId), let drawn = compositeLayers(layers),
       let composite = Self.composite(drawn, density: density)
    {
      return composite
    }
    return tensor(id: tensorId).flatMap(ImageTensor.cgImage(from:))
  }

  /// Whether the step whose image is `tensorId` has a layer finer than its image's own pixels (a
  /// zoomed refine, or a Draw Things upscale), so a full-detail read differs from the image.
  func hasDetail(tensorId: Int64) -> Bool {
    canvasLayers(imageTensorId: tensorId)?.contains { $0.scaleFactorBy120 > 120 } == true
  }

  /// The layers of the step whose image is `tensorId` that the image (at 120) loses detail of, to
  /// draw over it at their own resolution where the canvas is zoomed in (`Self.detailLayers`).
  /// Empty for a step with none.
  func detailLayers(tensorId: Int64) -> [DetailLayer] {
    guard let layers = canvasLayers(imageTensorId: tensorId),
          let start = layers.firstIndex(where: { $0.scaleFactorBy120 > 120 }),
          let drawn = compositeLayers(Array(layers[start...]))
    else { return [] }
    // Placed on the whole canvas's union, from the rows (only the detail is decoded).
    let union = layers.dropFirst().reduce(Self.units(layers[0])) { $0.union(Self.units($1)) }
    return drawn.compactMap { layer in
      Self.masked(layer).map {
        DetailLayer(image: $0, rect: Self.units(layer).offsetBy(dx: -union.minX, dy: -union.minY))
      }
    }
  }

  /// Layer rows read for compositing; nil when any tensor is missing.
  private func compositeLayers(_ layers: [Layer]) -> [CompositeLayer]? {
    let drawn: [CompositeLayer] = layers.compactMap { layer in
      guard let image = tensor(id: layer.tensorId).flatMap(ImageTensor.cgImage(from:)) else { return nil }
      let mask = layer.maskId > 0 ? self.mask(id: layer.maskId) : nil
      return CompositeLayer(
        image: image, mask: mask?.codes, maskWidth: mask?.width ?? 0, maskHeight: mask?.height ?? 0,
        x: Int(layer.x), y: Int(layer.y), scaleFactorBy120: Int(layer.scaleFactorBy120))
    }
    return drawn.count == layers.count ? drawn : nil
  }

  /// The layers, bottom to top, of the step whose image (top) layer is `tensorId`, when they're
  /// more than one plain image at the origin; nil for a plain step.
  private func canvasLayers(imageTensorId tensorId: Int64) -> [Layer]? {
    for row in workspace.fetch(for: Layer.self).where(Layer.tensorId == tensorId) {
      let layers = workspace.fetch(for: Layer.self).where(
        Layer.lineage == row.lineage && Layer.logicalTime == row.logicalTime && Layer.tensorId > 0,
        orderBy: [Layer.index.ascending])
      guard layers.last?.tensorId == tensorId else { continue }
      let plain = layers.count == 1
        && layers[0].maskId == 0 && layers[0].x == 0 && layers[0].y == 0 && layers[0].scaleFactorBy120 == 120
      return plain ? nil : Array(layers)
    }
    return nil
  }

  /// The layers of the step whose image is `tensorId`, bottom to top, for checks: ids, place in
  /// units, size in the tensor's pixels and density (`scale_factor_by_120`).
  func layerSummary(tensorId: Int64) -> [(
    tensorId: Int64, maskId: Int64, x: Int32, y: Int32, width: Int32, height: Int32, scale: Int32
  )] {
    for row in workspace.fetch(for: Layer.self).where(Layer.tensorId == tensorId) {
      let layers = workspace.fetch(for: Layer.self).where(
        Layer.lineage == row.lineage && Layer.logicalTime == row.logicalTime, orderBy: [Layer.index.ascending])
      if layers.last?.tensorId == tensorId {
        return layers.map { ($0.tensorId, $0.maskId, $0.x, $0.y, $0.width, $0.height, $0.scaleFactorBy120) }
      }
    }
    return []
  }

  /// The step's own `scale_factor_by_120` (the top layer's density), for checks.
  func stepScale(tensorId: Int64) -> Int32? {
    for row in workspace.fetch(for: Layer.self).where(Layer.tensorId == tensorId) {
      if let node = workspace.fetch(for: TensorHistoryNode.self).where(
        TensorHistoryNode.lineage == row.lineage && TensorHistoryNode.logicalTime == row.logicalTime
      ).first {
        return node.scaleFactorBy120
      }
    }
    return nil
  }

  /// A layer's mask (`binary_mask_<id>`, `[height, width]` codes).
  private func mask(id: Int64) -> (codes: [UInt8], width: Int, height: Int)? {
    storeAccess.withLock { _ in
      var mask: (codes: [UInt8], width: Int, height: Int)?
      graph.openStore(url.path, flags: [.readOnly]) {
        guard let tensor = $0.read("binary_mask_\(id)", codec: [.fpzip, .zip]).map({ Tensor<UInt8>($0) }),
              tensor.shape.count == 2
        else { return }
        let height = tensor.shape[0], width = tensor.shape[1]
        let codes = tensor.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self).prefix(width * height)) }
        mask = (codes, width, height)
      }
      return mask
    }
  }

  /// One layer of a canvas: its image, mask codes, and position in canvas units.
  struct CompositeLayer {
    var image: CGImage
    var mask: [UInt8]?
    var maskWidth: Int
    var maskHeight: Int
    var x: Int
    var y: Int
    var scaleFactorBy120: Int
  }

  /// A full-detail read's density: its finest layer's (`canvasSize` never goes past that).
  static let finestDensity = Int.max

  /// The most pixels a canvas finer than its image may have: an iPad has much less memory.
  #if os(iOS)
    static let fullDetailPixels: Double = 64 * 1024 * 1024
  #else
    static let fullDetailPixels: Double = 256 * 1024 * 1024
  #endif

  /// A layer row's rectangle in canvas units, from its fields alone (nothing decoded).
  private static func units(_ row: Layer) -> CGRect {
    let scale = Double(max(row.scaleFactorBy120, 1)) / 120
    return CGRect(x: Double(row.x), y: Double(row.y), width: Double(row.width) / scale, height: Double(row.height) / scale)
  }

  /// A layer's rectangle in canvas units: (x, y, width·120/s, height·120/s), as
  /// `ImageHistoryManager` keeps `TensorData` (width and height in the tensor's pixels,
  /// `scale_factor_by_120` its pixels per unit ×120).
  static func units(_ layer: CompositeLayer) -> CGRect {
    let scale = Double(max(layer.scaleFactorBy120, 1)) / 120
    return CGRect(
      x: Double(layer.x), y: Double(layer.y), width: Double(layer.image.width) / scale,
      height: Double(layer.image.height) / scale)
  }

  /// The canvas the layers make at `density`: their union in units, the pixels per unit, and the
  /// size in pixels. Never finer than the finest layer (more pixels would add no detail), and a
  /// finer canvas than the image's own stays within 16384 pixels a side and `fullDetailPixels`,
  /// coarser if need be (a 4× refine of a large image is a lot of memory, on an iPad above all).
  /// Nil when empty or impossibly large.
  static func canvasSize(_ layers: [CompositeLayer], density: Int = 120) -> (
    union: CGRect, scale: Double, width: Int, height: Int
  )? {
    guard let first = layers.first else { return nil }
    let union = layers.dropFirst().reduce(units(first)) { $0.union(units($1)) }
    guard union.width > 0, union.height > 0 else { return nil }
    let finest = layers.map(\.scaleFactorBy120).max() ?? 120
    var by120 = max(min(density, finest), 1)
    if by120 > 120 {
      let limit = min(
        16384 / union.width, 16384 / union.height, (fullDetailPixels / (union.width * union.height)).squareRoot())
      by120 = max(min(by120, Int((limit * 120).rounded(.down))), 120)
    }
    let scale = Double(by120) / 120
    let width = Int((union.width * scale).rounded(.up)), height = Int((union.height * scale).rounded(.up))
    guard width > 0, height > 0, width <= 32768, height <= 32768 else { return nil }
    return (union, scale, width, height)
  }

  /// Layers composited as Draw Things draws its canvas: each covers its `units` rectangle, drawn
  /// in order bottom to top, its mask's codes giving its alpha (0 and 3 opaque, any other
  /// `byte & 0xF8`, `ImageConverter.image(from:scaleFactor:binaryMask:)`, the mask read
  /// nearest-neighbour at the layer's size). The result spans the layers' union at `density`
  /// (`canvasSize`; 120 is 1 pixel per unit, the image's own size); what no layer covers is
  /// transparent.
  static func composite(_ layers: [CompositeLayer], density: Int = 120) -> CGImage? {
    guard let size = canvasSize(layers, density: density) else { return nil }
    let (union, density, width, height) = (size.union, size.scale, size.width, size.height)
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    for layer in layers {
      guard let image = masked(layer) else { continue }
      let rect = units(layer)
      let drawn = CGRect(
        x: (rect.minX - union.minX) * density, y: (rect.minY - union.minY) * density,
        width: rect.width * density, height: rect.height * density)
      context.draw(
        image, in: CGRect(x: drawn.minX, y: Double(height) - drawn.maxY, width: drawn.width, height: drawn.height))
    }
    return context.makeImage()
  }

  /// A layer drawn over the image where the canvas shows more pixels than the image has: its
  /// image (mask applied) and its rectangle in the image's pixels.
  struct DetailLayer: @unchecked Sendable {
    var image: CGImage
    var rect: CGRect
  }

  /// The layers from the lowest one finer than 120 to the top, masked, each placed in the
  /// composite's pixels at 120 (`composite`'s union from its top left). Drawn in order over that
  /// composite, they give its finer detail at any zoom; layers above a fine one come too, so they
  /// still cover it as they do in the composite.
  static func detailLayers(_ layers: [CompositeLayer]) -> [DetailLayer] {
    guard let start = layers.firstIndex(where: { $0.scaleFactorBy120 > 120 }),
          let union = canvasSize(layers)?.union
    else { return [] }
    return layers[start...].compactMap { layer in
      masked(layer).map { DetailLayer(image: $0, rect: units(layer).offsetBy(dx: -union.minX, dy: -union.minY)) }
    }
  }

  /// A layer's image with its mask's alpha applied.
  private static func masked(_ layer: CompositeLayer) -> CGImage? {
    guard let mask = layer.mask, layer.maskWidth > 0, layer.maskHeight > 0 else { return layer.image }
    let width = layer.image.width, height = layer.image.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
      guard let context = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(layer.image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    let scaleY = Double(layer.maskHeight) / Double(height), scaleX = Double(layer.maskWidth) / Double(width)
    for y in 0..<height {
      let my = min(max(Int(((Double(y) + 0.5) * scaleY - 0.5).rounded()), 0), layer.maskHeight - 1)
      for x in 0..<width {
        let mx = min(max(Int(((Double(x) + 0.5) * scaleX - 0.5).rounded()), 0), layer.maskWidth - 1)
        let alpha = CanvasMask.Stored.alpha(mask[my * layer.maskWidth + mx])
        guard alpha != 255 else { continue }
        let index = (y * width + x) * 4
        for c in 0..<4 { rgba[index + c] = UInt8((Int(rgba[index + c]) * Int(alpha)) / 255) }
      }
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  /// A step's image tensor, if it has one.
  func imageTensorId(at id: StepID) -> Int64? {
    workspace.fetch(for: TensorHistoryNode.self).where(
      TensorHistoryNode.lineage == id.lineage && TensorHistoryNode.logicalTime == id.logicalTime
    ).first.flatMap(imageTensorId(of:))
  }

  /// A clip's soundtrack, or the audio file a run took: an `audio_<id>` tensor, PCM in
  /// [channels, samples] order.
  func audio(id: Int64) -> Tensor<Float>? {
    storeAccess.withLock { _ in
      var audio: Tensor<Float>?
      graph.openStore(url.path, flags: [.readOnly]) {
        audio = $0.read("audio_\(id)", codec: [.fpzip, .zip]).map { Tensor<Float>(from: $0) }
      }
      return audio
    }
  }

  // MARK: - Writing

  /// Appends an image as a new step after the step whose image is `parentTensorId` (the newest
  /// step when nil or gone): the tensor, the step, its canvas layer, its moodboard and both
  /// thumbnails. `generated` false records an image brought in from outside, as Draw Things'
  /// Imported steps. `inputTensorId` marks a step generated from the canvas, its parent.
  ///
  /// After the newest step this is a plain append on its lineage. After any other step it forks
  /// as `ImageHistoryManager.pushHistory` does (the canvas always holds an image, so it never
  /// overwrites): the new step starts a lineage above all others, at the parent's step number
  /// plus one. When the parent isn't on the greatest lineage at its step number, its whole
  /// lineage is renumbered first, earlier steps to two above the old greatest lineage and the
  /// rest to one above, and the new step goes on the higher one. Draw Things' parent rule no
  /// longer holds after that, so every step records its parent's tensor in `profile_data`, and
  /// the first fork records it for older steps that don't yet. All in one transaction.
  @concurrent func append(
    tensor: Tensor<FloatType>, model: String, prompt: String, negativePrompt: String,
    seed: UInt32, settings: [String: JSONValue], createdAt: Date, duration: Double,
    timings: GenerationTimings? = nil,
    reason: ProjectFormat.Reason = .generate, generated: Bool = true,
    moodboard: [MoodboardTensor] = [], inputTensorId: Int64? = nil,
    after parentTensorId: Int64? = nil, refined: RefinedStep? = nil,
    colorMatch: ColorMatch.Record? = nil
  ) async throws -> HistoryItem {
    try await append(
      frames: [tensor], clip: nil, model: model, prompt: prompt, negativePrompt: negativePrompt,
      seed: seed, settings: settings, createdAt: createdAt, duration: duration, timings: timings,
      reason: reason, generated: generated, moodboard: moodboard, inputTensorId: inputTensorId,
      after: parentTensorId, refined: refined, colorMatch: colorMatch)
  }

  /// A moodboard image going into a step.
  struct MoodboardTensor: Sendable {
    var tensor: Tensor<FloatType>
    var weight: Float
  }

  /// A video run's clip, beyond its frames.
  struct ClipContent: Sendable {
    var framesPerSecond: Double
    /// The soundtrack, PCM in [channels, samples] order.
    var audio: Tensor<Float>?
    /// The audio file the run took, kept so Use Settings can bring it back.
    var audioInput: Tensor<Float>?
  }

  /// Appends a video as Draw Things' `pushHistory(asClip:)` does: one step per frame, in order on
  /// one lineage after `parentTensorId` (forking there like `append`), each with its image layer
  /// and thumbnails, all sharing a new `clip` row that holds the frame rate, size and soundtrack
  /// (an `audio_<id>` tensor). Returns the first frame's step, which stands for the clip.
  @concurrent func appendClip(
    frames: [Tensor<FloatType>], clip: ClipContent, model: String, prompt: String,
    negativePrompt: String, seed: UInt32, settings: [String: JSONValue], createdAt: Date,
    duration: Double, timings: GenerationTimings? = nil, moodboard: [MoodboardTensor] = [],
    inputTensorId: Int64? = nil, after parentTensorId: Int64? = nil
  ) async throws -> HistoryItem {
    try await append(
      frames: frames, clip: clip, model: model, prompt: prompt, negativePrompt: negativePrompt,
      seed: seed, settings: settings, createdAt: createdAt, duration: duration, timings: timings,
      reason: .generate,
      generated: true, moodboard: moodboard, inputTensorId: inputTensorId, after: parentTensorId, refined: nil,
      colorMatch: nil)
  }

  private func append(
    frames tensors: [Tensor<FloatType>], clip: ClipContent?, model: String, prompt: String,
    negativePrompt: String, seed: UInt32, settings: [String: JSONValue], createdAt: Date,
    duration: Double, timings: GenerationTimings?, reason: ProjectFormat.Reason, generated: Bool,
    moodboard: [MoodboardTensor], inputTensorId: Int64?,
    after parentTensorId: Int64?, refined: RefinedStep?, colorMatch: ColorMatch.Record?
  ) async throws -> HistoryItem {
    // Each frame's thumbnails, a few frames at a time across the cores (a clip's frames
    // together are large, so each image is dropped once its thumbnails are made).
    typealias Thumbnails = (size: (width: Int32, height: Int32), full: [UInt8]?, half: [UInt8]?)
    let made = Mutex([Thumbnails?](repeating: nil, count: tensors.count))
    nonisolated(unsafe) let sources = tensors
    DispatchQueue.concurrentPerform(iterations: tensors.count) { index in
      guard let image = ImageTensor.cgImage(from: sources[index]) else { return }
      let thumbnails = (
        size: (Int32(image.width), Int32(image.height)),
        full: ImageTensor.jpeg(image, quality: 0.75),
        half: ImageTensor.downsampled(image).flatMap { ImageTensor.jpeg($0, quality: 0.5) })
      made.withLock { $0[index] = thumbnails }
    }
    let results = made.withLock { $0 }
    guard !results.isEmpty, !results.contains(where: { $0 == nil }) else { throw ProjectError.badImage }
    var thumbnails = results.map { (full: $0!.full, half: $0!.half) }
    if let composite = refined?.composite, refined?.layers != nil {
      // A layered step's thumbnail is its whole canvas, as Draw Things shows it.
      thumbnails[0] = (
        ImageTensor.jpeg(composite, quality: 0.75),
        ImageTensor.downsampled(composite).flatMap { ImageTensor.jpeg($0, quality: 0.5) })
    }
    let size = results[0]!.size
    var tensorIds: [Int64] = []
    while tensorIds.count < tensors.count {
      let id = Int64.random(in: 100_000_000...299_999_999)
      if !tensorIds.contains(id) { tensorIds.append(id) }
    }
    // As addImage: moodboard tensors are "shuffle_<id>" with ids in their own band. A clip's
    // frames share them.
    let shuffleIds = moodboard.map { _ in Int64.random(in: 1_600_000_000...1_799_999_999) }
    // As addAudio: "audio_<id>" in the band above.
    let audioId = clip?.audio.map { _ in Int64.random(in: 1_800_000_000...2_199_999_999) }
    let inputAudioId = clip?.audioInput.map { _ in Int64.random(in: 1_800_000_000...2_199_999_999) }
    let layered = refined?.layers.flatMap { layeredRefine($0, frameTensorId: tensorIds[0]) }
    var written: [String] = []
    do {
      try writeTensors(
        zip(tensors, tensorIds).map { ("tensor_history_\($1)", $0) }
          + zip(moodboard, shuffleIds).map { ("shuffle_\($1)", $0.tensor) })
      written = tensorIds.map { "tensor_history_\($0)" } + shuffleIds.map { "shuffle_\($0)" }
      if let audioId, let audio = clip?.audio {
        try writeTensor(audio, name: "audio_\(audioId)")
        written.append("audio_\(audioId)")
      }
      if let layered {
        for (name, tensor) in layered.images {
          try writeTensor(tensor, name: name)
          written.append(name)
        }
        for (name, mask) in layered.masks {
          try writeTensor(mask, name: name)
          written.append(name)
        }
      }
      if let inputAudioId, let audio = clip?.audioInput {
        try writeTensor(audio, name: "audio_\(inputAudioId)")
        written.append("audio_\(inputAudioId)")
      }
    } catch {
      removeTensors(written)
      throw error
    }

    // As in pushHistory: the preview id is the sum of the step's layer ids, plus each moodboard
    // image's id times its weight in thousandths.
    var moodboardPreview: Int64 = 0
    for (entry, shuffleId) in zip(moodboard, shuffleIds) {
      moodboardPreview &+= shuffleId &* Int64((entry.weight * 1000).rounded())
    }
    var previewIds = tensorIds.map { $0 &+ moodboardPreview }
    if let layered {
      // Every layer's tensor and mask (`ImageHistoryManager.pushHistory`).
      previewIds[0] = layered.rows.reduce(moodboardPreview) { $0 &+ $1.tensorId &+ $1.maskId }
    }
    let (width, height) = size
    let wallClock = Int64(createdAt.timeIntervalSince1970 * 1_000_000)

    let workspace = workspace
    // Read and written inside the transaction, so nothing else changes the tree in between.
    var appended: TensorHistoryNode?
    let succeeded = await withCheckedContinuation { continuation in
      workspace.performChanges([
        TensorHistoryNode.self, Layer.self, TensorMoodboardData.self, ThumbnailHistoryNode.self,
        ThumbnailHistoryHalfNode.self, Clip.self,
      ]) { transaction in
        let rows = Rows(workspace)
        let tree = ProjectTree(nodes: rows.nodes, layers: rows.layers, items: false)
        let parent = parentTensorId.flatMap(tree.step(tensorId:)) ?? tree.newest
        var changes = Changes()
        let first: StepID
        if let parent, let newest = tree.newest, parent != newest {
          changes.recordParents(tree, rows)
          first = changes.fork(from: parent, newest: newest, rows)
        } else {
          first = parent.map { StepID(lineage: $0.lineage, logicalTime: $0.logicalTime + 1) }
            ?? StepID(lineage: 0, logicalTime: 0)
        }
        changes.submit(rows, to: transaction)

        // As pushHistory: a new clip takes the next id.
        let clipId = clip.map { _ in
          (workspace.fetch(for: Clip.self).all(limit: .limit(1), orderBy: [Clip.clipId.descending])
            .first?.clipId ?? 0) + 1
        }
        for index in tensorIds.indices {
          let id = StepID(lineage: first.lineage, logicalTime: first.logicalTime + Int64(index))
          let step = ProjectMapping.Step(
            lineage: id.lineage, logicalTime: id.logicalTime, model: model, prompt: prompt,
            negativePrompt: negativePrompt, seed: seed, tensorId: tensorIds[index],
            previewId: previewIds[index], wallClock: wallClock + Int64(index),
            generationTime: duration, reason: reason, generated: generated,
            moodboardCount: moodboard.count,
            inputTensorId: index == 0 ? inputTensorId : nil,
            parentTensorId: index == 0
              ? parent.flatMap { tree.steps[$0]?.tensorId } : tensorIds[index - 1],
            clipId: clipId, indexInAClip: index, hasAudio: audioId != nil,
            inputAudioId: inputAudioId, timings: index == 0 ? timings : nil,
            refine: index == 0 ? refined?.record : nil,
            colorMatch: index == 0 ? colorMatch : nil,
            layerCount: index == 0 ? layered.map { Int32($0.rows.count) } : nil,
            contentOffset: index == 0 ? layered.map { ($0.rows.last!.x, $0.rows.last!.y) } : nil,
            canvasScale: index == 0 ? layered.map { $0.rows.last!.scaleFactorBy120 } : nil)
          let node = ProjectMapping.node(for: step, settings: settings)
          if index == 0 { appended = node }
          transaction.try(submit: TensorHistoryNodeChangeRequest.upsertRequest(node))
          if index == 0, let layered {
            for (layerIndex, row) in layered.rows.enumerated() {
              transaction.try(
                submit: ProjectFormat.TensorDataChangeRequest.upsertRequest(
                  Layer(
                    lineage: id.lineage, logicalTime: id.logicalTime, index: Int64(layerIndex), x: row.x, y: row.y,
                    width: row.width, height: row.height, scaleFactorBy120: row.scaleFactorBy120, tensorId: row.tensorId,
                    maskId: row.maskId)))
            }
          } else {
            transaction.try(
              submit: ProjectFormat.TensorDataChangeRequest.upsertRequest(
                Layer(
                  lineage: id.lineage, logicalTime: id.logicalTime, index: 0, x: 0, y: 0,
                  width: width, height: height, scaleFactorBy120: 120, tensorId: tensorIds[index])))
          }
          for (moodIndex, (entry, shuffleId)) in zip(moodboard, shuffleIds).enumerated() {
            transaction.try(
              submit: TensorMoodboardDataChangeRequest.upsertRequest(
                TensorMoodboardData(
                  lineage: id.lineage, logicalTime: id.logicalTime, index: Int64(moodIndex),
                  shuffleId: shuffleId, weight: entry.weight)))
          }
          if let full = thumbnails[index].full {
            transaction.try(
              submit: ThumbnailHistoryNodeChangeRequest.upsertRequest(
                ThumbnailHistoryNode(id: previewIds[index], data: full)))
          }
          if let half = thumbnails[index].half {
            transaction.try(
              submit: ThumbnailHistoryHalfNodeChangeRequest.upsertRequest(
                ThumbnailHistoryHalfNode(id: previewIds[index], data: half)))
          }
        }
        if let clip, let clipId {
          transaction.try(
            submit: ClipChangeRequest.upsertRequest(
              Clip(
                clipId: clipId, count: Int32(tensorIds.count), framesPerSecond: clip.framesPerSecond,
                width: width, height: height, audioId: audioId ?? 0)))
        }
      } completionHandler: { continuation.resume(returning: $0) }
    }
    guard succeeded, let node = appended else {
      removeTensors(written)
      throw ProjectError.writeFailed
    }
    // As pushHistory: the new step is the newest, which is where an open starts by default.
    setCurrentStep(nil)
    return HistoryItem(
      id: StepID(lineage: node.lineage, logicalTime: node.logicalTime), tensorId: tensorIds[0],
      previewId: previewIds[0], sidecar: Self.sidecar(for: node), inputTensorId: inputTensorId,
      moodboardCount: moodboard.count, weightedMoodboardCount: moodboard.count { $0.weight > 0 },
      clip: node.clipId >= 0
        ? ClipInfo(
          clipId: node.clipId, frames: tensorIds, framesPerSecond: clip?.framesPerSecond ?? 0,
          audioId: audioId, inputAudioId: inputAudioId, previewOffset: moodboardPreview) : nil)
  }

  /// One layer row of a layered step (`TensorData`): x and y in canvas units (the source's
  /// pixels), width and height in the tensor's pixels, `scaleFactorBy120` its pixels per unit ×120.
  struct LayerRow {
    var tensorId: Int64
    var maskId: Int64
    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32
    var scaleFactorBy120: Int32 = 120
  }

  /// The layers of a merged refine (`RefinedStep.Layers`) and the tensors they need written: the
  /// source at the origin, reusing its step's tensor when that step is one plain layer of the same
  /// image there, carrying the paint mask (0xF9 painted, else its alpha's code, as Draw Things'
  /// brush and `ImageConverter.imageAndMask(from:)` write them); then the source step's own
  /// detail layers (`carriedDetail`); then the frame, `frameTensorId`, at its density, with a
  /// mask only where it isn't opaque.
  private func layeredRefine(_ layers: RefinedStep.Layers, frameTensorId: Int64) -> (
    rows: [LayerRow], images: [(String, Tensor<FloatType>)], masks: [(String, Tensor<UInt8>)]
  )? {
    let source = layers.source
    let width = source.width, height = source.height
    guard let alpha = CanvasMask.alpha(of: source, width: width, height: height),
          let frameAlpha = layers.frameAlpha ?? CanvasMask.alpha(of: layers.frame, width: layers.frame.width, height: layers.frame.height)
    else { return nil }
    var images: [(String, Tensor<FloatType>)] = []
    var masks: [(String, Tensor<UInt8>)] = []
    func newMaskId() -> Int64 { Int64.random(in: 300_000_000...599_999_999) }
    let opaque = !alpha.contains { $0 != 255 }
    var sourceTensorId: Int64
    if let id = layers.sourceTensorId, opaque, isPlainLayer(tensorId: id, width: width, height: height) {
      sourceTensorId = id
    } else {
      guard let tensor = ImageTensor.tensor(from: source) else { return nil }
      repeat {
        sourceTensorId = Int64.random(in: 100_000_000...299_999_999)
      } while sourceTensorId == frameTensorId
      images.append(("tensor_history_\(sourceTensorId)", tensor))
    }
    var sourceMaskId: Int64 = 0
    let paint = layers.paint
    let codes = alpha.indices.map { index -> UInt8 in
      paint.map { $0[index] != 0 } == true ? CanvasMask.Stored.painted : CanvasMask.Stored.code(alpha: alpha[index])
    }
    // Only a mask that says something: paint (under the frame) or transparency.
    if codes.contains(where: { $0 != CanvasMask.Stored.opaque }) {
      sourceMaskId = newMaskId()
      masks.append(("binary_mask_\(sourceMaskId)", Self.maskTensor(codes, width: width, height: height)))
    }
    var frameMaskId: Int64 = 0
    if frameAlpha.contains(where: { $0 != 255 }) {
      repeat { frameMaskId = newMaskId() } while frameMaskId == sourceMaskId
      masks.append((
        "binary_mask_\(frameMaskId)",
        Self.maskTensor(frameAlpha.map(CanvasMask.Stored.code(alpha:)), width: layers.frame.width, height: layers.frame.height)))
    }
    let frame = LayerRow(
      tensorId: frameTensorId, maskId: frameMaskId, x: layers.frameX, y: layers.frameY,
      width: Int32(layers.frame.width), height: Int32(layers.frame.height),
      scaleFactorBy120: layers.frameScaleFactorBy120)
    let carried = layers.sourceTensorId.map {
      carriedDetail(from: $0, under: frame, frameAlpha: frameAlpha, frameWidth: layers.frame.width)
    } ?? []
    return (
      [LayerRow(tensorId: sourceTensorId, maskId: sourceMaskId, x: 0, y: 0, width: Int32(width), height: Int32(height))]
        + carried + [frame],
      images, masks
    )
  }

  /// Most layers a merged refine keeps: the source, its carried detail, the frame.
  static let maxRefineLayers = 8

  /// The detail layers of the source's step (`detailLayers`'s: from its lowest layer finer than
  /// 120 up), carried into a refine of it so its detail outlives the next refine: the same
  /// tensors and masks (deleting a step only removes names no other step uses), moved by where
  /// the source's top left was on its canvas. One the new frame covers wholly and opaquely is
  /// dropped, whatever its density: it could never show again. Past `maxRefineLayers` the oldest go: the source layer
  /// below them already has them, at its own pixels (it's the step's image), so dropping one
  /// flattens it into the source.
  private func carriedDetail(from sourceTensorId: Int64, under frame: LayerRow, frameAlpha: [UInt8], frameWidth: Int) -> [LayerRow] {
    guard let layers = canvasLayers(imageTensorId: sourceTensorId),
          let start = layers.firstIndex(where: { $0.scaleFactorBy120 > 120 })
    else { return [] }
    let union = layers.dropFirst().reduce(Self.units(layers[0])) { $0.union(Self.units($1)) }
    let frameScale = Double(frame.scaleFactorBy120) / 120
    let frameUnits = CGRect(
      x: Double(frame.x), y: Double(frame.y), width: Double(frame.width) / frameScale,
      height: Double(frame.height) / frameScale)
    var carried: [LayerRow] = []
    for row in layers[start...] {
      let rect = Self.units(row).offsetBy(dx: -union.minX, dy: -union.minY)
      if frameUnits.contains(rect) {
        // Covered when every frame pixel over it is opaque.
        let x0 = Int(((rect.minX - frameUnits.minX) * frameScale).rounded(.down))
        let x1 = min(Int(((rect.maxX - frameUnits.minX) * frameScale).rounded(.up)), Int(frame.width))
        let y0 = Int(((rect.minY - frameUnits.minY) * frameScale).rounded(.down))
        let y1 = min(Int(((rect.maxY - frameUnits.minY) * frameScale).rounded(.up)), Int(frame.height))
        let opaque = (y0..<max(y1, y0)).allSatisfy { y in (x0..<max(x1, x0)).allSatisfy { frameAlpha[y * frameWidth + $0] == 255 } }
        if opaque { continue }
      }
      carried.append(
        LayerRow(
          tensorId: row.tensorId, maskId: row.maskId, x: row.x - Int32(union.minX), y: row.y - Int32(union.minY),
          width: row.width, height: row.height, scaleFactorBy120: row.scaleFactorBy120))
    }
    return Array(carried.suffix(Self.maxRefineLayers - 2))
  }

  /// Whether `tensorId` is some step's only layer, a plain image at the origin of this size.
  private func isPlainLayer(tensorId: Int64, width: Int, height: Int) -> Bool {
    let rows = workspace.fetch(for: Layer.self).where(Layer.tensorId == tensorId)
    return rows.contains { row in
      row.x == 0 && row.y == 0 && row.scaleFactorBy120 == 120 && row.maskId == 0 && row.width == width
        && row.height == height
        && workspace.fetch(for: Layer.self).where(Layer.lineage == row.lineage && Layer.logicalTime == row.logicalTime).count == 1
    }
  }

  static func maskTensor(_ codes: [UInt8], width: Int, height: Int) -> Tensor<UInt8> {
    var mask = Tensor<UInt8>(.CPU, .NC(height, width))
    mask.withUnsafeMutableBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      for index in 0..<min(codes.count, bytes.count) { bytes[index] = codes[index] }
    }
    return mask
  }

  /// Deletes a step, its layers, thumbnails and tensors. Returns its parent's image tensor.
  @discardableResult
  @concurrent func delete(_ id: StepID) async throws -> Int64? {
    try await delete { _ in id }
  }

  /// Deletes every frame of a clip, as Draw Things deletes them one by one, last first; the last
  /// one takes the clip row and its soundtrack. Returns the first frame's parent's image tensor.
  ///
  /// A clip's frames are a run of step numbers on one lineage, which `deleteRun` deletes in one
  /// transaction, ending where the frame-by-frame deletes would; frame by frame, each delete
  /// reads and renumbers the whole project again, minutes for a clip in a project of many.
  /// Frames that aren't such a run are deleted frame by frame.
  @discardableResult
  @concurrent func deleteClip(frames: [Int64]) async throws -> Int64? {
    if let deleted = try await deleteRun(tensorIds: frames) { return deleted.parentTensorId }
    return try await deleteFrameByFrame(frames)
  }

  /// `deleteClip` as one `deleteHistory` per frame, last first: what `deleteRun` must match.
  @discardableResult
  @concurrent func deleteFrameByFrame(_ frames: [Int64]) async throws -> Int64? {
    var parent: Int64?
    for tensorId in frames.reversed() {
      parent = try await delete(tensorId: tensorId)
    }
    return parent
  }

  /// Deletes the steps whose images are `tensorIds`, when they're a run of step numbers on one
  /// lineage in that order, ending as `deleteHistory` on each of them, last first, would: one
  /// read, one renumbering (`Changes.shift(afterDeleting:on:)`) and one write. Their children
  /// outside the run record its first step's parent; thumbnails, clip rows and tensors go once
  /// nothing left uses them. Nil, changing nothing, when they aren't such a run, or when the
  /// frame-by-frame deletes could find other parents than the run does (`parentsHold`).
  func deleteRun(tensorIds: [Int64]) async throws -> DeletedRun? {
    let workspace = workspace
    var outcome: (tensorNames: [String], parentTensorId: Int64?)?
    let succeeded = await withCheckedContinuation { continuation in
      workspace.performChanges([
        TensorHistoryNode.self, Layer.self, TensorMoodboardData.self, ThumbnailHistoryNode.self,
        ThumbnailHistoryHalfNode.self, Clip.self,
      ]) { transaction in
        let rows = Rows(workspace)
        let tree = ProjectTree(nodes: rows.nodes, layers: rows.layers, items: false)
        // The steps the frame-by-frame deletes would find: deleting later steps never moves
        // earlier ones, so each image still names the step it names now.
        var run: [StepID] = []
        for tensorId in tensorIds {
          guard let id = tree.step(tensorId: tensorId), rows.byID[id] != nil,
                run.last.map({ id.lineage == $0.lineage && id.logicalTime == $0.logicalTime + 1 }) ?? true
          else { return }
          run.append(id)
        }
        guard let first = run.first, let last = run.last else { return }
        let deleted = Set(run)
        guard Self.parentsHold(deleting: run, images: tensorIds, tree, rows) else { return }
        let isDeleted = { (node: TensorHistoryNode) in
          deleted.contains(StepID(lineage: node.lineage, logicalTime: node.logicalTime))
        }

        // Each delete hands its children to its parent, so a child ends with the nearest
        // ancestor outside the run.
        func survivor(of id: StepID) -> StepID? {
          var seen: Set<StepID> = [id]
          var next = tree.steps[id]?.parent
          while let step = next, deleted.contains(step), seen.insert(step).inserted {
            next = tree.steps[step]?.parent
          }
          return next.flatMap { deleted.contains($0) ? nil : $0 }
        }
        let parentTensorId = survivor(of: first).flatMap { tree.steps[$0]?.tensorId }
        var changes = Changes()
        changes.recordParents(tree, rows)
        for id in run {
          let tensorId = survivor(of: id).flatMap { tree.steps[$0]?.tensorId } ?? 0
          for child in tree.children[id] ?? [] where !deleted.contains(child) {
            changes.setParent(of: child, to: tensorId, rows)
          }
        }
        // Deleted steps aren't written back (see `delete(_:)`).
        for id in run { changes.profiles[id] = nil }
        changes.shift(afterDeleting: first.logicalTime...last.logicalTime, on: first.lineage, rows)

        let isDeletedKey = { (lineage: Int64, logicalTime: Int64) in
          deleted.contains(StepID(lineage: lineage, logicalTime: logicalTime))
        }
        let nodes = rows.nodes.filter(isDeleted)
        let others = rows.nodes.filter { !isDeleted($0) }
        let layers = rows.layers.filter { isDeletedKey($0.lineage, $0.logicalTime) }
        let otherLayers = rows.layers.filter { !isDeletedKey($0.lineage, $0.logicalTime) }
        let moods = rows.moods.filter { isDeletedKey($0.lineage, $0.logicalTime) }
        let otherMoods = rows.moods.filter { !isDeletedKey($0.lineage, $0.logicalTime) }
        for node in nodes {
          if let request = TensorHistoryNodeChangeRequest.deletionRequest(node) {
            transaction.try(submit: request)
          }
        }
        for layer in layers {
          if let request = ProjectFormat.TensorDataChangeRequest.deletionRequest(layer) {
            transaction.try(submit: request)
          }
        }
        for mood in moods {
          if let request = TensorMoodboardDataChangeRequest.deletionRequest(mood) {
            transaction.try(submit: request)
          }
        }
        changes.submit(rows, to: transaction)

        // Thumbnails and tensors go once no step left uses them: a frame-by-frame delete keeps
        // what a frame still to go uses, and the last of them to go lets it go.
        let otherPreviews = Set(others.map(\.previewId))
        for previewId in Set(nodes.map(\.previewId)) where previewId != 0 && !otherPreviews.contains(previewId) {
          if let thumbnail = workspace.fetch(for: ThumbnailHistoryNode.self).where(
            ThumbnailHistoryNode.id == previewId
          ).first, let request = ThumbnailHistoryNodeChangeRequest.deletionRequest(thumbnail) {
            transaction.try(submit: request)
          }
          if let thumbnail = workspace.fetch(for: ThumbnailHistoryHalfNode.self).where(
            ThumbnailHistoryHalfNode.id == previewId
          ).first, let request = ThumbnailHistoryHalfNodeChangeRequest.deletionRequest(thumbnail) {
            transaction.try(submit: request)
          }
        }
        let used = Set(otherLayers.flatMap(Self.tensorNames(of:)))
          .union(others.compactMap { $0.tensorId > 0 ? "tensor_history_\($0.tensorId)" : nil })
          .union(otherMoods.map { "shuffle_\($0.shuffleId)" })
        var names = layers.flatMap(Self.tensorNames(of:)) + moods.map { "shuffle_\($0.shuffleId)" }
        names += nodes.compactMap { $0.tensorId > 0 ? "tensor_history_\($0.tensorId)" : nil }
        // As deleteHistory: a clip row and its soundtrack go with the clip's last frame.
        let goneClips = Set(nodes.map(\.clipId).filter { $0 >= 0 }).subtracting(others.map(\.clipId))
        if !goneClips.isEmpty {
          let clips = Array(workspace.fetch(for: Clip.self).all())
          let otherAudio = Set(clips.filter { !goneClips.contains($0.clipId) }.map(\.audioId))
          for clip in clips where goneClips.contains(clip.clipId) {
            if let request = ClipChangeRequest.deletionRequest(clip) { transaction.try(submit: request) }
            if clip.audioId > 0, !otherAudio.contains(clip.audioId) { names.append("audio_\(clip.audioId)") }
          }
        }
        // Reading every other step's settings for its audio input only when there's one to keep.
        let inputAudio = Set(nodes.compactMap { ProjectMapping.Profile($0.profileData)?.inputAudioId })
        if !inputAudio.isEmpty {
          let otherInputAudio = Set(others.compactMap { ProjectMapping.Profile($0.profileData)?.inputAudioId })
          names += inputAudio.subtracting(otherInputAudio).map { "audio_\($0)" }
        }
        outcome = (Array(Set(names).subtracting(used)), parentTensorId)
      } completionHandler: { continuation.resume(returning: $0) }
    }
    guard succeeded else { throw ProjectError.writeFailed }
    guard let outcome else { return nil }
    removeTensors(outcome.tensorNames)
    return DeletedRun(parentTensorId: outcome.parentTensorId)
  }

  /// Whether deleting `run` frame by frame, each delete reading the tree afresh, finds the parents
  /// the run reads once. A tree finds a parent by position (Draw Things' rule, the step one earlier
  /// with the greatest lineage not above) or by the recorded tensor, preferring the rule's step
  /// when its layers hold that tensor (`ProjectTree.init`); positions change as each delete
  /// renumbers later steps, so a recorded tensor must name the same step wherever things sit:
  /// - Each frame's image is that one step's image and in no other step's layers, so a tensor
  ///   recorded for a frame names it, by layers or by image, wherever its child sits.
  /// - A frame's other layers (a refined canvas's source) hold tensors that are no frame's, and
  ///   that only that frame holds, or only it and its parent, whose image it is (a source reused
  ///   from the step refined). A step recording such a tensor finds the parent or, when the frame
  ///   is the rule's step, the frame, whose delete hands it the parent's image: what it recorded.
  /// - No step that renumbering can put right after a frame records a tensor that's no other
  ///   step's image: its parent is the rule's step alone. The rule's step is a frame only for a
  ///   step on the run's lineage or above, numbered one past a frame; steps only move down, never
  ///   off their lineage, so that takes a lineage at or above the run's and a number past its
  ///   start. Others (older history, lower branches) never have a frame as the rule's step.
  /// Anything else (a frame's image shared, a frame holding another frame's image or another
  /// step's image beyond its parent's, a step recording a lost image) falls back frame by frame.
  /// Steps recording nothing get their rule parent recorded first, as the first delete does.
  private static func parentsHold(deleting run: [StepID], images: [Int64], _ tree: ProjectTree, _ rows: Rows) -> Bool {
    let deleted = Set(run)
    let frameTensors = Set(images)
    var holders: [Int64: Set<StepID>] = [:]
    var held: [StepID: Set<Int64>] = [:]
    for layer in rows.layers where layer.tensorId > 0 {
      let id = StepID(lineage: layer.lineage, logicalTime: layer.logicalTime)
      holders[layer.tensorId, default: []].insert(id)
      if deleted.contains(id) { held[id, default: []].insert(layer.tensorId) }
    }
    for (id, image) in zip(run, images) {
      guard tree.steps(tensorId: image) == [id], (holders[image] ?? [id]) == [id] else { return false }
      for tensorId in held[id] ?? [] where tensorId != image {
        guard !frameTensors.contains(tensorId) else { return false }
        let others = (holders[tensorId] ?? []).subtracting([id])
        guard others.isEmpty
          || (others.count == 1 && tree.steps(tensorId: tensorId) == Array(others)
            && tree.steps[id]?.parent == others.first)
        else { return false }
      }
    }
    guard let start = run.first else { return false }
    return !tree.steps.values.contains { step in
      guard !deleted.contains(step.id), step.id.lineage >= start.lineage, step.id.logicalTime > start.logicalTime,
            let recorded = step.recordedParent, recorded != 0
      else { return false }
      return tree.steps(tensorId: recorded).allSatisfy { $0 == step.id }
    }
  }

  /// What `deleteRun` deleted.
  nonisolated struct DeletedRun {
    var parentTensorId: Int64?
  }

  /// Deletes the step whose image is `tensorId`. Returns its parent's image tensor.
  @discardableResult
  @concurrent func delete(tensorId: Int64) async throws -> Int64? {
    try await delete { $0.step(tensorId: tensorId) }
  }

  /// Deletes a step as `ImageHistoryManager.deleteHistory` does: its layers and moodboard rows go,
  /// and later steps move down one step number on its lineage and on the higher lineages that
  /// have no step at its number (up to the greatest lineage there, when that's another step's).
  /// Its children record its parent as theirs.
  private func delete(_ target: @escaping @Sendable (ProjectTree) -> StepID?) async throws -> Int64? {
    let workspace = workspace
    var outcome: (tensorNames: [String], parentTensorId: Int64?)?
    let succeeded = await withCheckedContinuation { continuation in
      workspace.performChanges([
        TensorHistoryNode.self, Layer.self, TensorMoodboardData.self, ThumbnailHistoryNode.self,
        ThumbnailHistoryHalfNode.self, Clip.self,
      ]) { transaction in
        let rows = Rows(workspace)
        let tree = ProjectTree(nodes: rows.nodes, layers: rows.layers, items: false)
        guard let id = target(tree), let node = rows.byID[id] else { return }
        let parentTensorId = tree.steps[id]?.parent.flatMap { tree.steps[$0]?.tensorId }
        var changes = Changes()
        changes.recordParents(tree, rows)
        for child in tree.children[id] ?? [] {
          changes.setParent(of: child, to: parentTensorId ?? 0, rows)
        }
        // The deleted step isn't written back. Recording its parent (a step Draw Things wrote,
        // with none recorded) would put it back, over whichever step moves into its key.
        changes.profiles[id] = nil
        changes.shift(afterDeleting: id, rows)

        let layers = rows.layers.filter { $0.lineage == id.lineage && $0.logicalTime == id.logicalTime }
        let moods = rows.moods.filter { $0.lineage == id.lineage && $0.logicalTime == id.logicalTime }
        if let request = TensorHistoryNodeChangeRequest.deletionRequest(node) {
          transaction.try(submit: request)
        }
        for layer in layers {
          if let request = ProjectFormat.TensorDataChangeRequest.deletionRequest(layer) {
            transaction.try(submit: request)
          }
        }
        for mood in moods {
          if let request = TensorMoodboardDataChangeRequest.deletionRequest(mood) {
            transaction.try(submit: request)
          }
        }
        changes.submit(rows, to: transaction)

        // Thumbnails and tensors go once no other step uses them.
        let others = rows.nodes.filter { $0.lineage != id.lineage || $0.logicalTime != id.logicalTime }
        if node.previewId != 0, !others.contains(where: { $0.previewId == node.previewId }) {
          if let thumbnail = workspace.fetch(for: ThumbnailHistoryNode.self).where(
            ThumbnailHistoryNode.id == node.previewId
          ).first, let request = ThumbnailHistoryNodeChangeRequest.deletionRequest(thumbnail) {
            transaction.try(submit: request)
          }
          if let thumbnail = workspace.fetch(for: ThumbnailHistoryHalfNode.self).where(
            ThumbnailHistoryHalfNode.id == node.previewId
          ).first, let request = ThumbnailHistoryHalfNodeChangeRequest.deletionRequest(thumbnail) {
            transaction.try(submit: request)
          }
        }
        let otherLayers = rows.layers.filter { !($0.lineage == id.lineage && $0.logicalTime == id.logicalTime) }
        let used = Set(otherLayers.flatMap(Self.tensorNames(of:)))
          .union(others.compactMap { $0.tensorId > 0 ? "tensor_history_\($0.tensorId)" : nil })
          .union(
            rows.moods.filter { !($0.lineage == id.lineage && $0.logicalTime == id.logicalTime) }
              .map { "shuffle_\($0.shuffleId)" })
        var names = layers.flatMap(Self.tensorNames(of:)) + moods.map { "shuffle_\($0.shuffleId)" }
        if node.tensorId > 0 { names.append("tensor_history_\(node.tensorId)") }
        // As deleteHistory: the clip row and its soundtrack go with the clip's last frame.
        if node.clipId >= 0, !others.contains(where: { $0.clipId == node.clipId }),
           let clip = workspace.fetch(for: Clip.self).where(Clip.clipId == node.clipId).first
        {
          if let request = ClipChangeRequest.deletionRequest(clip) { transaction.try(submit: request) }
          let otherClips = workspace.fetch(for: Clip.self).all().filter { $0.clipId != node.clipId }
          if clip.audioId > 0, !otherClips.contains(where: { $0.audioId == clip.audioId }) {
            names.append("audio_\(clip.audioId)")
          }
        }
        if let inputAudioId = ProjectMapping.Profile(node.profileData)?.inputAudioId,
           !others.contains(where: { ProjectMapping.Profile($0.profileData)?.inputAudioId == inputAudioId })
        {
          names.append("audio_\(inputAudioId)")
        }
        outcome = (names.filter { !used.contains($0) }, parentTensorId)
      } completionHandler: { continuation.resume(returning: $0) }
    }
    guard succeeded else { throw ProjectError.writeFailed }
    guard let outcome else { return nil }
    removeTensors(outcome.tensorNames)
    return outcome.parentTensorId
  }

  /// For `--project-check`: drops every recorded parent, as in projects written before branching.
  @concurrent func forgetParentLinks() async {
    let workspace = workspace
    _ = await withCheckedContinuation { continuation in
      workspace.performChanges([TensorHistoryNode.self]) { transaction in
        for node in workspace.fetch(for: TensorHistoryNode.self).all() {
          guard var profile = ProjectMapping.Profile(node.profileData) else { continue }
          profile.parentTensorId = nil
          var builder = TensorHistoryNodeBuilder(from: node)
          builder.profileData = profile.bytes
          transaction.try(submit: TensorHistoryNodeChangeRequest.upsertRequest(builder.build()))
        }
      } completionHandler: { continuation.resume(returning: $0) }
    }
  }

  /// Every step, layer and moodboard row, read inside a transaction.
  private struct Rows {
    var nodes: [TensorHistoryNode]
    var byID: [StepID: TensorHistoryNode] = [:]
    var layers: [Layer]
    var moods: [TensorMoodboardData]

    init(_ workspace: SQLiteWorkspace) {
      nodes = Array(workspace.fetch(for: TensorHistoryNode.self).all())
      layers = Array(workspace.fetch(for: Layer.self).all())
      moods = Array(workspace.fetch(for: TensorMoodboardData.self).all())
      for node in nodes { byID[StepID(lineage: node.lineage, logicalTime: node.logicalTime)] = node }
    }
  }

  /// Edits to existing steps, written together: new keys for moved steps (their layers and
  /// moodboard rows move with them) and new parent links in `profile_data`.
  private struct Changes {
    var moved: [StepID: StepID] = [:]
    var profiles: [StepID: [UInt8]] = [:]

    /// Records each step's parent tensor where it isn't recorded yet, while Draw Things' rule
    /// still gives the parent.
    mutating func recordParents(_ tree: ProjectTree, _ rows: Rows) {
      for step in tree.steps.values where !step.recordsParent {
        if let parent = step.parent {
          if let tensorId = tree.steps[parent]?.tensorId { setParent(of: step.id, to: tensorId, rows) }
        } else if step.id.logicalTime > 0 {
          setParent(of: step.id, to: 0, rows)
        }
      }
    }

    mutating func setParent(of id: StepID, to tensorId: Int64, _ rows: Rows) {
      guard let node = rows.byID[id] else { return }
      var profile = ProjectMapping.Profile(node.profileData)
        ?? ProjectMapping.Profile(duration: node.generationTime, inputTensorId: nil, parentTensorId: nil)
      profile.parentTensorId = tensorId
      profiles[id] = profile.bytes
    }

    /// pushHistory's fork from `parent` (not the newest step); returns the new step's key.
    mutating func fork(from parent: StepID, newest: StepID, _ rows: Rows) -> StepID {
      let maxLineage = newest.lineage
      // The greatest lineage at the parent's step number: Draw Things' "sacred" one there.
      if parent.logicalTime > 0,
         let sacred = rows.nodes.filter({ $0.logicalTime == parent.logicalTime }).map(\.lineage).max(),
         parent.lineage < sacred
      {
        for node in rows.nodes where node.lineage == parent.lineage {
          moved[StepID(lineage: node.lineage, logicalTime: node.logicalTime)] = StepID(
            lineage: node.logicalTime < parent.logicalTime ? maxLineage + 2 : maxLineage + 1,
            logicalTime: node.logicalTime)
        }
        return StepID(lineage: maxLineage + 2, logicalTime: parent.logicalTime + 1)
      }
      return StepID(lineage: maxLineage + 1, logicalTime: parent.logicalTime + 1)
    }

    /// deleteHistory's renumbering: which later steps move down one step number.
    mutating func shift(afterDeleting id: StepID, _ rows: Rows) {
      let time = id.logicalTime
      let maxAtTime = rows.nodes.filter { $0.logicalTime == time }.map(\.lineage).max() ?? id.lineage
      let upper = maxAtTime > id.lineage ? maxAtTime : .max
      let inRange = rows.nodes.filter {
        $0.logicalTime >= time && $0.lineage >= id.lineage && $0.lineage < upper
      }
      // Lineages with a step of their own at that number are other branches; they stay.
      let unrelated = Set(
        inRange.filter { $0.logicalTime == time && $0.lineage != id.lineage }.map(\.lineage))
      for node in inRange where node.logicalTime != time && !unrelated.contains(node.lineage) {
        moved[StepID(lineage: node.lineage, logicalTime: node.logicalTime)] = StepID(
          lineage: node.lineage, logicalTime: node.logicalTime - 1)
      }
    }

    /// `shift(afterDeleting:)` for each step numbered `run` on `lineage`, last first, at once.
    /// The delete at `t` judges lineages by the steps numbered `t`, which the deletes before it
    /// (all later numbers) never move: a lineage moves there when it's `lineage`, or below the
    /// greatest lineage at `t` (when that's above `lineage`) with no step of its own at `t`. A step
    /// numbered `s` past the run's start moves once for each such `t` before `s`: the earlier
    /// deletes leave it above `t` (and a step at `t` on another lineage keeps its own there).
    mutating func shift(afterDeleting run: ClosedRange<Int64>, on lineage: Int64, _ rows: Rows) {
      var greatest: [Int64: Int64] = [:]
      var lineagesAt: [Int64: Set<Int64>] = [:]
      for node in rows.nodes where run.contains(node.logicalTime) {
        greatest[node.logicalTime] = max(greatest[node.logicalTime] ?? node.lineage, node.lineage)
        lineagesAt[node.logicalTime, default: []].insert(node.lineage)
      }
      for node in rows.nodes where node.lineage >= lineage && node.logicalTime > run.lowerBound {
        // The run's own steps go.
        if node.lineage == lineage, run.contains(node.logicalTime) { continue }
        var count: Int64 = 0
        for time in run.lowerBound...min(node.logicalTime - 1, run.upperBound) {
          let maxAtTime = greatest[time] ?? lineage
          let upper = maxAtTime > lineage ? maxAtTime : .max
          guard node.lineage < upper else { continue }
          if node.lineage == lineage || lineagesAt[time]?.contains(node.lineage) != true { count += 1 }
        }
        if count > 0 {
          moved[StepID(lineage: node.lineage, logicalTime: node.logicalTime)] = StepID(
            lineage: node.lineage, logicalTime: node.logicalTime - count)
        }
      }
    }

    /// Old keys are deleted before anything is written, so a key freed by one move can take the
    /// next.
    func submit(_ rows: Rows, to transaction: TransactionContext) {
      let layers = rows.layers.filter { moved[StepID(lineage: $0.lineage, logicalTime: $0.logicalTime)] != nil }
      let moods = rows.moods.filter { moved[StepID(lineage: $0.lineage, logicalTime: $0.logicalTime)] != nil }
      for old in moved.keys {
        if let node = rows.byID[old], let request = TensorHistoryNodeChangeRequest.deletionRequest(node) {
          transaction.try(submit: request)
        }
      }
      for layer in layers {
        if let request = ProjectFormat.TensorDataChangeRequest.deletionRequest(layer) {
          transaction.try(submit: request)
        }
      }
      for mood in moods {
        if let request = TensorMoodboardDataChangeRequest.deletionRequest(mood) {
          transaction.try(submit: request)
        }
      }
      for old in Set(moved.keys).union(profiles.keys) {
        guard let node = rows.byID[old] else { continue }
        var builder = TensorHistoryNodeBuilder(from: node)
        if let new = moved[old] {
          builder.lineage = new.lineage
          builder.logicalTime = new.logicalTime
        }
        if let profile = profiles[old] { builder.profileData = profile }
        transaction.try(submit: TensorHistoryNodeChangeRequest.upsertRequest(builder.build()))
      }
      for layer in layers {
        guard let new = moved[StepID(lineage: layer.lineage, logicalTime: layer.logicalTime)] else { continue }
        var builder = ProjectFormat.TensorDataBuilder(from: layer)
        builder.lineage = new.lineage
        builder.logicalTime = new.logicalTime
        transaction.try(submit: ProjectFormat.TensorDataChangeRequest.upsertRequest(builder.build()))
      }
      for mood in moods {
        guard let new = moved[StepID(lineage: mood.lineage, logicalTime: mood.logicalTime)] else { continue }
        var builder = TensorMoodboardDataBuilder(from: mood)
        builder.lineage = new.lineage
        builder.logicalTime = new.logicalTime
        transaction.try(submit: TensorMoodboardDataChangeRequest.upsertRequest(builder.build()))
      }
    }
  }

  #if DEBUG
  /// For tests: adds a layer of image `tensorId` at index `index` to the step whose image is
  /// `imageOf`, as a refined canvas's source or as Draw Things projects share tensors, with a new
  /// mask `maskId`; `writing` writes a new tensor for it.
  @concurrent func addLayerForTests(
    tensorId: Int64, index: Int64, toStepOf imageOf: Int64, maskId: Int64 = 0, writing: Bool = false
  ) async throws {
    if writing { try writeTensor(Tensor<FloatType>(.CPU, .NHWC(1, 8, 8, 3)), name: "tensor_history_\(tensorId)") }
    if maskId > 0 {
      let codes = [UInt8](repeating: CanvasMask.Stored.painted, count: 64)
      try writeTensor(Self.maskTensor(codes, width: 8, height: 8), name: "binary_mask_\(maskId)")
    }
    let workspace = workspace
    _ = await withCheckedContinuation { continuation in
      workspace.performChanges([TensorHistoryNode.self, Layer.self]) { transaction in
        let tree = ProjectTree(
          nodes: Array(workspace.fetch(for: TensorHistoryNode.self).all()),
          layers: Array(workspace.fetch(for: Layer.self).all()), items: false)
        guard let id = tree.step(tensorId: imageOf),
              let layer = workspace.fetch(for: Layer.self).where(
                Layer.lineage == id.lineage && Layer.logicalTime == id.logicalTime
              ).first
        else { return }
        var builder = ProjectFormat.TensorDataBuilder(from: layer)
        builder.index = index
        builder.tensorId = tensorId
        builder.maskId = maskId
        transaction.try(submit: ProjectFormat.TensorDataChangeRequest.upsertRequest(builder.build()))
      } completionHandler: { continuation.resume(returning: $0) }
    }
  }

  /// For tests: makes `tensorId` the image of the step whose image is `imageOf` through the node's
  /// own field, as Draw Things steps without layers keep it, so two steps share one image.
  @concurrent func setNodeImageForTests(tensorId: Int64, ofStepOf imageOf: Int64) async {
    let workspace = workspace
    _ = await withCheckedContinuation { continuation in
      workspace.performChanges([TensorHistoryNode.self, Layer.self, TensorMoodboardData.self]) { transaction in
        let rows = Rows(workspace)
        let tree = ProjectTree(nodes: rows.nodes, layers: rows.layers, items: false)
        guard let id = tree.step(tensorId: imageOf), let node = rows.byID[id] else { return }
        var builder = TensorHistoryNodeBuilder(from: node)
        builder.dataStored = 0
        builder.tensorId = tensorId
        transaction.try(submit: TensorHistoryNodeChangeRequest.upsertRequest(builder.build()))
      } completionHandler: { continuation.resume(returning: $0) }
    }
  }

  /// For tests: records `parentTensorId` as the parent of the step whose image is `imageOf`.
  @concurrent func setRecordedParentForTests(_ parentTensorId: Int64, ofStepOf imageOf: Int64) async {
    let workspace = workspace
    _ = await withCheckedContinuation { continuation in
      workspace.performChanges([TensorHistoryNode.self, Layer.self, TensorMoodboardData.self]) { transaction in
        let rows = Rows(workspace)
        let tree = ProjectTree(nodes: rows.nodes, layers: rows.layers, items: false)
        guard let id = tree.step(tensorId: imageOf), let node = rows.byID[id],
              var profile = ProjectMapping.Profile(node.profileData)
        else { return }
        profile.parentTensorId = parentTensorId
        var builder = TensorHistoryNodeBuilder(from: node)
        builder.profileData = profile.bytes
        transaction.try(submit: TensorHistoryNodeChangeRequest.upsertRequest(builder.build()))
      } completionHandler: { continuation.resume(returning: $0) }
    }
  }

  /// For tests: every row a delete changes, in key order, and the tensor store's names.
  nonisolated struct Contents: Equatable {
    var nodes: [TensorHistoryNode]
    var layers: [ProjectFormat.TensorData]
    var moods: [TensorMoodboardData]
    var clips: [Clip]
    var thumbnails: [Int64]
    var halfThumbnails: [Int64]
    var tensorNames: [String]
  }

  func contents() -> Contents {
    let key = { (lineage: Int64, logicalTime: Int64) in [lineage, logicalTime] }
    let tensorNames = storeAccess.withLock { _ in
      var names: [String] = []
      _ = graph.openStore(url.path, flags: [.readOnly]) { names = $0.keys }
      return names.sorted()
    }
    return workspace.fetchWithinASnapshot {
      Contents(
        // JSONEncoder orders keys as it likes, so profiles are compared with their keys sorted.
        nodes: workspace.fetch(for: TensorHistoryNode.self).all().map { node in
          guard let object = try? JSONSerialization.jsonObject(with: Data(node.profileData)),
                let sorted = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
          else { return node }
          var builder = TensorHistoryNodeBuilder(from: node)
          builder.profileData = [UInt8](sorted)
          return builder.build()
        }
        .sorted { key($0.lineage, $0.logicalTime).lexicographicallyPrecedes(key($1.lineage, $1.logicalTime)) },
        layers: workspace.fetch(for: Layer.self).all()
          .sorted { (key($0.lineage, $0.logicalTime) + [$0.index]).lexicographicallyPrecedes(key($1.lineage, $1.logicalTime) + [$1.index]) },
        moods: workspace.fetch(for: TensorMoodboardData.self).all()
          .sorted { (key($0.lineage, $0.logicalTime) + [$0.index]).lexicographicallyPrecedes(key($1.lineage, $1.logicalTime) + [$1.index]) },
        clips: workspace.fetch(for: Clip.self).all().sorted { $0.clipId < $1.clipId },
        thumbnails: workspace.fetch(for: ThumbnailHistoryNode.self).all().map(\.id).sorted(),
        halfThumbnails: workspace.fetch(for: ThumbnailHistoryHalfNode.self).all().map(\.id).sorted(),
        tensorNames: tensorNames)
    }
  }

  #endif

  private static func tensorNames(of layer: Layer) -> [String] {
    [
      ("tensor_history", layer.tensorId), ("binary_mask", layer.maskId),
      ("depth_map", layer.depthMapId), ("scribble", layer.scribbleId), ("pose", layer.poseId),
      ("color_palette", layer.colorPaletteId), ("custom", layer.customId),
    ].compactMap { $0.1 > 0 ? "\($0.0)_\($0.1)" : nil }
  }

  private func writeTensor<Element: TensorNumeric>(_ tensor: Tensor<Element>, name: String) throws {
    try writeTensors([(name, tensor)])
  }

  /// Writes the tensors in one opening of the store.
  private func writeTensors<Element: TensorNumeric>(_ tensors: [(name: String, tensor: Tensor<Element>)])
    throws
  {
    let failed = storeAccess.withLock { _ in
      // Default flags would truncate the file on close; Draw Things opens it with none.
      let result = graph.openStore(url.path, flags: []) { store in
        for (name, tensor) in tensors { store.write(name, tensor: tensor, codec: [.fpzip, .zip]) }
      }
      if case .failure = result { return true }
      return false
    }
    if failed { throw ProjectError.writeFailed }
  }

  private func removeTensors(_ names: [String]) {
    guard !names.isEmpty else { return }
    storeAccess.withLock { _ in
      _ = graph.openStore(url.path, flags: []) { store in
        for name in names { store.remove(name) }
      }
    }
  }
}

/// A project's steps and how they connect. A step's parent is the step whose image it recorded
/// as `parent_tensor_id`, when there is one; otherwise Draw Things' rule: the step one number
/// earlier with the greatest lineage not above its own.
///
/// A step's image is its top canvas layer. Draw Things places a generation over part of a larger
/// canvas as a new layer, so the layers below repeat the earlier image on every step that builds
/// on it.
nonisolated struct ProjectTree: Sendable {
  struct Step {
    var id: StepID
    /// The image layer's tensor.
    var tensorId: Int64?
    var parent: StepID?
    var generated: Bool
    var wallClock: Int64
    /// Whether `profile_data` records the parent (`parent_tensor_id`).
    var recordsParent: Bool
    /// The parent tensor `profile_data` records (0: none).
    var recordedParent: Int64?
  }

  private(set) var steps: [StepID: Step] = [:]
  /// The generated steps, as History lists them.
  private(set) var items: [StepID: HistoryItem] = [:]
  /// Each step's children, newest first.
  private(set) var children: [StepID: [StepID]] = [:]
  /// The step with the greatest lineage and, on it, the greatest step number: the one Draw Things
  /// opens on and appends after.
  private(set) var newest: StepID?
  private var byTensor: [Int64: [StepID]] = [:]
  /// Each clip frame's step: the item listing the clip (its first frame).
  private var clipItems: [StepID: StepID] = [:]
  private var greatestLineage: [Int64: Int64] = [:]
  /// The images of steps with a layer mask (a Draw Things canvas, or a merged refine's source
  /// layer): what `Project.layerMask` may find paint in.
  private(set) var layerMaskedImages: Set<Int64> = []

  init() {}

  /// `items` false leaves out History's items (their settings take longest to read).
  init(
    nodes: [TensorHistoryNode], layers: [ProjectFormat.TensorData], clips: [Clip] = [],
    moods: [TensorMoodboardData] = [], items withItems: Bool = true
  ) {
    // Each step's moodboard images with weight, which History's items count.
    var weightedMoods: [StepID: Int] = [:]
    for mood in moods where mood.weight > 0 {
      weightedMoods[StepID(lineage: mood.lineage, logicalTime: mood.logicalTime), default: 0] += 1
    }
    // The image layer: the top layer with a tensor, else the node's own field.
    var layerTensors: [StepID: (index: Int64, tensorId: Int64)] = [:]
    var allLayerTensors: [StepID: Set<Int64>] = [:]
    var maskedSteps: Set<StepID> = []
    for layer in layers where layer.tensorId > 0 {
      let id = StepID(lineage: layer.lineage, logicalTime: layer.logicalTime)
      if layer.maskId > 0 { maskedSteps.insert(id) }
      allLayerTensors[id, default: []].insert(layer.tensorId)
      if layerTensors[id].map({ layer.index > $0.index }) ?? true {
        layerTensors[id] = (layer.index, layer.tensorId)
      }
    }
    var byTime: [Int64: [StepID]] = [:]
    var profiles: [StepID: ProjectMapping.Profile] = [:]
    var clipFrames: [Int64: [(index: Int32, tensorId: Int64)]] = [:]
    var clipFrameSteps: [Int64: [StepID]] = [:]
    var clipListings: [Int64: (id: StepID, inputAudioId: Int64?)] = [:]
    for node in nodes {
      let id = StepID(lineage: node.lineage, logicalTime: node.logicalTime)
      let tensorId =
        node.dataStored > 0 ? layerTensors[id]?.tensorId : (node.tensorId > 0 ? node.tensorId : nil)
      let profile = ProjectMapping.Profile(node.profileData)
      profiles[id] = profile
      steps[id] = Step(
        id: id, tensorId: tensorId, parent: nil, generated: node.generated,
        wallClock: node.wallClock, recordsParent: profile?.parentTensorId != nil,
        recordedParent: profile?.parentTensorId)
      if let tensorId { byTensor[tensorId, default: []].append(id) }
      byTime[id.logicalTime, default: []].append(id)
      greatestLineage[id.logicalTime] = max(greatestLineage[id.logicalTime] ?? .min, id.lineage)
      if newest.map({ (id.lineage, id.logicalTime) > ($0.lineage, $0.logicalTime) }) ?? true {
        newest = id
      }
      if node.clipId >= 0, let tensorId {
        clipFrames[node.clipId, default: []].append((node.indexInAClip, tensorId))
        clipFrameSteps[node.clipId, default: []].append(id)
      }
      // A clip is listed once, by its first frame.
      if withItems, node.generated, let tensorId, node.clipId < 0 || node.indexInAClip == 0 {
        items[id] = HistoryItem(
          id: id, tensorId: tensorId, previewId: node.previewId, sidecar: Project.sidecar(for: node),
          inputTensorId: profile?.inputTensorId, moodboardCount: Int(node.shuffleDataStored),
          weightedMoodboardCount: weightedMoods[id] ?? 0)
        if node.clipId >= 0 {
          clipListings[node.clipId] = (id, profile?.inputAudioId)
        }
      }
    }
    let clipRows = Dictionary(clips.map { ($0.clipId, $0) }, uniquingKeysWith: { a, _ in a })
    for (clipId, item) in clipListings {
      let frames = (clipFrames[clipId] ?? []).sorted { $0.index < $1.index }.map(\.tensorId)
      let row = clipRows[clipId]
      let first = items[item.id]
      items[item.id]?.clip = ClipInfo(
        clipId: clipId, frames: frames, framesPerSecond: row?.framesPerSecond ?? 0,
        audioId: row.flatMap { $0.audioId > 0 ? $0.audioId : nil }, inputAudioId: item.inputAudioId,
        previewOffset: (first?.previewId ?? 0) &- (first?.tensorId ?? 0))
      for frame in clipFrameSteps[clipId] ?? [] { clipItems[frame] = item.id }
    }
    for id in Array(steps.keys) {
      let ruleParent = byTime[id.logicalTime - 1]?.filter { $0.lineage <= id.lineage }
        .max { $0.lineage < $1.lineage }
      let parent: StepID?
      if let recorded = profiles[id]?.parentTensorId, recorded == 0 {
        parent = nil
      } else if let recorded = profiles[id]?.parentTensorId, let ruleParent,
                allLayerTensors[ruleParent]?.contains(recorded) == true
      {
        // Earlier builds recorded a canvas's bottom layer, which every step drawn over that
        // canvas shares; Draw Things' rule picks the right one of them.
        parent = ruleParent
      } else if let recorded = profiles[id]?.parentTensorId,
                byTensor[recorded]?.contains(where: { $0 != id }) == true
      {
        parent = candidate(for: recorded, child: id)
      } else {
        parent = ruleParent
      }
      steps[id]?.parent = parent
      if let parent { children[parent, default: []].append(id) }
    }
    for (id, list) in children { children[id] = list.sorted(by: isNewer) }
    layerMaskedImages = Set(maskedSteps.compactMap { steps[$0]?.tensorId })
  }

  /// Where a recorded tensor appears on more than one step (Draw Things can share one), the
  /// latest one before the child.
  private func candidate(for tensorId: Int64, child: StepID) -> StepID? {
    let candidates = (byTensor[tensorId] ?? []).filter { $0 != child }
    return candidates.filter { $0.logicalTime < child.logicalTime }.max { $0.logicalTime < $1.logicalTime }
      ?? candidates.first
  }

  /// Newer first: by creation time, then by key.
  func isNewer(_ a: StepID, _ b: StepID) -> Bool {
    let (x, y) = (steps[a]?.wallClock ?? 0, steps[b]?.wallClock ?? 0)
    if x != y { return x > y }
    return (a.lineage, a.logicalTime) > (b.lineage, b.logicalTime)
  }

  /// The step holding the image `tensorId`.
  func step(tensorId: Int64) -> StepID? {
    byTensor[tensorId]?.first
  }

  /// Every step whose image is `tensorId` (Draw Things can share one).
  func steps(tensorId: Int64) -> [StepID] {
    byTensor[tensorId] ?? []
  }

  /// The item listing the clip whose frame is the image `tensorId` (the clip's first frame), when
  /// it's a clip frame.
  func clipItem(frame tensorId: Int64) -> StepID? {
    byTensor[tensorId]?.lazy.compactMap { clipItems[$0] }.first
  }

  /// `id`, its parent, and so on to the first step.
  func ancestry(of id: StepID) -> [StepID] {
    var line: [StepID] = []
    var seen: Set<StepID> = []
    var next: StepID? = steps[id] != nil ? id : nil
    while let step = next, seen.insert(step).inserted {
      line.append(step)
      next = steps[step]?.parent
    }
    return line
  }

  /// The main line: the newest step's ancestry, newest first.
  var mainLine: [StepID] { newest.map(ancestry(of:)) ?? [] }

  /// Draw Things' "sacred" step at a step number: the one with the greatest lineage there.
  func sacredStep(at logicalTime: Int64) -> StepID? {
    greatestLineage[logicalTime].map { StepID(lineage: $0, logicalTime: logicalTime) }
  }

  /// The sacred step at every step number, first to last (what Draw Things' slider walks).
  var sacredLine: [StepID] {
    greatestLineage.keys.sorted().compactMap(sacredStep(at:))
  }

  /// Every generated step, newest first.
  var itemsNewestFirst: [HistoryItem] {
    items.keys.sorted(by: isNewer).compactMap { items[$0] }
  }

  /// The nearest generated step at or above `id`.
  func visibleAncestor(of id: StepID) -> StepID? {
    ancestry(of: id).first { items[$0] != nil }
  }

  /// The generated step standing for `id` in the views: itself, else the clip it's a frame of,
  /// else the nearest generated step below it (newest first), else the nearest above it.
  func representative(of id: StepID) -> StepID? {
    if items[id] != nil { return id }
    // A clip is current at its last frame; the clip stands for it, not a run that follows it.
    if let clip = clipItems[id] { return clip }
    var queue = children[id] ?? []
    var seen: Set<StepID> = [id]
    while !queue.isEmpty {
      let step = queue.removeFirst()
      guard seen.insert(step).inserted else { continue }
      if items[step] != nil { return step }
      queue += children[step] ?? []
    }
    return visibleAncestor(of: id)
  }
}

/// A clip's frames and sound, as Draw Things records them: a step per frame and a `clip` row.
nonisolated struct ClipInfo: Hashable, Sendable {
  var clipId: Int64
  /// Each frame's image tensor, in order.
  var frames: [Int64]
  var framesPerSecond: Double
  /// The soundtrack's `audio_<id>` tensor.
  var audioId: Int64?
  /// The audio file the run took (H3 Ref2VA, LongCat), as an `audio_<id>` tensor.
  var inputAudioId: Int64?
  /// What every frame's preview id adds to its tensor id (the moodboard's part, `pushHistory`).
  var previewOffset: Int64 = 0

  /// Frame `index`'s thumbnail id.
  func previewId(_ index: Int) -> Int64 { frames[index] &+ previewOffset }

  /// Seconds.
  var duration: Double { framesPerSecond > 0 ? Double(frames.count) / framesPerSecond : 0 }
}

nonisolated enum ProjectError: LocalizedError {
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
nonisolated enum ImageTensor {
  /// The RGB channels of a decoded image. Some decoders (Qwen Image 2.1) return ARGB with alpha
  /// first; Draw Things keeps only the RGB part (`ImageConverter.imageAndMask`).
  static func rgb(_ tensor: Tensor<FloatType>) -> Tensor<FloatType> {
    let shape = tensor.shape
    guard shape.count == 4, shape[3] == 4 else { return tensor }
    return tensor[0..<shape[0], 0..<shape[1], 0..<shape[2], 1..<4].copied()
  }

  static func cgImage(from tensor: Tensor<FloatType>) -> CGImage? {
    let shape = tensor.shape
    guard shape.count == 4, shape[0] >= 1, shape[3] >= 3 else { return nil }
    let height = shape[1]
    let width = shape[2]
    let channels = shape[3]
    // ARGB tensors (see `rgb`) have the color after the alpha channel.
    let first = channels == 4 ? 1 : 0
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    tensor.withUnsafeBytes { raw in
      let values = raw.bindMemory(to: FloatType.self)
      for pixel in 0..<(width * height) {
        for c in 0..<3 {
          let v = (Float(values[pixel * channels + first + c]) + 1) * 127.5
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

  /// With `properties` (ImageIO's metadata dictionaries) written into the file.
  static func png(_ image: CGImage, properties: [CFString: Any] = [:]) -> Data? {
    encode(image, type: .png, properties: properties).map { Data($0) }
  }

  static func tiff(_ image: CGImage) -> Data? {
    encode(image, type: .tiff, properties: [:]).map { Data($0) }
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
