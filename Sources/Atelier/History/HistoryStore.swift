@preconcurrency import _MediaGenerationKit
import CoreGraphics
import CoreTransferable
@preconcurrency import Diffusion
import Foundation
import ImageIO
@preconcurrency import ModelZoo
@preconcurrency import NNC
import Observation
import ProjectFormat
import Synchronization
import UniformTypeIdentifiers

/// One generated image: a step in the current project.
nonisolated struct HistoryItem: Identifiable, Hashable, Sendable {
  var id: StepID
  var tensorId: Int64
  var previewId: Int64
  var sidecar: HistoryStore.Sidecar
  /// Set for a step generated from the canvas (Edit): the image tensor of its input, the step
  /// before it.
  var inputTensorId: Int64?
  /// How many moodboard images the step went in with (Draw Things' `shuffle_data_stored`).
  var moodboardCount = 0
  /// How many of those had weight above 0: the ones the model took, which Match Colors to
  /// Original may match to.
  var weightedMoodboardCount = 0
  /// Set for a video: the item is its first frame and stands for the whole clip.
  var clip: ClipInfo?
  /// Set for an input entry: the canvas and moodboard as they were before a run (an image brought
  /// in, a moodboard change, Clear, or a mask at Generate), not a run of its own. A Moodboard,
  /// Clear or Mask entry is keyed by its own `entry_key` (`tensorId`), since it shows the canvas's
  /// image or none; an Imported one by its image.
  var entryReason: EntryReason?
  /// An entry's canvas image, nil for an empty canvas.
  var canvasTensorId: Int64?
  /// An entry's canvas mask, nil for none.
  var entryMask: CanvasMask?
  /// An entry's whole moodboard, weight-0 images too, in order.
  var entryMoodboard: [EntryMood] = []

  var isVideo: Bool { clip != nil }
  var isEntry: Bool { entryReason != nil }
  /// The tensor holding the item's image: its own, or an entry's canvas (nil when it's empty).
  var imageTensorId: Int64? { isEntry ? canvasTensorId : tensorId }
  /// Whether there's an image to show, copy or export.
  var hasImage: Bool { imageTensorId != nil }

  /// What an input entry records, as Draw Things' history reasons (`tensor_history.fbs` `Reason`).
  nonisolated enum EntryReason: String, Sendable, Hashable, CaseIterable {
    /// `draw`: the canvas image with its paint layer baked in (`CanvasPaint`), before a run.
    case imported, moodboard, cleared, mask, draw

    var reason: ProjectFormat.Reason {
      switch self {
      case .imported: .imported
      case .moodboard: .moodboard
      case .cleared: .clear
      case .mask: .mask
      case .draw: .draw
      }
    }

    init?(_ reason: ProjectFormat.Reason) {
      switch reason {
      case .imported: self = .imported
      case .moodboard: self = .moodboard
      case .clear: self = .cleared
      case .mask: self = .mask
      case .draw: self = .draw
      default: return nil
      }
    }

    /// The badge on its tile.
    var title: String {
      switch self {
      case .imported: "Imported"
      case .moodboard: "Moodboard"
      case .cleared: "Cleared"
      case .mask: "Mask"
      case .draw: "Draw"
      }
    }
  }

  /// One moodboard image of an entry: its `shuffle_<id>` tensor and weight.
  nonisolated struct EntryMood: Hashable, Sendable {
    var shuffleId: Int64
    var weight: Float
  }

  /// What VoiceOver says for the image or video: the start of its prompt.
  var accessibilityDescription: String {
    let prompt = sidecar.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if let entryReason { return "Input entry: \(entryReason.title)" }
    let kind = isVideo ? "Video" : "Image"
    if prompt.isEmpty { return kind }
    return "\(kind): \(prompt.count > 80 ? prompt.prefix(80) + "…" : prompt)"
  }

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
  nonisolated struct Sidecar: Codable, Sendable {
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
    /// How long each phase of the run took; nil for steps saved without them.
    var timings: GenerationTimings?
    /// For a region refined and merged back into its input: where the frame was, and the mask.
    var refine: RefineRecord?
    /// For a step made by Match Colors to Original: how, and from which original.
    var colorMatch: ColorMatch.Record?
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
  /// Star ratings (1 to 5) by image tensor; a clip's is under its first frame.
  private(set) var ratings: [Int64: Int] = [:]
  /// The images with a kept mask (`Project.storedMask`), true when it paints anything, false for
  /// one cleared over an older mask. Read once per opening and kept up to date here.
  private(set) var storedMasks: [Int64: Bool] = [:]
  /// The project `storedMasks` was read from.
  @ObservationIgnored private var storedMasksProject: ObjectIdentifier?
  /// For projects from before masks were kept per image: the mask of each image's newest Edit
  /// child that recorded one (`refine_mask`), by the image's tensor (`childMasks`).
  private var childMasks: [Int64: CanvasMask] = [:]
  /// Progress of the one-time import of the old PNG history, while it runs.
  private(set) var importProgress: (done: Int, total: Int)?
  /// Projects other than the current one that something still holds (a queued Match Colors to
  /// Original saving into its own project), by name, so `project(named:)` and `open` hand out the
  /// same one rather than open a second connection to the same file.
  @ObservationIgnored private var heldProjects: [String: WeakProject] = [:]
  /// Run before another project opens (`CreateModel` records a pending moodboard change).
  @ObservationIgnored var willSwitchProject: (() async -> Void)?

  private final class WeakProject {
    weak var project: Project?
    init(_ project: Project) { self.project = project }
  }

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
    let readsMasks = storedMasksProject != ObjectIdentifier(project)
    let (tree, stored, output, ratings, masks) = await project.read {
      project -> (ProjectTree, StepID?, ProjectOutput, [Int64: Int], [Int64: Bool]?) in
      let tree = project.tree()
      return (
        tree, project.storedCurrentStep(in: tree), project.output, project.ratings,
        readsMasks ? project.storedMaskImages() : nil)
    }
    guard project === self.project else { return }
    self.output = output
    self.ratings = ratings
    if let masks {
      storedMasks = masks
      storedMasksProject = ObjectIdentifier(project)
      moodboardShuffles = project.moodboardShuffles
    }
    self.tree = tree
    items = tree.itemsNewestFirst
    byTensor = Dictionary(items.map { ($0.tensorId, $0) }, uniquingKeysWith: { a, _ in a })
    childMasks = Self.childMasks(items)
    visibleParents = [:]
    visibleChildren = [:]
    for item in items {
      guard let parent = tree.steps[item.id]?.parent.flatMap(tree.visibleAncestor(of:)) else { continue }
      visibleParents[item.id] = parent
      visibleChildren[parent, default: []].append(item.id)
    }
    for (id, children) in visibleChildren { visibleChildren[id] = children.sorted(by: tree.isNewer) }
    if currentTensorId.flatMap(tree.step(tensorId:)) == nil {
      currentTensorId = Self.openingCurrent(in: tree, stored: stored)
    }
    projectNames = Self.scanProjectNames()
    if !projectNames.contains(project.name) { projectNames = (projectNames + [project.name]).sorted() }
    isLoaded = true
  }

  // MARK: - Projects

  /// Makes `name` the current project, creating it if needed.
  func open(_ name: String) async {
    guard name != project.name else { return }
    // A moodboard change still to be recorded goes into the project it was made in.
    await willSwitchProject?()
    guard name != project.name else { return }
    // One still held (a job saving into it) is the one opened; the one left stays findable while
    // it's held.
    let previous = project
    project = heldProjects.removeValue(forKey: name)?.project ?? Project(url: Self.url(for: name))
    heldProjects[previous.name] = WeakProject(previous)
    heldProjects = heldProjects.filter { $0.value.project != nil }
    if SessionState.isEnabled { UserDefaults.standard.set(name, forKey: Self.currentProjectKey) }
    isLoaded = false
    items = []
    tree = ProjectTree()
    currentTensorId = nil
    output = ProjectOutput()
    ratings = [:]
    storedMasks = [:]
    childMasks = [:]
    moodboardShuffles = [:]
    await reload()
  }

  /// Sets the current project's output folder overrides.
  func setOutput(_ output: ProjectOutput) {
    self.output = output
    project.output = output
  }

  /// The project called `name`, open or not, for work that reads and saves into its own project
  /// whichever is open: the current one, else one opened for it (the same one every caller gets
  /// while one holds it, see `heldProjects`). Nil when there's no such project file.
  func project(named name: String) -> Project? {
    if name == project.name { return project }
    if let held = heldProjects[name]?.project { return held }
    let url = Self.url(for: name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let opened = Project(url: url)
    heldProjects[name] = WeakProject(opened)
    return opened
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
        Log.attempt(Log.project, "Renaming a project's \(suffix) file") {
          try FileManager.default.moveItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
        }
      }
    }
    project = Project(url: target)
    if SessionState.isEnabled { UserDefaults.standard.set(name, forKey: Self.currentProjectKey) }
    await reload()
  }

  /// The project opened in place of `name` when it's deleted while current: the one after it in
  /// the list, else the one before, else a new empty one (not `name` again, which would bring the
  /// deleted project's name straight back).
  func projectToOpen(afterDeleting name: String) -> String {
    let others = Self.scanProjectNames()
    let all = (others.contains(name) ? others : (others + [name])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    if let index = all.firstIndex(of: name) {
      if index + 1 < all.count { return all[index + 1] }
      if index > 0 { return all[index - 1] }
    }
    return availableName()
  }

  /// Deletes the project called `name`: its file (and -wal/-shm) go to the Trash, its cached clip
  /// videos are removed. The current project is switched away from first (`projectToOpen`), so
  /// nothing is open on the file when it moves; one still held for a job (`heldProjects`) is
  /// closed, so the job finds it closed (`Project.isOpen`) rather than writing into the Trash.
  /// Returns the trashed project file, nil when it went for good (iPad, see `trashProjectFiles`).
  @discardableResult
  func delete(_ name: String) async throws -> URL? {
    if name == project.name {
      await open(projectToOpen(afterDeleting: name))
    }
    // Never the file that's open (another switch brought it back meanwhile).
    guard name != project.name else { throw DeleteError.stillOpen(name) }
    if let held = heldProjects.removeValue(forKey: name)?.project { await held.close() }
    let trashed = try await Self.trashProjectFiles(at: Self.url(for: name))
    Self.removeClipFiles(in: Self.clipCache, project: name)
    // Thumbnails are cached by the file's path: a project made later under the same name mustn't
    // show this one's.
    Self.thumbnails.removeAllObjects()
    projectNames = Self.scanProjectNames()
    if !projectNames.contains(project.name) { projectNames = (projectNames + [project.name]).sorted() }
    return trashed
  }

  enum DeleteError: LocalizedError {
    case stillOpen(String)
    var errorDescription: String? {
      switch self {
      case .stillOpen(let name): "“\(name)” is open again. Switch to another project and try again."
      }
    }
  }

  /// Moves a project file and its -wal/-shm to the Trash. On iPad they're removed instead: the
  /// Trash is the Mac's (Files' Recently Deleted only takes what's deleted in Files), and the
  /// confirmation says it can't be undone. On the Mac a failure leaves the files where they are
  /// rather than removing them outright.
  @concurrent nonisolated static func trashProjectFiles(at url: URL) async throws -> URL? {
    let fileManager = FileManager.default
    func discard(_ file: URL) throws -> URL? {
      #if os(macOS)
        var trashed: NSURL?
        try fileManager.trashItem(at: file, resultingItemURL: &trashed)
        return trashed as URL?
      #else
        try fileManager.removeItem(at: file)
        return nil
      #endif
    }
    // The database first: when it can't move, nothing else has.
    let trashed = fileManager.fileExists(atPath: url.path) ? try discard(url) : nil
    for suffix in ["-wal", "-shm"] {
      let side = URL(fileURLWithPath: url.path + suffix)
      guard fileManager.fileExists(atPath: side.path) else { continue }
      Log.attempt(Log.project, "Deleting a project's \(suffix) file") { _ = try discard(side) }
    }
    return trashed
  }

  nonisolated static func scanProjectNames() -> [String] {
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
    timings: GenerationTimings? = nil,
    refined: RefinedStep? = nil,
    resultMask: CanvasMask? = nil,
    into target: Project? = nil,
    makeCurrent: () -> Bool = { true }
  ) async throws -> HistoryItem {
    var settings = request.configuration
    settings.seed = request.seed
    if output.isVideo { settings.numFrames = output.frames.count }
    // The current project, unless the caller names its own (`project(named:)`).
    let project = target ?? project
    let dump = JSONValue.fields(of: settings)
    // The run follows the step that was current when it started, or with the canvas, the
    // canvas's step: an Edit run's input is its result's parent. When the canvas isn't exactly
    // a step's image (an image from outside, moved, zoomed or another size), it goes in first as
    // a step of its own after the current one: Imported for an image from outside, as Draw Things
    // does. A refined region merged back (`request.merge`) follows the whole image it was
    // refined from, so that's the input saved, not the frame.
    //
    // When the step the run follows is an input entry showing that very image (Imported, or a
    // Moodboard or Mask entry made since), the entry is the input: it holds the canvas and the
    // whole moodboard as they were, which Use brings back.
    var parentTensorId = request.parentTensorId
    var inputTensorId: Int64?
    // The input's image, which an entry shares with the canvas's own step.
    var inputImageTensorId: Int64?
    // With paint, the input is the painted frame (or the Draw entry holding it), not the
    // unpainted source the result merges into.
    if let canvas = request.merge.flatMap({ $0.painted ? nil : $0.source }) ?? request.canvas {
      if let key = request.canvasTensorId, let image = await imageTensor(ofKey: key, in: project) {
        inputImageTensorId = image
        inputTensorId = key
        if let parent = parentTensorId, parent != key, await imageTensor(ofKey: parent, in: project) == image {
          inputTensorId = parent
        }
      } else if let tensor = ImageTensor.tensor(from: canvas) {
        let input = try await project.append(
          tensor: tensor, model: request.model, prompt: request.prompt,
          negativePrompt: request.negativePrompt, seed: request.seed, settings: dump,
          createdAt: startedAt, duration: 0,
          reason: request.canvasIsImported ? .imported : .other, generated: false,
          after: parentTensorId)
        inputTensorId = input.tensorId
        inputImageTensorId = input.tensorId
      }
      parentTensorId = inputTensorId ?? parentTensorId
    }
    let moodboard = request.moodboard.compactMap { entry in
      ImageTensor.tensor(from: entry.image).map { Project.MoodboardTensor(tensor: $0, weight: entry.weight) }
    }
    let item: HistoryItem
    var clipFrames: [Tensor<FloatType>] = []
    if let framesPerSecond = output.framesPerSecond {
      clipFrames = output.frames.map(ImageTensor.rgb)
      item = try await project.appendClip(
        frames: clipFrames,
        clip: Project.ClipContent(
          framesPerSecond: framesPerSecond, audio: output.audio, audioInput: output.audioInput),
        model: request.model, prompt: request.prompt, negativePrompt: request.negativePrompt,
        seed: request.seed, settings: dump, createdAt: finishedAt,
        duration: finishedAt.timeIntervalSince(startedAt), timings: timings, moodboard: moodboard,
        inputTensorId: inputTensorId, after: parentTensorId)
    } else {
      // A layered refine's bottom layer is its input's image, the step just found or saved.
      var refined = refined
      // With paint it's the unpainted source's own step (none for an image from outside: written
      // afresh), never the painted input.
      if let merge = request.merge, let inputImageTensorId {
        refined?.layers?.sourceTensorId = merge.painted ? merge.sourceTensorId : inputImageTensorId
      }
      // A layered refine's own image is its top layer: the frame.
      let image = refined?.layers.flatMap { ImageTensor.tensor(from: $0.frame) } ?? ImageTensor.rgb(output.frames[0])
      item = try await project.append(
        tensor: image, model: request.model, prompt: request.prompt,
        negativePrompt: request.negativePrompt, seed: request.seed,
        settings: dump, createdAt: finishedAt,
        duration: finishedAt.timeIntervalSince(startedAt), timings: timings, moodboard: moodboard,
        inputTensorId: inputTensorId, after: parentTensorId, refined: refined, colorMatch: request.colorMatch?.record)
    }
    // An image from outside the project, saved now as a merge's input (the image itself),
    // remembers the mask it was queued with. One already in the project remembered it when the job
    // was queued (`CreateModel.rememberCanvasMask`): writing it again here could undo a change
    // made since. The merged result keeps it too, moved as the image grew.
    if let source = request.canvasSourceMask, source.tensorId == nil, request.merge != nil, let inputImageTensorId {
      keepMask(source.mask, forImage: inputImageTensorId, size: CGSize(width: source.width, height: source.height), in: project)
    }
    if let resultMask {
      keepMask(resultMask, forImage: item.tensorId, size: refined.map { CGSize(width: $0.composite.width, height: $0.composite.height) }, in: project)
    }
    if project === self.project {
      // A fork may have renumbered other steps.
      let keepCurrent = !makeCurrent()
      if !keepCurrent { currentTensorId = Self.tip(of: item) }
      await reload()
      // The new step is likely the newest now, which the project records as no position.
      if keepCurrent { recordCurrent() }
    }
    // Tensor ids are per project: another project's step can only be the one just appended.
    let saved = project === self.project ? self.item(tensorId: item.tensorId) ?? item : item
    // The player asks for the clip's MP4 as soon as it's shown. Start it now from the frames still
    // in memory: reading them back means decompressing every frame from the project (~10 s for
    // 124 frames at 832×512). They're the tensors just saved, converted to images the same way.
    if project === self.project, saved.clip?.frames.count == clipFrames.count, !clipFrames.isEmpty {
      nonisolated(unsafe) let frames = clipFrames
      Task { _ = try? await videoFile(for: saved, frames: { ImageTensor.cgImage(from: frames[$0]) }) }
    }
    return saved
  }

  /// The step a run after `item` follows: its own, or a clip's last frame.
  static func tip(of item: HistoryItem) -> Int64 {
    item.clip?.frames.last ?? item.tensorId
  }

  /// The image of the step `key` names (its image, or an input entry's key), in `project` (read
  /// fresh when it isn't the one loaded); nil for no such step or one without an image.
  private func imageTensor(ofKey key: Int64, in project: Project) async -> Int64? {
    if project === self.project { return tree.step(tensorId: key).flatMap { tree.steps[$0]?.tensorId } }
    return await project.read { project in
      let tree = project.tree(items: false)
      return tree.step(tensorId: key).flatMap { tree.steps[$0]?.tensorId }
    }
  }

  /// A step's moodboard images and weights (empty when it had none).
  func moodboard(at id: StepID, in projectName: String) async -> [(image: CGImage, weight: Float)] {
    guard projectName == project.name else { return [] }
    let project = project
    return await project.read { $0.moodboard(at: id) }
  }

  /// The input entry a run went in after: the step it follows, past the hidden frame a canvas of
  /// another size was drawn into (`save`), when that's an entry. It holds the canvas and the whole
  /// moodboard as they were when the run was queued.
  func inputEntry(of item: HistoryItem) -> HistoryItem? {
    Self.inputEntry(of: item, in: tree)
  }

  /// `inputEntry` in `tree`: only Atelier's hidden frame steps (Other) are passed over; any other
  /// step that isn't listed (a Draw Things Moodboard or Mask step, an Imported one from before
  /// entries) ends the search, so an older entry beyond it isn't taken for the run's input.
  nonisolated static func inputEntry(of item: HistoryItem, in tree: ProjectTree) -> HistoryItem? {
    guard !item.isEntry else { return nil }
    var next = tree.steps[item.id]?.parent
    var seen: Set<StepID> = []
    while let id = next, let step = tree.steps[id] {
      guard seen.insert(id).inserted else {
        Log.once(Log.history, site: "inputEntry", "the parents above \(item.tensorId) loop at \(id.lineage)/\(id.logicalTime)")
        return nil
      }
      if let listed = tree.items[id] { return listed.isEntry ? listed : nil }
      guard !step.generated, step.reasonValue == ProjectFormat.Reason.other.rawValue else { return nil }
      next = step.parent
    }
    return nil
  }

  /// What's current when a project opens: the step it recorded, else the newest, by what finds it
  /// (an input entry's key, which its image would find the image's own step by instead).
  nonisolated static func openingCurrent(in tree: ProjectTree, stored: StepID?) -> Int64? {
    (stored ?? tree.newest).flatMap { tree.steps[$0]?.key }
  }

  /// A step's moodboard images, weights and `shuffle_<id>` tensors (empty when it had none).
  func moodboardImages(at id: StepID, in projectName: String) async -> [(image: CGImage, weight: Float, shuffleId: Int64)] {
    guard projectName == project.name else { return [] }
    let project = project
    return await project.read { $0.moodboardImages(at: id) }
  }

  // MARK: - Input entries

  /// What an input entry records, gathered on the Create screen.
  struct EntryInput {
    enum Canvas {
      case empty
      /// The current project's step whose image is on the canvas.
      case step(tensorId: Int64)
      /// An image that isn't a step of the project yet.
      case image(CGImage)
    }

    var reason: HistoryItem.EntryReason
    /// The current step when it was gathered, which the entry follows.
    var parent: Int64?
    var canvas: Canvas
    /// What the canvas shows, for the thumbnail.
    var canvasImage: CGImage?
    var mask: CanvasMask?
    var moodboard: [MoodboardItem]
    var model: String
    var prompt: String
    var negativePrompt: String
    var seed: UInt32
    var settings: [String: JSONValue]
  }

  /// What an entry would hold, for telling whether it repeats one (`isDuplicate`).
  nonisolated struct EntrySignature: Equatable {
    var canvasTensorId: Int64?
    var mask: CanvasMask?
    var moodboard: [HistoryItem.EntryMood]

    init(canvasTensorId: Int64?, mask: CanvasMask?, moodboard: [HistoryItem.EntryMood]) {
      self.canvasTensorId = canvasTensorId
      // A mask that paints nothing is no mask.
      self.mask = mask?.mayHavePaint == true ? mask : nil
      self.moodboard = moodboard
    }

    init(_ entry: HistoryItem) {
      self.init(canvasTensorId: entry.canvasTensorId, mask: entry.entryMask, moodboard: entry.entryMoodboard)
    }
  }

  /// Whether an entry holding `state` would repeat `entry` (nil: there's none to repeat): the same
  /// canvas image, mask and moodboard, weights and all. An image new to the project never does.
  nonisolated static func isDuplicate(_ state: EntrySignature?, of entry: HistoryItem?) -> Bool {
    guard let state, let entry, entry.isEntry else { return false }
    return EntrySignature(entry) == state
  }

  /// What an entry made from `input` now would hold; nil for an image new to the project.
  func signature(of input: EntryInput) -> EntrySignature? {
    let canvas: Int64?
    switch input.canvas {
    case .empty: canvas = nil
    case .step(let tensorId): canvas = tensorId
    case .image: return nil
    }
    // A moodboard image the project has no tensor for yet can't match any entry's.
    return EntrySignature(
      canvasTensorId: canvas, mask: input.mask,
      moodboard: input.moodboard.map { HistoryItem.EntryMood(shuffleId: moodboardShuffles[$0.id] ?? -1, weight: $0.weight) })
  }

  /// The entry the next one would follow and could repeat: the current step, when it's one.
  var currentEntry: HistoryItem? {
    currentTensorId.flatMap(entry(key:))
  }

  /// The input entry `key` finds, if it's one.
  func entry(key: Int64) -> HistoryItem? {
    tree.step(tensorId: key).flatMap { tree.items[$0] }.flatMap { $0.isEntry ? $0 : nil }
  }

  /// The `shuffle_<id>` tensor each moodboard image already has in the current project, so an
  /// entry shares it rather than storing the image again. Kept in the project file (Draw Things
  /// ignores the key); `Project.appendEntry` checks a row still uses one before sharing it.
  private(set) var moodboardShuffles: [UUID: Int64] = [:]

  /// Remembers that the moodboard images `ids` are the project's `shuffleIds` (restored from an
  /// entry, or just written).
  func noteMoodboardShuffles(_ ids: [UUID], _ shuffleIds: [Int64]) {
    guard !ids.isEmpty else { return }
    for (id, shuffleId) in zip(ids, shuffleIds) { moodboardShuffles[id] = shuffleId }
    project.moodboardShuffles = moodboardShuffles
  }

  /// Writes an input entry after the step `parent` names (its image or key; the newest when nil)
  /// and with `makeCurrent` makes it the current step, unless it would repeat that step
  /// (`isDuplicate`; an Imported image never does). Returns the entry, nil when none was written.
  ///
  /// `claim`, when given, is asked once the entry's tensors are made, just before it's written:
  /// false writes nothing (quitting took the entry meanwhile). `write` hears what was written as
  /// soon as the project has it, off the main actor (`EntryWrite`).
  @discardableResult
  func saveEntry(
    _ input: EntryInput, after parent: Int64?, makeCurrent: Bool, write: EntryWrite? = nil,
    claim: (() -> Bool)? = nil
  ) async throws -> HistoryItem? {
    guard isLoaded else { return nil }
    if input.reason != .imported, Self.isDuplicate(signature(of: input), of: parent.flatMap(entry(key:))) {
      return nil
    }
    let project = project
    let shuffles = moodboardShuffles
    let moods = input.moodboard.map { (id: $0.id, image: $0.image, weight: $0.weight, shuffleId: shuffles[$0.id]) }
    let made = await Self.entryContents(canvas: input.canvas, moodboard: moods, canvasImage: input.canvasImage)
    let canvas: Project.EntryCanvas
    switch input.canvas {
    case .empty: canvas = .empty
    case .step(let tensorId): canvas = .step(tensorId: tensorId)
    case .image:
      guard let tensor = made.image else { throw ProjectError.badImage }
      canvas = .image(tensor)
    }
    if let claim, !claim() { return nil }
    let appended = try await Self.appendEntry(
      to: project, reason: input.reason, canvas: canvas, mask: input.mask, moodboard: made.moodboard,
      thumbnail: made.thumbnail, input: input, after: parent, write: write)
    guard project === self.project else { return nil }
    noteMoodboardShuffles(input.moodboard.map(\.id), appended.shuffleIds)
    if makeCurrent { currentTensorId = appended.key }
    await reload()
    recordCurrent()
    return item(tensorId: appended.key)
  }

  /// `Project.appendEntry`, telling `write` what was written (or that nothing was) from where the
  /// write finished, off the main actor, so a main thread waiting on it doesn't wait on itself.
  @concurrent private nonisolated static func appendEntry(
    to project: Project, reason: HistoryItem.EntryReason, canvas: Project.EntryCanvas, mask: CanvasMask?,
    moodboard: [Project.EntryMood], thumbnail: CGImage?, input: EntryInput, after parent: Int64?, write: EntryWrite?
  ) async throws -> Project.AppendedEntry {
    do {
      let appended = try await project.appendEntry(
        reason: reason.reason, keyed: reason != .imported, canvas: canvas, mask: mask, moodboard: moodboard,
        thumbnail: thumbnail, model: input.model, prompt: input.prompt, negativePrompt: input.negativePrompt,
        seed: input.seed, settings: input.settings, createdAt: Date(), after: parent)
      write?.finish(appended)
      return appended
    } catch {
      write?.finish(nil)
      throw error
    }
  }

  /// `saveEntry` for quitting, which can't wait: written off the main actor while this waits for it,
  /// up to a few seconds. Made the current step when `makeCurrent`, as the project's newest.
  ///
  /// Waits until `deadline` at most, which several such writes share. Returns what finds the entry,
  /// nil when none was written (it repeated the step before, failed, or ran out of time).
  @discardableResult
  func saveEntryBeforeQuit(_ input: EntryInput, after parent: Int64?, makeCurrent: Bool, deadline: Date) -> Int64? {
    guard isLoaded, Date() < deadline, !Self.isDuplicate(signature(of: input), of: parent.flatMap(entry(key:))) else {
      return nil
    }
    let project = project
    let current = currentTensorId
    let written = Mutex<Int64?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      defer { done.signal() }
      // The project's own map: an earlier write at quit may have added to it.
      let shuffles = project.moodboardShuffles
      let moods = input.moodboard.map { (id: $0.id, image: $0.image, weight: $0.weight, shuffleId: shuffles[$0.id]) }
      let made = await Self.entryContents(canvas: input.canvas, moodboard: moods, canvasImage: input.canvasImage)
      let canvas: Project.EntryCanvas
      switch input.canvas {
      case .empty: canvas = .empty
      case .step(let tensorId): canvas = .step(tensorId: tensorId)
      case .image:
        guard let tensor = made.image else { return }
        canvas = .image(tensor)
      }
      guard let appended = try? await project.appendEntry(
        reason: input.reason.reason, keyed: input.reason != .imported, canvas: canvas, mask: input.mask,
        moodboard: made.moodboard, thumbnail: made.thumbnail, model: input.model, prompt: input.prompt,
        negativePrompt: input.negativePrompt, seed: input.seed, settings: input.settings, createdAt: Date(),
        after: parent)
      else { return }
      var map = project.moodboardShuffles
      for (mood, shuffleId) in zip(moods, appended.shuffleIds) { map[mood.id] = shuffleId }
      project.moodboardShuffles = map
      // `appendEntry` leaves the newest step current; otherwise the current one stays.
      if !makeCurrent, let current {
        let tree = project.tree(items: false)
        let step = tree.step(tensorId: current)
        project.setCurrentStep(step == tree.newest ? nil : step)
      }
      written.withLock { $0 = appended.key }
    }
    _ = done.wait(timeout: .now() + max(deadline.timeIntervalSinceNow, 0))
    return written.withLock { $0 }
  }

  /// An entry's tensors and thumbnail, made off the main actor: the canvas image's tensor when it's
  /// new, each moodboard image's, and the thumbnail (the canvas, else the moodboard's collage, else
  /// a blank tile).
  @concurrent private nonisolated static func entryContents(
    canvas: EntryInput.Canvas, moodboard: [(id: UUID, image: CGImage, weight: Float, shuffleId: Int64?)],
    canvasImage: CGImage?
  ) async -> (image: Tensor<FloatType>?, moodboard: [Project.EntryMood], thumbnail: CGImage?) {
    var image: Tensor<FloatType>?
    if case .image(let new) = canvas { image = ImageTensor.tensor(from: new) }
    let moods = moodboard.compactMap { mood in
      ImageTensor.tensor(from: mood.image).map { Project.EntryMood(shuffleId: mood.shuffleId, tensor: $0, weight: mood.weight) }
    }
    let thumbnail = canvasImage ?? EntryThumbnail.collage(moodboard.map(\.image)) ?? EntryThumbnail.blank()
    return (image, moods, thumbnail)
  }

  /// Removes the steps from the project. Later steps may be renumbered, so each is found by its
  /// image. A deleted current step hands over to its parent, else the newest step.
  func delete(_ items: [HistoryItem]) async throws {
    let project = project
    do {
      for item in items {
        if let clip = item.clip {
          let parent = try await project.deleteClip(frames: clip.frames)
          Self.removeClipFiles(project: project.name, clipId: clip.clipId, tensorId: item.tensorId)
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
    // A later image could be given a deleted one's tensor: don't let it inherit the mask either.
    let gone = await project.read { $0.pruneStoredMasks(keeping: $0.tree(items: false)) }
    if project === self.project { for tensorId in gone { storedMasks[tensorId] = nil } }
    // Nor its paint, nor a deleted Draw entry's record.
    await project.read {
      let tree = $0.tree(items: false)
      $0.pruneStoredPaint(keeping: tree)
      $0.pruneStoredMaskHidden(keeping: tree)
      $0.pruneStoredDrawRecords(keeping: tree)
    }
    // A later image could be given a deleted one's tensor: don't let it inherit the rating.
    let kept = ratings.filter { byTensor[$0.key] != nil }
    if kept.count != ratings.count { ratings = kept; project.ratings = kept }
  }

  // MARK: - Masks

  /// Whether the image has a mask to bring back or apply (`storedMask`): its own kept one, else
  /// one from before masks were kept (its newest Edit child's, its own refine record's), else a
  /// Draw Things layer mask.
  func hasStoredMask(tensorId: Int64) -> Bool {
    if let kept = storedMasks[tensorId] { return kept }
    return hasOlderMask(tensorId: tensorId)
  }

  /// A mask other than a kept one: `storedMask`'s fallbacks.
  private func hasOlderMask(tensorId: Int64) -> Bool {
    if childMasks[tensorId] != nil { return true }
    if let refine = byTensor[tensorId]?.sidecar.refine {
      return refine.mask != nil
    }
    return tree.layerMaskedImages.contains(tensorId)
  }

  /// The mask the image last had on the canvas, in its pixels: the one kept with it (none when it
  /// was cleared). For older projects, the mask its newest Edit child recorded, else a merged
  /// result's own record moved as the image grew, else a Draw Things canvas's painted layer mask
  /// (read-only, one bitmap; not for Atelier's own merged steps, whose layer mask is their
  /// record's).
  func storedMask(tensorId: Int64) async -> CanvasMask? {
    let project = project
    if let kept = storedMasks[tensorId] {
      guard kept else { return nil }
      if let mask = await project.read({ $0.storedMask(forImage: tensorId) }) { return mask }
    }
    if let mask = childMasks[tensorId] { return mask }
    if let refine = byTensor[tensorId]?.sidecar.refine {
      return refine.mask.flatMap { Self.resultMask(of: refine, mask: $0) }
    }
    guard tree.layerMaskedImages.contains(tensorId) else { return nil }
    return await project.read { $0.layerMask(tensorId: tensorId) }
  }

  /// Keeps `mask` as the image's last mask (nil or one that paints nothing clears it), compacted
  /// for an image of `size` (`CanvasMask.compacted`). Clearing writes an empty mask where an older
  /// one would otherwise come back, and removes the key where none would.
  func setMask(_ mask: CanvasMask?, forImage tensorId: Int64, size: CGSize?) {
    guard tree.step(tensorId: tensorId) != nil else { return }
    keepMask(mask, forImage: tensorId, size: size, in: project)
  }

  /// Whether the image's mask was hidden (`Project.storedMaskHidden`).
  func storedMaskHidden(tensorId: Int64) async -> Bool {
    let project = project
    return await project.read { $0.storedMaskHidden(forImage: tensorId) }
  }

  /// Keeps whether the image's mask is hidden.
  func setMaskHidden(_ hidden: Bool, forImage tensorId: Int64) {
    guard tree.step(tensorId: tensorId) != nil else { return }
    project.setStoredMaskHidden(hidden, forImage: tensorId)
  }

  private func keepMask(_ mask: CanvasMask?, forImage tensorId: Int64, size: CGSize?, in project: Project) {
    let loaded = project === self.project
    if let mask, mask.mayHavePaint {
      project.setStoredMask(mask.compacted(for: size), forImage: tensorId)
      if loaded { storedMasks[tensorId] = true }
    } else if loaded {
      if hasOlderMask(tensorId: tensorId) {
        guard storedMasks[tensorId] != false else { return }
        project.setStoredMask(CanvasMask(), forImage: tensorId)
        storedMasks[tensorId] = false
      } else if storedMasks[tensorId] != nil {
        project.setStoredMask(nil, forImage: tensorId)
        storedMasks[tensorId] = nil
      }
    } else {
      project.setStoredMask(nil, forImage: tensorId)
    }
  }

  // MARK: - Paint

  /// The picture a Draw entry was painted on and its paint (`Project.DrawRecord`), when the entry
  /// has a record and that image is still a step of the project; nil otherwise (an older entry, a
  /// deleted image, one Draw Things wrote), and the entry's own baked image is all there is.
  /// Its image must still be the size recorded (`Project.DrawRecord.fits`), checked once loaded.
  func drawBase(ofEntry entry: HistoryItem) -> Project.DrawRecord? {
    guard entry.entryReason == .draw, let record = project.storedDrawRecord(forEntry: entry.tensorId),
          record.paint.mayHaveColor, tree.step(tensorId: record.baseTensorId) != nil
    else { return nil }
    return record
  }

  /// Keeps what the Draw entry `key` was painted on: the image `baseTensorId` of `size`, `paint`,
  /// and the fade its image was made with.
  func setDrawBase(_ paint: CanvasPaint, baseTensorId: Int64, size: CGSize, fade: CanvasPaint.Fade?, forEntry key: Int64) {
    guard tree.step(tensorId: key) != nil, tree.step(tensorId: baseTensorId) != nil else { return }
    project.setStoredDrawRecord(
      Project.DrawRecord(
        baseTensorId: baseTensorId, paint: paint.compacted(for: size), width: Int(size.width), height: Int(size.height), fade: fade),
      forEntry: key)
  }

  /// The paint layer the image last had on the canvas (`CreateModel.canvasPaint`), in its pixels;
  /// nil for none.
  func storedPaint(tensorId: Int64) async -> CanvasPaint? {
    let project = project
    return await project.read { $0.storedPaint(forImage: tensorId) }
  }

  /// Keeps `paint` as the image's last paint layer, compacted for an image of `size`
  /// (`CanvasPaint.compacted`); nil or one that shows nothing removes it.
  func setPaint(_ paint: CanvasPaint?, forImage tensorId: Int64, size: CGSize?) {
    guard tree.step(tensorId: tensorId) != nil else { return }
    project.setStoredPaint(paint?.mayHaveColor == true ? paint?.compacted(for: size) : nil, forImage: tensorId)
  }

  /// Each image's newest Edit child's recorded mask (`refine_mask`, in the image's pixels), from
  /// `items` newest first: what an image from before masks were kept had on the canvas last.
  nonisolated static func childMasks(_ items: [HistoryItem]) -> [Int64: CanvasMask] {
    var masks: [Int64: CanvasMask] = [:]
    for item in items {
      guard let input = item.inputTensorId, masks[input] == nil, let mask = item.sidecar.refine?.mask else { continue }
      masks[input] = mask
    }
    return masks
  }

  /// A merged result's recorded mask (in its input's pixels) on the result: moved by where the
  /// input's top left landed, as `CanvasMerge.merge` grows the image (the union of the input and
  /// the frame, to whole pixels).
  nonisolated static func resultMask(of record: RefineRecord, mask: CanvasMask) -> CanvasMask {
    guard record.rect.count == 4 else { return mask }
    let origin = CGPoint(x: -min(record.rect[0].rounded(.down), 0), y: -min(record.rect[1].rounded(.down), 0))
    return mask.translated(by: origin)
  }

  // MARK: - Ratings

  /// The item's star rating, 0 when it has none.
  func rating(of item: HistoryItem) -> Int {
    ratings[item.tensorId] ?? 0
  }

  /// Gives the items `stars` (0 to 5; 0 clears the rating), saved in the project.
  func setRating(_ stars: Int, for items: [HistoryItem]) {
    let stars = min(max(stars, 0), 5)
    for item in items { ratings[item.tensorId] = stars > 0 ? stars : nil }
    project.ratings = ratings
  }

  func item(_ id: StepID) -> HistoryItem? {
    tree.items[id]
  }

  func item(tensorId: Int64) -> HistoryItem? {
    byTensor[tensorId]
  }

  /// The video whose frame is the image `tensorId`, any frame (History lists a video by its first).
  func clipItem(frame tensorId: Int64) -> HistoryItem? {
    tree.clipItem(frame: tensorId).flatMap { tree.items[$0] }
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
    return Self.lineage(of: current, parent: parent(of:), firstChild: { self.children(of: $0).first })
  }

  /// `currentLineage` from `current`: the newest line below it (each step's first child), newest
  /// first, then it and its ancestors. A loop in the links, which should never be, ends the walk
  /// where it comes back round (logged once), rather than walking it forever: the strip asks for
  /// this on every change of the current step.
  nonisolated static func lineage(
    of current: HistoryItem, parent: (HistoryItem) -> HistoryItem?, firstChild: (HistoryItem) -> HistoryItem?
  ) -> [HistoryItem] {
    var seen: Set<Int64> = [current.tensorId]
    var below: [HistoryItem] = []
    var next = firstChild(current)
    while let item = next {
      guard seen.insert(item.tensorId).inserted else {
        Log.once(Log.history, site: "currentLineage", "the children below \(current.tensorId) loop back to \(item.tensorId)")
        break
      }
      below.append(item)
      next = firstChild(item)
    }
    var line = Array(below.reversed())
    line.append(current)
    // Each step once: an ancestor that's also below ends the line too.
    var up = parent(current)
    while let item = up {
      guard seen.insert(item.tensorId).inserted else {
        Log.once(Log.history, site: "currentLineage", "the parents above \(current.tensorId) loop back to \(item.tensorId)")
        break
      }
      line.append(item)
      up = parent(item)
    }
    return line
  }

  /// The step's JPEG preview (`half` for grids), decoded off the main actor.
  func thumbnail(for item: HistoryItem, half: Bool) async -> CGImage? {
    let key = "\(project.url.path)#\(item.previewId)#\(half)" as NSString
    if let cached = Self.thumbnails.object(forKey: key) { return cached }
    let project = project
    let image = await project.read { $0.thumbnail(previewId: item.previewId, half: half) }
    if let image { Self.thumbnails.setObject(image, forKey: key) }
    return image
  }

  /// The full-resolution image, decoded from the project's tensor.
  func image(for item: HistoryItem) async -> CGImage? {
    let project = project
    return await project.read { $0.image(for: item) }
  }

  /// An Edit step's input step and image, while that step still exists in `projectName`.
  func input(of item: HistoryItem, in projectName: String) async -> (id: StepID, image: CGImage, imageTensorId: Int64)? {
    guard projectName == project.name, let tensorId = item.inputTensorId else { return nil }
    let project = project
    return await project.read { $0.input(of: item.id, tensorId: tensorId) }
  }

  /// The full-resolution image of a step in `projectName` (when that's the current project).
  func image(at id: StepID, in projectName: String) async -> CGImage? {
    guard projectName == project.name else { return nil }
    let project = project
    return await project.read { $0.image(at: id) }
  }

  /// A step's image tensor in `projectName` (when that's the current project).
  func tensorId(at id: StepID, in projectName: String) async -> Int64? {
    guard projectName == project.name else { return nil }
    let project = project
    return await project.read { $0.imageTensorId(at: id) }
  }

  /// The step's layers finer than its image (`Project.detailLayers`), in `projectName` (when
  /// that's the current project); empty for most steps.
  func detailLayers(tensorId: Int64, in projectName: String) async -> [Project.DetailLayer] {
    guard projectName == project.name else { return [] }
    let project = project
    return await project.read { $0.detailLayers(tensorId: tensorId) }
  }

  /// The full-resolution image `tensorId` in `projectName` (when that's the current project).
  func image(tensorId: Int64, in projectName: String) async -> CGImage? {
    guard projectName == project.name else { return nil }
    let project = project
    return await project.read { $0.image(tensorId: tensorId) }
  }

  /// Writes a newly generated image or clip to the output folder when Settings or the project
  /// turns that on, named like an export. Returns why it couldn't be written, if it couldn't.
  /// `project` is the one it was saved in when that isn't the current one.
  func writeToOutputFolder(_ item: HistoryItem, image: CGImage?, in project: Project? = nil) async -> String? {
    let output = project.map { $0 === self.project ? self.output : $0.output } ?? self.output
    guard output.effectiveSaves else { return nil }
    let access = FolderBookmarks.open(output.effectiveFolder)
    let folder = access.url
    let name = project.map { "\($0.name) \(item.id.logicalTime)-\(item.sidecar.seed)" } ?? fileName(for: item)
    do {
      defer { withExtendedLifetime(access) {} }
      let file: (data: Data?, video: URL?, extension: String)
      if item.isVideo {
        file = (nil, try await videoFile(for: item), "mp4")
      } else {
        var image = image
        if AppSettings.exportsFullDetail, let full = await fullDetailImage(tensorId: item.tensorId, in: project) {
          image = full
        }
        guard let image else { throw ProjectError.badImage }
        file = (try Self.pngData(image, sidecar: item.sidecar), nil, "png")
      }
      try await Self.write(data: file.data, video: file.video, extension: file.extension, name: name, to: folder)
      return nil
    } catch {
      return "Saved to the project, but not to the output folder: \(error.localizedDescription)"
    }
  }

  /// Writes a file into the output folder, under a name no file there has.
  @concurrent private nonisolated static func write(
    data: Data?, video: URL?, extension fileExtension: String, name: String, to folder: URL
  ) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Steps can be renumbered when the history branches, so never overwrite a file.
    var url = folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(fileExtension)
      n += 1
    }
    if let video {
      try FileManager.default.copyItem(at: video, to: url)
    } else {
      try data?.write(to: url, options: .withoutOverwriting)
    }
  }

  // MARK: - Clips

  /// A clip's frames, decoded from the project's tensors.
  func frames(of item: HistoryItem) async -> [CGImage] {
    guard let clip = item.clip else { return [] }
    let project = project
    return await project.read { project in clip.frames.compactMap { project.image(tensorId: $0) } }
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
    let samples = await project.read { $0.audio(id: audioId) }
    return samples.map { ($0, RemoteModelTraits.audioSampleRate(of: item.sidecar.model)) }
  }

  /// The audio file a video run took, as it was resampled for the model.
  func audioInput(of item: HistoryItem) async -> Tensor<Float>? {
    guard let audioId = item.clip?.inputAudioId else { return nil }
    let project = project
    return await project.read { $0.audio(id: audioId) }
  }

  /// The clip as an MP4 with its soundtrack and settings, written once into the caches folder
  /// and reused by the player, exports, drags and the output folder.
  func videoFile(for item: HistoryItem) async throws -> URL {
    try await videoFile(for: item, frames: nil)
  }

  /// `frames`, when given, supplies the clip's images instead of reading them from the project.
  private func videoFile(
    for item: HistoryItem, frames: (@Sendable (Int) -> CGImage?)?
  ) async throws -> URL {
    guard let clip = item.clip else { throw ClipVideoError.noFrames }
    let codec = VideoCodec.current
    let url = Self.clipCache.appendingPathComponent(
      Self.clipFileName(project: project.name, clipId: clip.clipId, tensorId: item.tensorId, codec: codec))
    if FileManager.default.fileExists(atPath: url.path) { return url }
    if let pending = videoFiles[url] { return try await pending.value }
    let project = project
    let metadata = videoMetadata(item)
    let audioId = clip.audioId
    let sampleRate = RemoteModelTraits.audioSampleRate(of: item.sidecar.model)
    // Registered before anything is awaited, so callers asking at once share one write.
    let task = Task.detached {
      let audio = audioId.flatMap { project.audio(id: $0) }.map { (samples: $0, sampleRate: sampleRate) }
      try FileManager.default.createDirectory(at: Self.clipCache, withIntermediateDirectories: true)
      // Written beside its final name, so a half-written file is never taken as done.
      let partial = url.deletingPathExtension().appendingPathExtension(Self.partialExtension)
      do {
        try await ClipVideo.write(
          to: partial, count: clip.frames.count,
          frame: { frames?($0) ?? project.image(tensorId: clip.frames[$0]) },
          framesPerSecond: clip.framesPerSecond, audio: audio?.samples,
          audioSampleRate: audio?.sampleRate ?? 0, codec: codec, metadata: metadata)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
      } catch {
        try? FileManager.default.removeItem(at: partial)
        throw error
      }
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

  private nonisolated static let partialExtension = "partial.mp4"

  private nonisolated static func clipFileName(
    project: String, clipId: Int64, tensorId: Int64, codec: VideoCodec
  ) -> String {
    "\(project)-\(clipId)-\(tensorId)-\(codec.rawValue).mp4"
  }

  /// Removes every cached video of the project called `project` (deleted).
  nonisolated static func removeClipFiles(in folder: URL, project: String) {
    for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
      guard clipFileParts(file)?.project == project else { continue }
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
    }
  }

  /// A cached clip video's project and codec, read back from its name
  /// ("<project>-<clip>-<tensor>-<codec>.mp4"; a project's name can hold dashes itself). Nil for
  /// anything else, a half-written one too.
  private nonisolated static func clipFileParts(_ file: String) -> (project: String, codec: VideoCodec)? {
    guard file.hasSuffix(".mp4"), !file.hasSuffix("." + partialExtension) else { return nil }
    let parts = file.dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count >= 4, Int64(parts[parts.count - 2]) != nil, Int64(parts[parts.count - 3]) != nil,
          let codec = VideoCodec(rawValue: String(parts[parts.count - 1]))
    else { return nil }
    return (parts.dropLast(3).joined(separator: "-"), codec)
  }

  /// Removes a deleted clip's cached videos, in every codec.
  nonisolated static func removeClipFiles(
    in folder: URL = clipCache, project: String, clipId: Int64, tensorId: Int64
  ) {
    for codec in VideoCodec.allCases {
      let name = clipFileName(project: project, clipId: clipId, tensorId: tensorId, codec: codec)
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  /// Drops what the clip cache can't use at launch: videos cut off by a quit or a crash, videos in
  /// a codec no longer chosen, and videos of projects that are gone or renamed.
  @concurrent nonisolated static func pruneClipCache(keepingProject current: String) async {
    let projects = Set(scanProjectNames() + [current])
    pruneClipCache(in: clipCache, projects: projects, codec: .current)
  }

  nonisolated static func pruneClipCache(in folder: URL, projects: Set<String>, codec: VideoCodec) {
    let fileManager = FileManager.default
    for file in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
      let url = folder.appendingPathComponent(file)
      if file.hasSuffix("." + partialExtension) {
        try? fileManager.removeItem(at: url)
        continue
      }
      guard let (project, fileCodec) = clipFileParts(file) else { continue }
      if fileCodec != codec || !projects.contains(project) {
        try? fileManager.removeItem(at: url)
      }
    }
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
  /// metadata (`ImageMetadata`) and Atelier's sidecar in an `Atelier` iTXt chunk. At full detail
  /// unless Settings says otherwise (`exportImage`).
  func pngData(_ item: HistoryItem) async throws -> Data {
    guard let image = await exportImage(for: item) else { throw ProjectError.badImage }
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

  /// The image as exports, copies and drags take it: at full detail (`Project.finestDensity`),
  /// unless Settings ▸ Images says the image's own size (`AppSettings.exportsFullDetail`).
  func exportImage(for item: HistoryItem) async -> CGImage? {
    let project = project
    let density = AppSettings.exportsFullDetail ? Project.finestDensity : 120
    guard let tensorId = item.imageTensorId else { return nil }
    return await project.read { $0.image(tensorId: tensorId, density: density) }
  }

  /// The step's image at full detail when it has layers finer than its image; nil when it has
  /// none (its image is all there is) or isn't in `project` (the current one by default).
  func fullDetailImage(tensorId: Int64, in project: Project? = nil) async -> CGImage? {
    let project = project ?? self.project
    return await project.read {
      $0.hasDetail(tensorId: tensorId) ? $0.image(tensorId: tensorId, density: Project.finestDensity) : nil
    }
  }

  /// Puts the full-resolution image on the clipboard.
  func copyImage(_ item: HistoryItem) async {
    if let image = await exportImage(for: item) { Self.copy(image) }
  }

  /// Puts several full-resolution images on the clipboard, one pasteboard item each.
  func copyImages(_ items: [HistoryItem]) async {
    guard items.count > 1 else {
      if let item = items.first { await copyImage(item) }
      return
    }
    var images: [(png: Data?, tiff: Data?)] = []
    for item in items {
      guard let image = await exportImage(for: item) else { continue }
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
    let legacy = await Self.scanLegacy(AppSettings.historyDirectory)
    guard !legacy.isEmpty else {
      UserDefaults.standard.set(true, forKey: Self.legacyImportedKey)
      return
    }
    let target = project.name == Self.defaultProjectName
      ? project : Project(url: Self.url(for: Self.defaultProjectName))
    importProgress = (0, legacy.count)
    for (index, entry) in legacy.reversed().enumerated() {
      let tensor = await Self.legacyTensor(at: entry.png)
      if let tensor {
        let sidecar = entry.sidecar
        do {
          _ = try await target.append(
            tensor: tensor, model: sidecar.model, prompt: sidecar.prompt,
            negativePrompt: sidecar.negativePrompt, seed: sidecar.seed,
            settings: sidecar.configuration, createdAt: sidecar.createdAt,
            duration: sidecar.durationSeconds)
        } catch {
          // The old file stays where it is.
          Log.history.error("Couldn't import \(entry.png.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
      }
      importProgress = (index + 1, legacy.count)
    }
    importProgress = nil
    UserDefaults.standard.set(true, forKey: Self.legacyImportedKey)
    if target === project { await reload() }
  }

  @concurrent private nonisolated static func legacyTensor(at png: URL) async -> Tensor<FloatType>? {
    guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return ImageTensor.tensor(from: image)
  }

  @concurrent private nonisolated static func scanLegacy(_ root: URL) async -> [(png: URL, sidecar: Sidecar)] {
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
nonisolated enum PNGText {
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
nonisolated enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  static func fields(of value: Any) -> [String: JSONValue] {
    if let configuration = value as? PipelineConfiguration {
      var fields = fields(of: configuration.base)
      fields["shiftForAudio"] = JSONValue(configuration.shiftForAudio)
      fields["usesSolAttention"] = .bool(configuration.usesSolAttention)
      fields["solAttentionStart"] = JSONValue(configuration.solAttentionStart)
      fields["solAttentionTau"] = JSONValue(configuration.solAttentionTau)
      return fields
    }
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

/// A PNG to drag into Finder (as a file) or another app (as image data), or to share, encoded on
/// drop (or when the share target asks for it); a clip goes as its MP4.
nonisolated struct PNGExport: Transferable, Identifiable {
  /// The image tensor.
  var id: Int64
  var name: String
  var data: @Sendable () async throws -> Data
  /// Set for a clip: its video file.
  var video: (@Sendable () async throws -> URL)?
  /// Set when it's shared rather than dragged: its file then goes in the Shares area, kept
  /// longer (`TemporaryFiles.shareLifetime`).
  var isShared = false

  /// A new folder for its file, in the area its use calls for.
  private var folder: URL {
    isShared ? TemporaryFiles.newShareFolder() : TemporaryFiles.newDragFolder()
  }

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .mpeg4Movie) { export in
      let folder = export.folder
      let file = folder.appendingPathComponent(export.name).appendingPathExtension("mp4")
      guard let video = export.video else { throw ClipVideoError.noFrames }
      try FileManager.default.copyItem(at: try await video(), to: file)
      return SentTransferredFile(file)
    }
    .exportingCondition { $0.video != nil }
    .suggestedFileName { $0.name + ".mp4" }
    FileRepresentation(exportedContentType: .png) { export in
      let folder = export.folder
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

/// The thumbnail of an input entry with no canvas image: its moodboard side by side, else a blank
/// tile.
nonisolated enum EntryThumbnail {
  static let side = 384

  /// The images in a row of square tiles, each filled and cropped to its tile, at most four.
  static func collage(_ images: [CGImage]) -> CGImage? {
    let images = Array(images.prefix(4))
    guard !images.isEmpty, let context = context(width: side * images.count, height: side) else { return nil }
    context.interpolationQuality = .high
    for (index, image) in images.enumerated() {
      let scale = max(Double(side) / Double(image.width), Double(side) / Double(image.height))
      let width = Double(image.width) * scale, height = Double(image.height) * scale
      let tile = CGRect(x: index * side, y: 0, width: side, height: side)
      context.saveGState()
      context.clip(to: tile)
      context.draw(image, in: CGRect(x: tile.midX - width / 2, y: tile.midY - height / 2, width: width, height: height))
      context.restoreGState()
    }
    return context.makeImage()
  }

  /// A plain grey square, for an empty canvas with an empty moodboard.
  static func blank() -> CGImage? {
    guard let context = context(width: side, height: side) else { return nil }
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()
  }

  private static func context(width: Int, height: Int) -> CGContext? {
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  }
}

/// An entry being written (`HistoryStore.saveEntry`), which quitting can wait for: what the
/// project got, published from where the write finished, never needing the main actor.
final nonisolated class EntryWrite: Sendable {
  private let result = Mutex<Project.AppendedEntry?>(nil)
  private let done = DispatchSemaphore(value: 0)

  func finish(_ appended: Project.AppendedEntry?) {
    result.withLock { $0 = appended }
    done.signal()
  }

  /// What was written, waiting until `deadline` at most; nil when nothing was, or not by then.
  func wait(until deadline: Date) -> Project.AppendedEntry? {
    guard done.wait(timeout: .now() + max(deadline.timeIntervalSinceNow, 0)) == .success else { return nil }
    done.signal()
    return result.withLock { $0 }
  }
}
