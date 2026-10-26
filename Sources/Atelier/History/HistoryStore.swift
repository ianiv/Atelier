import CoreGraphics
import CoreTransferable
import Diffusion
import Foundation
import ImageIO
import ModelZoo
import NNC
import Observation
import UniformTypeIdentifiers
import _MediaGenerationKit

/// One generated image: a step in the current project.
struct HistoryItem: Identifiable, Hashable {
  var id: StepID
  var tensorId: Int64
  var previewId: Int64
  var sidecar: HistoryStore.Sidecar
  /// Set for a step generated from the canvas (Edit): the image tensor of its input, the step
  /// before it.
  var inputTensorId: Int64?
  /// Set for a video: the item is its first frame and stands for the whole clip.
  var clip: ClipInfo?

  var isVideo: Bool { clip != nil }

  // Step ids change when a fork or a delete renumbers steps; the image tensor doesn't.
  static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool { lhs.tensorId == rhs.tensorId }
  func hash(into hasher: inout Hasher) { hasher.combine(tensorId) }
}

/// History lives in projects: Draw Things-format `.sqlite3` files under
/// ~/Pictures/Atelier/Projects/. One is current; Create appends to it and History lists every
/// branch (newest first).
///
/// The project has a current step, as Draw Things does: the image last clicked or generated. The
/// next run follows it, which forks a branch when it isn't the newest step. Fork and delete
/// renumber steps, so it and everything else here are held by image tensor, which doesn't change.
@MainActor
@Observable
final class HistoryStore {
  /// A history item's settings summary. Built from the project's step; also the format of the
  /// JSON sidecars Atelier wrote before projects (imported once, see `importLegacyHistory`) and
  /// of the iTXt chunk in exported PNGs.
  struct Sidecar: Codable {
    var app = "Atelier"
    var createdAt: Date
    var durationSeconds: Double
    var prompt: String
    var negativePrompt: String
    var model: String
    var seed: UInt32
    var width: Int
    var height: Int
    var steps: Int
    var guidanceScale: Float
    var shift: Float
    var sampler: String
    var resolutionDependentShift: Bool
    var hiresFix: Bool
    /// Every public field of the pipeline configuration actually used.
    var configuration: [String: JSONValue]
  }

  private(set) var project: Project
  /// Project names (file names without `.sqlite3`), sorted.
  private(set) var projectNames: [String] = []
  /// Every generated step on every branch, newest first.
  private(set) var items: [HistoryItem] = []
  /// The current project's steps and how they connect.
  private(set) var tree = ProjectTree()
  /// The current step's image; nil until the project loads (then the recorded or newest step).
  private(set) var currentTensorId: Int64?
  /// Each generated step's nearest generated ancestor, and the reverse (newest first). Steps
  /// that aren't generated (Imported and Other inputs) aren't listed, so they collapse.
  private var visibleParents: [StepID: StepID] = [:]
  private var visibleChildren: [StepID: [StepID]] = [:]
  private var byTensor: [Int64: HistoryItem] = [:]
  private(set) var isLoaded = false
  /// The current project's output folder overrides.
  private(set) var output = ProjectOutput()
  /// Progress of the one-time import of the old PNG history, while it runs.
  private(set) var importProgress: (done: Int, total: Int)?

  static let defaultProjectName = "Atelier"
  private static let currentProjectKey = "currentProject"

  init() {
    // Scripted runs (Automation) pass `--project NAME` to keep their images out of the user's.
    let args = CommandLine.arguments
    let scripted = args.firstIndex(of: "--project").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let saved = SessionState.isEnabled
      ? UserDefaults.standard.string(forKey: Self.currentProjectKey) : nil
    project = Project(url: Self.url(for: scripted ?? saved ?? Self.defaultProjectName))
    Task {
      await reload()
      #if DEBUG
        await addSampleImagesIfAsked()
      #endif
      await importLegacyHistory()
    }
  }

  nonisolated static var projectsDirectory: URL {
    AppSettings.historyDirectory.appendingPathComponent("Projects", isDirectory: true)
  }

  nonisolated static func url(for name: String) -> URL {
    try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    return projectsDirectory.appendingPathComponent(name).appendingPathExtension("sqlite3")
  }

  func reload() async {
    let project = project
    let (tree, stored, output) = await Task.detached { () -> (ProjectTree, StepID?, ProjectOutput) in
      let tree = project.tree()
      return (tree, project.storedCurrentStep(in: tree), project.output)
    }.value
    guard project === self.project else { return }
    self.output = output
    self.tree = tree
    items = tree.itemsNewestFirst
    byTensor = Dictionary(items.map { ($0.tensorId, $0) }, uniquingKeysWith: { a, _ in a })
    visibleParents = [:]
    visibleChildren = [:]
    for item in items {
      guard let parent = tree.steps[item.id]?.parent.flatMap(tree.visibleAncestor(of:)) else { continue }
      visibleParents[item.id] = parent
      visibleChildren[parent, default: []].append(item.id)
    }
    for (id, children) in visibleChildren { visibleChildren[id] = children.sorted(by: tree.isNewer) }
    if currentTensorId.flatMap(tree.step(tensorId:)) == nil {
      currentTensorId = (stored ?? tree.newest).flatMap { tree.steps[$0]?.tensorId }
    }
    projectNames = Self.scanProjectNames()
    if !projectNames.contains(project.name) { projectNames = (projectNames + [project.name]).sorted() }
    isLoaded = true
  }

  // MARK: - Projects

  /// Makes `name` the current project, creating it if needed.
  func open(_ name: String) async {
    guard name != project.name else { return }
    project = Project(url: Self.url(for: name))
    if SessionState.isEnabled { UserDefaults.standard.set(name, forKey: Self.currentProjectKey) }
    isLoaded = false
    items = []
    tree = ProjectTree()
    currentTensorId = nil
    output = ProjectOutput()
    await reload()
  }

  /// Sets the current project's output folder overrides.
  func setOutput(_ output: ProjectOutput) {
    self.output = output
    project.output = output
  }

  /// A name not taken yet: `base`, else `base 2`, `base 3`, …
  func availableName(_ base: String = "Untitled") -> String {
    let names = Set(Self.scanProjectNames() + [project.name])
    var name = base
    var n = 2
    while names.contains(name) {
      name = "\(base) \(n)"
      n += 1
    }
    return name
  }

  static func isValidName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.hasPrefix(".")
  }

  /// Renames the current project's file (and its -wal/-shm).
  func renameCurrent(to name: String) async throws {
    let name = name.trimmingCharacters(in: .whitespaces)
    guard Self.isValidName(name), name != project.name else { return }
    let target = Self.url(for: name)
    guard !FileManager.default.fileExists(atPath: target.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let old = project.url
    // Close the workspace first so nothing writes while the files move.
    await project.close()
    try FileManager.default.moveItem(at: old, to: target)
    for suffix in ["-wal", "-shm"] {
      let side = URL(fileURLWithPath: old.path + suffix)
      if FileManager.default.fileExists(atPath: side.path) {
        try? FileManager.default.moveItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
      }
    }
    project = Project(url: target)
    if SessionState.isEnabled { UserDefaults.standard.set(name, forKey: Self.currentProjectKey) }
    await reload()
  }

  private nonisolated static func scanProjectNames() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: projectsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return files.filter { $0.pathExtension == "sqlite3" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  // MARK: - Items

  @discardableResult
  func save(
    _ output: GenerationEngine.Output,
    request: GenerationEngine.Request,
    startedAt: Date,
    finishedAt: Date,
    makeCurrent: () -> Bool = { true }
  ) async throws -> HistoryItem {
    var settings = request.configuration
    settings.seed = request.seed
    if output.isVideo { settings.numFrames = output.frames.count }
    let project = project
    let dump = JSONValue.fields(of: settings)
    // The run follows the step that was current when it started, or with the canvas, the
    // canvas's step: an Edit run's input is its result's parent. When the canvas isn't exactly
    // a step's image (an image from outside, moved, zoomed or another size), it goes in first as
    // a step of its own after the current one: Imported for an image from outside, as Draw Things
    // does.
    var parentTensorId = request.parentTensorId
    var inputTensorId: Int64?
    if let canvas = request.canvas {
      if let tensorId = request.canvasTensorId, await step(tensorId: tensorId, in: project) != nil {
        inputTensorId = tensorId
      } else if let tensor = ImageTensor.tensor(from: canvas) {
        let input = try await project.append(
          tensor: tensor, model: request.model, prompt: request.prompt,
          negativePrompt: request.negativePrompt, seed: request.seed, settings: dump,
          createdAt: startedAt, duration: 0,
          reason: request.canvasIsImported ? .imported : .other, generated: false,
          after: parentTensorId)
        inputTensorId = input.tensorId
      }
      parentTensorId = inputTensorId ?? parentTensorId
    }
    let moodboard = request.moodboard.compactMap { entry in
      ImageTensor.tensor(from: entry.image).map { (tensor: $0, weight: entry.weight) }
    }
    let item: HistoryItem
    if let framesPerSecond = output.framesPerSecond {
      item = try await project.appendClip(
        frames: output.frames.map(ImageTensor.rgb),
        clip: Project.ClipContent(
          framesPerSecond: framesPerSecond, audio: output.audio, audioInput: output.audioInput),
        model: request.model, prompt: request.prompt, negativePrompt: request.negativePrompt,
        seed: request.seed, settings: dump, createdAt: finishedAt,
        duration: finishedAt.timeIntervalSince(startedAt), moodboard: moodboard,
        inputTensorId: inputTensorId, after: parentTensorId)
    } else {
      item = try await project.append(
        tensor: ImageTensor.rgb(output.frames[0]), model: request.model, prompt: request.prompt,
        negativePrompt: request.negativePrompt, seed: request.seed,
        settings: dump, createdAt: finishedAt,
        duration: finishedAt.timeIntervalSince(startedAt), moodboard: moodboard,
        inputTensorId: inputTensorId, after: parentTensorId)
    }
    if project === self.project {
      // A fork may have renumbered other steps.
      let keepCurrent = !makeCurrent()
      if !keepCurrent { currentTensorId = Self.tip(of: item) }
      await reload()
      // The new step is likely the newest now, which the project records as no position.
      if keepCurrent { recordCurrent() }
    }
    return self.item(tensorId: item.tensorId) ?? item
  }

  /// The step a run after `item` follows: its own, or a clip's last frame.
  static func tip(of item: HistoryItem) -> Int64 {
    item.clip?.frames.last ?? item.tensorId
  }

  /// The step holding the image, in `project` (read fresh when it isn't the one loaded).
  private func step(tensorId: Int64, in project: Project) async -> StepID? {
    if project === self.project { return tree.step(tensorId: tensorId) }
    return await Task.detached { project.tree(items: false).step(tensorId: tensorId) }.value
  }

  /// A step's moodboard images and weights (empty when it had none).
  func moodboard(at id: StepID, in projectName: String) async -> [(image: CGImage, weight: Float)] {
    guard projectName == project.name else { return [] }
    let project = project
    return await Task.detached { project.moodboard(at: id) }.value
  }

  /// Removes the steps from the project. Later steps may be renumbered, so each is found by its
  /// image. A deleted current step hands over to its parent, else the newest step.
  func delete(_ items: [HistoryItem]) async throws {
    let project = project
    do {
      for item in items {
        if let clip = item.clip {
          let parent = try await project.deleteClip(frames: clip.frames)
          if let current = currentTensorId, clip.frames.contains(current) { currentTensorId = parent }
        } else {
          let parent = try await project.delete(tensorId: item.tensorId)
          if item.tensorId == currentTensorId { currentTensorId = parent }
        }
      }
    } catch {
      project.setCurrentStep(nil)
      await reload()
      recordCurrent()
      throw error
    }
    // The step numbers it was recorded under may have moved: forget them while reloading.
    project.setCurrentStep(nil)
    await reload()
    recordCurrent()
  }

  func item(_ id: StepID) -> HistoryItem? {
    tree.items[id]
  }

  func item(tensorId: Int64) -> HistoryItem? {
    byTensor[tensorId]
  }

  // MARK: - Branches

  /// The current step (possibly one that isn't generated, such as an Edit run's input).
  var currentStep: StepID? {
    currentTensorId.flatMap(tree.step(tensorId:))
  }

  /// The generated step standing for the current one in the views.
  var currentItem: HistoryItem? {
    currentStep.flatMap(tree.representative(of:)).flatMap { tree.items[$0] }
  }

  /// Makes the step holding `tensorId` current, so the next run follows it. Recorded in the
  /// project as Draw Things records its position (`image_seek_to`).
  ///
  /// A clip is current at its last frame, so the next run follows the whole clip; `exact` makes
  /// the step holding `tensorId` current even when it's a clip's first frame (a run from it then
  /// branches there).
  func setCurrent(tensorId: Int64, exact: Bool = false) {
    let tensorId = exact ? tensorId : byTensor[tensorId].map(Self.tip(of:)) ?? tensorId
    guard tree.step(tensorId: tensorId) != nil, tensorId != currentTensorId else { return }
    currentTensorId = tensorId
    recordCurrent()
  }

  private func recordCurrent() {
    let step = currentStep
    project.setCurrentStep(step == tree.newest ? nil : step)
  }

  /// The generated step a generated step follows, skipping inputs that aren't listed.
  func parent(of item: HistoryItem) -> HistoryItem? {
    visibleParents[item.id].flatMap { tree.items[$0] }
  }

  /// The generated steps that follow one, newest first.
  func children(of item: HistoryItem) -> [HistoryItem] {
    (visibleChildren[item.id] ?? []).compactMap { tree.items[$0] }
  }

  /// The current step's line, newest first: the newest steps beyond it (taking the newest child
  /// wherever it branches), it, and its ancestors.
  var currentLineage: [HistoryItem] {
    guard let current = currentItem else { return [] }
    var below: [HistoryItem] = []
    var next = children(of: current).first
    while let item = next {
      below.append(item)
      next = children(of: item).first
    }
    var line = Array(below.reversed())
    var up: HistoryItem? = current
    while let item = up {
      line.append(item)
      up = parent(of: item)
    }
    return line
  }

  /// The step's JPEG preview (`half` for grids), decoded off the main actor.
  func thumbnail(for item: HistoryItem, half: Bool) async -> CGImage? {
    let key = "\(project.url.path)#\(item.previewId)#\(half)" as NSString
    if let cached = Self.thumbnails.object(forKey: key) { return cached }
    let project = project
    let image = await Task.detached { project.thumbnail(previewId: item.previewId, half: half) }.value
    if let image { Self.thumbnails.setObject(image, forKey: key) }
    return image
  }

  /// The full-resolution image, decoded from the project's tensor.
  func image(for item: HistoryItem) async -> CGImage? {
    let project = project
    return await Task.detached { project.image(for: item) }.value
  }

  /// An Edit step's input step and image, while that step still exists in `projectName`.
  func input(of item: HistoryItem, in projectName: String) async -> (id: StepID, image: CGImage)? {
    guard projectName == project.name, let tensorId = item.inputTensorId else { return nil }
    let project = project
    return await Task.detached { project.input(of: item.id, tensorId: tensorId) }.value
  }

  /// The full-resolution image of a step in `projectName` (when that's the current project).
  func image(at id: StepID, in projectName: String) async -> CGImage? {
    guard projectName == project.name else { return nil }
    let project = project
    return await Task.detached { project.image(at: id) }.value
  }

  /// A step's image tensor in `projectName` (when that's the current project).
  func tensorId(at id: StepID, in projectName: String) async -> Int64? {
    guard projectName == project.name else { return nil }
    let project = project
    return await Task.detached { project.imageTensorId(at: id) }.value
  }

  /// The full-resolution image `tensorId` in `projectName` (when that's the current project).
  func image(tensorId: Int64, in projectName: String) async -> CGImage? {
    guard projectName == project.name else { return nil }
    let project = project
    return await Task.detached { project.image(tensorId: tensorId) }.value
  }

  /// Writes a newly generated image or clip to the output folder when Settings or the project
  /// turns that on, named like an export. Returns why it couldn't be written, if it couldn't.
  func writeToOutputFolder(_ item: HistoryItem, image: CGImage?) async -> String? {
    guard output.effectiveSaves else { return nil }
    let access = FolderBookmarks.open(output.effectiveFolder)
    let folder = access.url
    let name = fileName(for: item)
    do {
      defer { withExtendedLifetime(access) {} }
      let file: (data: Data?, video: URL?, extension: String)
      if item.isVideo {
        file = (nil, try await videoFile(for: item), "mp4")
      } else {
        guard let image else { throw ProjectError.badImage }
        file = (try Self.pngData(image, sidecar: item.sidecar), nil, "png")
      }
      try await Task.detached {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Steps can be renumbered when the history branches, so never overwrite a file.
        var url = folder.appendingPathComponent(name).appendingPathExtension(file.extension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
          url = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(file.extension)
          n += 1
        }
        if let video = file.video {
          try FileManager.default.copyItem(at: video, to: url)
        } else {
          try file.data?.write(to: url, options: .withoutOverwriting)
        }
      }.value
      return nil
    } catch {
      return "Saved to the project, but not to the output folder: \(error.localizedDescription)"
    }
  }

  // MARK: - Clips

  /// A clip's frames, decoded from the project's tensors.
  func frames(of item: HistoryItem) async -> [CGImage] {
    guard let clip = item.clip else { return [] }
    let project = project
    return await Task.detached {
      clip.frames.compactMap { project.image(tensorId: $0) }
    }.value
  }

  /// One frame of a clip, full size.
  func frame(_ index: Int, of item: HistoryItem) async -> CGImage? {
    guard let frames = item.clip?.frames, frames.indices.contains(index) else { return nil }
    return await image(tensorId: frames[index], in: project.name)
  }

  /// A clip's soundtrack and its sample rate (the model's).
  func audio(of item: HistoryItem) async -> (samples: Tensor<Float>, sampleRate: Int)? {
    guard let audioId = item.clip?.audioId else { return nil }
    let project = project
    let samples = await Task.detached { project.audio(id: audioId) }.value
    return samples.map { ($0, ModelZoo.audioSampleRateForModel(item.sidecar.model)) }
  }

  /// The audio file a video run took, as it was resampled for the model.
  func audioInput(of item: HistoryItem) async -> Tensor<Float>? {
    guard let audioId = item.clip?.inputAudioId else { return nil }
    let project = project
    return await Task.detached { project.audio(id: audioId) }.value
  }

  /// The clip as an MP4 with its soundtrack and settings, written once into the caches folder
  /// and reused by the player, exports, drags and the output folder.
  func videoFile(for item: HistoryItem) async throws -> URL {
    guard let clip = item.clip else { throw ClipVideoError.noFrames }
    let codec = VideoCodec.current
    let url = Self.clipCache.appendingPathComponent(
      "\(project.name)-\(clip.clipId)-\(item.tensorId)-\(codec.rawValue).mp4")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    if let pending = videoFiles[url] { return try await pending.value }
    let project = project
    let audio = await audio(of: item)
    let metadata = videoMetadata(item)
    let task = Task.detached {
      try FileManager.default.createDirectory(at: Self.clipCache, withIntermediateDirectories: true)
      // Written beside its final name, so a half-written file is never taken as done.
      let partial = url.deletingPathExtension().appendingPathExtension("partial.mp4")
      try await ClipVideo.write(
        to: partial, count: clip.frames.count,
        frame: { project.image(tensorId: clip.frames[$0]) },
        framesPerSecond: clip.framesPerSecond, audio: audio?.samples,
        audioSampleRate: audio?.sampleRate ?? 0, codec: codec, metadata: metadata)
      try? FileManager.default.removeItem(at: url)
      try FileManager.default.moveItem(at: partial, to: url)
      return url
    }
    videoFiles[url] = task
    defer { videoFiles[url] = nil }
    return try await task.value
  }

  /// Videos being written, so the player and an export asking at once share one.
  private var videoFiles: [URL: Task<URL, Error>] = [:]

  private nonisolated static var clipCache: URL {
    URL.cachesDirectory.appending(path: "Atelier/Clips", directoryHint: .isDirectory)
  }

  /// What an exported video says about itself: Draw Things' summary as its description, the
  /// sidecar as its comment (unless Settings turns embedding off).
  private func videoMetadata(_ item: HistoryItem) -> ClipVideo.Metadata? {
    guard AppSettings.embedsSettings else { return nil }
    let properties = ImageMetadata.properties(for: item.sidecar)
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let description = tiff?[kCGImagePropertyTIFFImageDescription] as? String ?? item.sidecar.prompt
    let json = (try? Self.encoder.encode(item.sidecar)).map { String(decoding: $0, as: UTF8.self) }
    return ClipVideo.Metadata(description: description, settings: json)
  }

  /// Writes the clip as an MP4 at `url`.
  func exportVideo(_ item: HistoryItem, to url: URL) async throws {
    let file = try await videoFile(for: item)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.copyItem(at: file, to: url)
  }

  /// Writes the image as a PNG carrying its settings (see `pngData`).
  func exportPNG(_ item: HistoryItem, to url: URL) async throws {
    try await pngData(item).write(to: url)
  }

  /// The image as PNG carrying its settings, unless Settings turns that off: Draw Things'
  /// metadata (`ImageMetadata`) and Atelier's sidecar in an `Atelier` iTXt chunk.
  func pngData(_ item: HistoryItem) async throws -> Data {
    guard let image = await image(for: item) else { throw ProjectError.badImage }
    return try Self.pngData(image, sidecar: item.sidecar)
  }

  static func pngData(_ image: CGImage, sidecar: Sidecar) throws -> Data {
    guard AppSettings.embedsSettings else {
      guard let png = ImageTensor.png(image) else { throw ProjectError.badImage }
      return png
    }
    guard let png = ImageTensor.png(image, properties: ImageMetadata.properties(for: sidecar))
    else { throw ProjectError.badImage }
    let json = try encoder.encode(sidecar)
    let tagged = PNGText.inserting(
      keyword: "Atelier", text: String(decoding: json, as: UTF8.self), into: png)
    return tagged ?? png
  }

  /// "Project 12-1234567", the name exports and drags use.
  func fileName(for item: HistoryItem) -> String {
    "\(project.name) \(item.id.logicalTime)-\(item.sidecar.seed)"
  }

  /// The image (or clip, as a video) as a file to drag out, named like an export.
  func dragExport(_ item: HistoryItem) -> PNGExport {
    var export = PNGExport(id: item.tensorId, name: fileName(for: item)) { [self] in
      try await pngData(item)
    }
    if item.isVideo {
      export.video = { [self] in try await videoFile(for: item) }
    }
    return export
  }

  /// Puts the full-resolution image on the clipboard.
  func copyImage(_ item: HistoryItem) async {
    if let image = await image(for: item) { Self.copy(image) }
  }

  /// Puts several full-resolution images on the clipboard, one pasteboard item each.
  func copyImages(_ items: [HistoryItem]) async {
    guard items.count > 1 else {
      if let item = items.first { await copyImage(item) }
      return
    }
    var images: [(png: Data?, tiff: Data?)] = []
    for item in items {
      guard let image = await image(for: item) else { continue }
      images.append((ImageTensor.png(image), ImageTensor.tiff(image)))
    }
    Clipboard.copyImages(images)
  }

  /// Puts an image on the clipboard as PNG and TIFF, which other apps paste most reliably.
  static func copy(_ image: CGImage) {
    Clipboard.copyImage(png: ImageTensor.png(image), tiff: ImageTensor.tiff(image))
  }

  private static let thumbnails = NSCache<NSString, CGImage>()

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  // MARK: - Old PNG history

  private static let legacyImportedKey = "legacyHistoryImported"

  /// Copies the PNG + JSON history from before projects (~/Pictures/Atelier/<date>/) into the
  /// default project, oldest first, once. The old files are left where they are.
  func importLegacyHistory() async {
    guard SessionState.isEnabled, !UserDefaults.standard.bool(forKey: Self.legacyImportedKey)
    else { return }
    let legacy = await Task.detached { Self.scanLegacy(AppSettings.historyDirectory) }.value
    guard !legacy.isEmpty else {
      UserDefaults.standard.set(true, forKey: Self.legacyImportedKey)
      return
    }
    let target = project.name == Self.defaultProjectName
      ? project : Project(url: Self.url(for: Self.defaultProjectName))
    importProgress = (0, legacy.count)
    for (index, entry) in legacy.reversed().enumerated() {
      let tensor = await Task.detached { () -> Tensor<FloatType>? in
        guard let source = CGImageSourceCreateWithURL(entry.png as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return ImageTensor.tensor(from: image)
      }.value
      if let tensor {
        let sidecar = entry.sidecar
        _ = try? await target.append(
          tensor: tensor, model: sidecar.model, prompt: sidecar.prompt,
          negativePrompt: sidecar.negativePrompt, seed: sidecar.seed,
          settings: sidecar.configuration, createdAt: sidecar.createdAt,
          duration: sidecar.durationSeconds)
      }
      importProgress = (index + 1, legacy.count)
    }
    importProgress = nil
    UserDefaults.standard.set(true, forKey: Self.legacyImportedKey)
    if target === project { await reload() }
  }

  private nonisolated static func scanLegacy(_ root: URL) -> [(png: URL, sidecar: Sidecar)] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let fileManager = FileManager.default
    let days = (try? fileManager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
    var items: [(png: URL, sidecar: Sidecar)] = []
    for day in days where day.lastPathComponent != "Projects" {
      let files = (try? fileManager.contentsOfDirectory(
        at: day, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
      for json in files where json.pathExtension == "json" {
        let png = json.deletingPathExtension().appendingPathExtension("png")
        guard fileManager.fileExists(atPath: png.path),
          let data = try? Data(contentsOf: json),
          let sidecar = try? decoder.decode(Sidecar.self, from: data)
        else { continue }
        items.append((png, sidecar))
      }
    }
    return items.sorted { $0.sidecar.createdAt > $1.sidecar.createdAt }
  }
}

/// Inserts and reads PNG iTXt chunks.
enum PNGText {
  /// Inserts an iTXt chunk right after IHDR.
  static func inserting(keyword: String, text: String, into png: Data) -> Data? {
    let bytes = [UInt8](png)
    // 8-byte signature, then IHDR: length(4) type(4) data(13) crc(4).
    guard bytes.count > 33, bytes[12..<16].elementsEqual("IHDR".utf8) else { return nil }
    var body = [UInt8]("iTXt".utf8)
    body += Array(keyword.utf8) + [0]
    body += [0, 0]  // uncompressed, compression method 0
    body += [0, 0]  // empty language tag and translated keyword
    body += Array(text.utf8)
    var chunk = withUnsafeBytes(of: UInt32(body.count - 4).bigEndian, Array.init)
    chunk += body
    chunk += withUnsafeBytes(of: crc32(body).bigEndian, Array.init)
    return Data(bytes[..<33] + chunk + bytes[33...])
  }

  /// The text of the first uncompressed iTXt chunk named `keyword`.
  static func text(keyword: String, in png: Data) -> String? {
    let bytes = [UInt8](png)
    guard bytes.count > 8, bytes[1..<4].elementsEqual("PNG".utf8) else { return nil }
    // keyword, NUL, uncompressed, compression method 0
    let prefix = Array(keyword.utf8) + [0, 0, 0]
    var offset = 8
    while offset + 12 <= bytes.count {
      let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
      let type = bytes[offset + 4..<offset + 8]
      let start = offset + 8
      guard start + length + 4 <= bytes.count, !type.elementsEqual("IEND".utf8) else { return nil }
      let body = bytes[start..<start + length]
      if type.elementsEqual("iTXt".utf8), body.starts(with: prefix) {
        // Then the language tag and translated keyword, each NUL-terminated.
        let rest = body.dropFirst(prefix.count)
        guard let language = rest.firstIndex(of: 0),
          let translated = rest[(language + 1)...].firstIndex(of: 0)
        else { return nil }
        return String(decoding: rest[(translated + 1)...], as: UTF8.self)
      }
      offset = start + length + 4
    }
    return nil
  }

  private static let table: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
  }

  private static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
  }
}

/// Minimal JSON tree for dumping Configuration, which isn't Codable in MGK.
enum JSONValue: Codable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  static func fields(of value: Any) -> [String: JSONValue] {
    var fields: [String: JSONValue] = [:]
    for child in Mirror(reflecting: value).children {
      guard let label = child.label else { continue }
      fields[label] = JSONValue(child.value)
    }
    return fields
  }

  init(_ value: Any) {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
      if let wrapped = mirror.children.first?.value {
        self = JSONValue(wrapped)
      } else {
        self = .null
      }
      return
    }
    switch value {
    case let value as Bool: self = .bool(value)
    case let value as Int: self = .number(Double(value))
    case let value as Int32: self = .number(Double(value))
    case let value as UInt32: self = .number(Double(value))
    case let value as Float: self = JSONValue(value)
    case let value as Double: self = .number(value)
    case let value as String: self = .string(value)
    default:
      switch mirror.displayStyle {
      case .collection, .set:
        self = .array(mirror.children.map { JSONValue($0.value) })
      case .struct, .class:
        self = .object(JSONValue.fields(of: value))
      default:
        // Enums (sampler, seed mode, …) encode as their case name.
        self = .string(String(describing: value))
      }
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

/// A PNG to drag into Finder (as a file) or another app (as image data), encoded on drop; a
/// clip drags as its MP4.
struct PNGExport: Transferable, Identifiable {
  /// The image tensor.
  var id: Int64
  var name: String
  var data: @Sendable () async throws -> Data
  /// Set for a clip: its video file.
  var video: (@Sendable () async throws -> URL)? = nil

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .mpeg4Movie) { export in
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent(export.name).appendingPathExtension("mp4")
      guard let video = export.video else { throw ClipVideoError.noFrames }
      try FileManager.default.copyItem(at: try await video(), to: file)
      return SentTransferredFile(file)
    }
    .exportingCondition { $0.video != nil }
    .suggestedFileName { $0.name + ".mp4" }
    FileRepresentation(exportedContentType: .png) { export in
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent(export.name).appendingPathExtension("png")
      try await export.data().write(to: file)
      return SentTransferredFile(file)
    }
    .exportingCondition { $0.video == nil }
    .suggestedFileName { $0.name }
    DataRepresentation(exportedContentType: .png) { try await $0.data() }
      .exportingCondition { $0.video == nil }
      .suggestedFileName { $0.name }
  }
}
