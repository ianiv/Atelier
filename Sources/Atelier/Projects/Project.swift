import _MediaGenerationKit
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

/// A canvas layer (`tensordata`); the bare name clashes with another module's `TensorData`.
private typealias Layer = ProjectFormat.TensorData

/// A step in a project's history, keyed like Draw Things: the branch and the step number.
struct StepID: Hashable, Codable, Sendable {
  var lineage: Int64
  var logicalTime: Int64
}

/// A project's overrides of the output folder settings; nil follows Settings.
struct ProjectOutput: Equatable, Sendable {
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
        clips: items ? Array(workspace.fetch(for: Clip.self).all()) : [], items: items)
    }
  }

  /// The input of an Edit step: its parent, when the parent's image is still the recorded input
  /// (`tensorId`). Nil once that step was deleted (the step now before it holds another image).
  func input(of id: StepID, tensorId: Int64) -> (id: StepID, image: CGImage)? {
    let tree = tree(items: false)
    guard let parent = tree.steps[id]?.parent, tree.steps[parent]?.tensorId == tensorId,
          let image = self.tensor(id: tensorId).flatMap(ImageTensor.cgImage(from:))
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
    tensor(named: "tensor_history_\(id)")
  }

  private func tensor(named name: String) -> Tensor<FloatType>? {
    lock.lock()
    defer { lock.unlock() }
    var tensor: Tensor<FloatType>?
    graph.openStore(url.path, flags: [.readOnly]) {
      tensor = $0.read(name, codec: [.fpzip, .zip]).map { Tensor<FloatType>(from: $0) }
    }
    return tensor
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
    tensor(id: item.tensorId).flatMap(ImageTensor.cgImage(from:))
  }

  /// The full-resolution image of a step, if it has one.
  func image(at id: StepID) -> CGImage? {
    imageTensorId(at: id).flatMap(image(tensorId:))
  }

  func image(tensorId: Int64) -> CGImage? {
    tensor(id: tensorId).flatMap(ImageTensor.cgImage(from:))
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
    lock.lock()
    defer { lock.unlock() }
    var audio: Tensor<Float>?
    graph.openStore(url.path, flags: [.readOnly]) {
      audio = $0.read("audio_\(id)", codec: [.fpzip, .zip]).map { Tensor<Float>(from: $0) }
    }
    return audio
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
  func append(
    tensor: Tensor<FloatType>, model: String, prompt: String, negativePrompt: String,
    seed: UInt32, settings: [String: JSONValue], createdAt: Date, duration: Double,
    reason: ProjectFormat.Reason = .generate, generated: Bool = true,
    moodboard: [(tensor: Tensor<FloatType>, weight: Float)] = [], inputTensorId: Int64? = nil,
    after parentTensorId: Int64? = nil
  ) async throws -> HistoryItem {
    try await append(
      frames: [tensor], clip: nil, model: model, prompt: prompt, negativePrompt: negativePrompt,
      seed: seed, settings: settings, createdAt: createdAt, duration: duration, reason: reason,
      generated: generated, moodboard: moodboard, inputTensorId: inputTensorId,
      after: parentTensorId)
  }

  /// A video run's clip, beyond its frames.
  struct ClipContent {
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
  func appendClip(
    frames: [Tensor<FloatType>], clip: ClipContent, model: String, prompt: String,
    negativePrompt: String, seed: UInt32, settings: [String: JSONValue], createdAt: Date,
    duration: Double, moodboard: [(tensor: Tensor<FloatType>, weight: Float)] = [],
    inputTensorId: Int64? = nil, after parentTensorId: Int64? = nil
  ) async throws -> HistoryItem {
    try await append(
      frames: frames, clip: clip, model: model, prompt: prompt, negativePrompt: negativePrompt,
      seed: seed, settings: settings, createdAt: createdAt, duration: duration, reason: .generate,
      generated: true, moodboard: moodboard, inputTensorId: inputTensorId, after: parentTensorId)
  }

  private func append(
    frames tensors: [Tensor<FloatType>], clip: ClipContent?, model: String, prompt: String,
    negativePrompt: String, seed: UInt32, settings: [String: JSONValue], createdAt: Date,
    duration: Double, reason: ProjectFormat.Reason, generated: Bool,
    moodboard: [(tensor: Tensor<FloatType>, weight: Float)], inputTensorId: Int64?,
    after parentTensorId: Int64?
  ) async throws -> HistoryItem {
    // Each frame's thumbnails, one frame decoded at a time (a clip's frames together are large).
    var size: (width: Int32, height: Int32)?
    var thumbnails: [(full: [UInt8]?, half: [UInt8]?)] = []
    for tensor in tensors {
      guard let image = ImageTensor.cgImage(from: tensor) else { throw ProjectError.badImage }
      if size == nil { size = (Int32(image.width), Int32(image.height)) }
      thumbnails.append(
        (
          ImageTensor.jpeg(image, quality: 0.75),
          ImageTensor.downsampled(image).flatMap { ImageTensor.jpeg($0, quality: 0.5) }
        ))
    }
    guard let size else { throw ProjectError.badImage }
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
    let previewIds = tensorIds.map { $0 &+ moodboardPreview }
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
            inputAudioId: inputAudioId)
          let node = ProjectMapping.node(for: step, settings: settings)
          if index == 0 { appended = node }
          transaction.try(submit: TensorHistoryNodeChangeRequest.upsertRequest(node))
          transaction.try(
            submit: ProjectFormat.TensorDataChangeRequest.upsertRequest(
              Layer(
                lineage: id.lineage, logicalTime: id.logicalTime, index: 0, x: 0, y: 0,
                width: width, height: height, scaleFactorBy120: 120, tensorId: tensorIds[index])))
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
      clip: node.clipId >= 0
        ? ClipInfo(
          clipId: node.clipId, frames: tensorIds, framesPerSecond: clip?.framesPerSecond ?? 0,
          audioId: audioId, inputAudioId: inputAudioId, previewOffset: moodboardPreview) : nil)
  }

  /// Deletes a step, its layers, thumbnails and tensors. Returns its parent's image tensor.
  @discardableResult
  func delete(_ id: StepID) async throws -> Int64? {
    try await delete { _ in id }
  }

  /// Deletes every frame of a clip, last first, as Draw Things deletes them one by one; the last
  /// one takes the clip row and its soundtrack. Returns the first frame's parent's image tensor.
  @discardableResult
  func deleteClip(frames: [Int64]) async throws -> Int64? {
    var parent: Int64?
    for tensorId in frames.reversed() {
      parent = try await delete(tensorId: tensorId)
    }
    return parent
  }

  /// Deletes the step whose image is `tensorId`. Returns its parent's image tensor.
  @discardableResult
  func delete(tensorId: Int64) async throws -> Int64? {
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
  func forgetParentLinks() async {
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
    lock.lock()
    defer { lock.unlock() }
    // Default flags would truncate the file on close; Draw Things opens it with none.
    let result = graph.openStore(url.path, flags: []) { store in
      for (name, tensor) in tensors { store.write(name, tensor: tensor, codec: [.fpzip, .zip]) }
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

/// A project's steps and how they connect. A step's parent is the step whose image it recorded
/// as `parent_tensor_id`, when there is one; otherwise Draw Things' rule: the step one number
/// earlier with the greatest lineage not above its own.
///
/// A step's image is its top canvas layer. Draw Things places a generation over part of a larger
/// canvas as a new layer, so the layers below repeat the earlier image on every step that builds
/// on it.
struct ProjectTree: @unchecked Sendable {
  struct Step {
    var id: StepID
    /// The image layer's tensor.
    var tensorId: Int64?
    var parent: StepID?
    var generated: Bool
    var wallClock: Int64
    /// Whether `profile_data` records the parent (`parent_tensor_id`).
    var recordsParent: Bool
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
  private var greatestLineage: [Int64: Int64] = [:]

  init() {}

  /// `items` false leaves out History's items (their settings take longest to read).
  init(
    nodes: [TensorHistoryNode], layers: [ProjectFormat.TensorData], clips: [Clip] = [],
    items withItems: Bool = true
  ) {
    // The image layer: the top layer with a tensor, else the node's own field.
    var layerTensors: [StepID: (index: Int64, tensorId: Int64)] = [:]
    var allLayerTensors: [StepID: Set<Int64>] = [:]
    for layer in layers where layer.tensorId > 0 {
      let id = StepID(lineage: layer.lineage, logicalTime: layer.logicalTime)
      allLayerTensors[id, default: []].insert(layer.tensorId)
      if layerTensors[id].map({ layer.index > $0.index }) ?? true {
        layerTensors[id] = (layer.index, layer.tensorId)
      }
    }
    var byTime: [Int64: [StepID]] = [:]
    var profiles: [StepID: ProjectMapping.Profile] = [:]
    var clipFrames: [Int64: [(index: Int32, tensorId: Int64)]] = [:]
    var clipItems: [Int64: (id: StepID, inputAudioId: Int64?)] = [:]
    for node in nodes {
      let id = StepID(lineage: node.lineage, logicalTime: node.logicalTime)
      let tensorId =
        node.dataStored > 0 ? layerTensors[id]?.tensorId : (node.tensorId > 0 ? node.tensorId : nil)
      let profile = ProjectMapping.Profile(node.profileData)
      profiles[id] = profile
      steps[id] = Step(
        id: id, tensorId: tensorId, parent: nil, generated: node.generated,
        wallClock: node.wallClock, recordsParent: profile?.parentTensorId != nil)
      if let tensorId { byTensor[tensorId, default: []].append(id) }
      byTime[id.logicalTime, default: []].append(id)
      greatestLineage[id.logicalTime] = max(greatestLineage[id.logicalTime] ?? .min, id.lineage)
      if newest.map({ (id.lineage, id.logicalTime) > ($0.lineage, $0.logicalTime) }) ?? true {
        newest = id
      }
      if node.clipId >= 0, let tensorId {
        clipFrames[node.clipId, default: []].append((node.indexInAClip, tensorId))
      }
      // A clip is listed once, by its first frame.
      if withItems, node.generated, let tensorId, node.clipId < 0 || node.indexInAClip == 0 {
        items[id] = HistoryItem(
          id: id, tensorId: tensorId, previewId: node.previewId, sidecar: Project.sidecar(for: node),
          inputTensorId: profile?.inputTensorId)
        if node.clipId >= 0 {
          clipItems[node.clipId] = (id, profile?.inputAudioId)
        }
      }
    }
    let clipRows = Dictionary(clips.map { ($0.clipId, $0) }, uniquingKeysWith: { a, _ in a })
    for (clipId, item) in clipItems {
      let frames = (clipFrames[clipId] ?? []).sorted { $0.index < $1.index }.map(\.tensorId)
      let row = clipRows[clipId]
      let first = items[item.id]
      items[item.id]?.clip = ClipInfo(
        clipId: clipId, frames: frames, framesPerSecond: row?.framesPerSecond ?? 0,
        audioId: row.flatMap { $0.audioId > 0 ? $0.audioId : nil }, inputAudioId: item.inputAudioId,
        previewOffset: (first?.previewId ?? 0) &- (first?.tensorId ?? 0))
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

  /// The generated step standing for `id` in the views: itself, else the nearest generated step
  /// below it (newest first), else the nearest above it.
  func representative(of id: StepID) -> StepID? {
    if items[id] != nil { return id }
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
struct ClipInfo: Hashable, Sendable {
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
