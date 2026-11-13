@preconcurrency import _MediaGenerationKit
import AVFoundation
import CoreGraphics
@preconcurrency import Diffusion
import Foundation
@preconcurrency import ModelZoo
import Observation
import UserNotifications

/// State behind the Create screen: the selected model, the inspector values, and the running job.
@MainActor
@Observable
final class CreateModel {
  /// The running job's progress.
  nonisolated enum Phase: Equatable {
    case idle
    case running(String)
    case cancelling
  }

  /// Generate starts from the prompt alone; Edit also sends the canvas to the model.
  nonisolated enum CanvasMode: String {
    case generate, edit
  }

  let engine = GenerationEngine()
  /// The servers this device can run jobs on.
  let remoteServers = RemoteServerList()
  /// What the paired servers' styles were when last seen.
  let remoteStyles = RemoteStyleLibrary()
  /// Atelier's own place on your tailnet.
  let tailnet = RemoteTailnet()
  /// What runs jobs for `target`.
  func backend(for target: JobTarget) -> any GenerationBackend {
    switch target {
    case .local: engine
    case .remote(let serverID): remoteServers.backend(for: serverID)
    }
  }

  /// A server's models, LoRAs and model folder listing, as the pickers want them.
  struct ServerCatalog {
    var models: [MediaGenerationResolvedModel]
    var loras: [ModelLibrary.LoRA]
    var files: [String]
    var upscalers: RemoteUpscalers
    /// `RemoteProtocol.features` the server lists.
    var features: Set<String> = []
  }

  /// Where new jobs run (Run on). A job keeps the target it was queued with.
  var runTarget = JobTarget.local {
    didSet {
      guard runTarget != oldValue else { return }
      serverCatalog = nil
      saveSession()
      Task { await loadRunTargetCatalog() }
    }
  }

  /// What the selected server has; nil on this device, or until it answers.
  private(set) var serverCatalog: ServerCatalog?
  /// The models the pickers offer: `models`, which are always this device's, or the server's.
  var availableModels: [MediaGenerationResolvedModel] {
    runTarget == .local ? models : serverCatalog?.models ?? []
  }

  /// The file names the settings offer refiners and upscalers from.
  private var availableFiles: [String] {
    runTarget == .local ? modelFiles : serverCatalog?.files ?? []
  }

  /// The LoRAs the pickers offer: `library`'s, or the selected server's.
  func availableLoRAs(in library: ModelLibrary) -> [ModelLibrary.LoRA] {
    runTarget == .local ? library.loras : serverCatalog?.loras ?? []
  }

  /// The name of the selected server; nil on this device.
  var runTargetServerName: String? {
    guard case .remote(let id) = runTarget else { return nil }
    return remoteServers.name(of: id) ?? "The server"
  }

  /// The selected server and what it can upscale with; nil on this device.
  var runTargetUpscalers: (name: String, upscalers: RemoteUpscalers)? {
    guard let name = runTargetServerName else { return nil }
    return (name, serverCatalog?.upscalers ?? RemoteUpscalers())
  }

  /// Why Generate can't go to the selected server right now.
  var runTargetProblem: String? {
    guard case .remote(let id) = runTarget, let name = runTargetServerName else { return nil }
    if remoteServers.status(of: id) == .offline { return "\(name) is offline." }
    if serverCatalog == nil { return "Connecting to \(name)…" }
    if let selectedModel, !availableModels.contains(where: { $0.file == selectedModel }) {
      return "\(name) doesn't have this model."
    }
    return runTargetMaskProblem
  }

  /// Generate would send a mask to a server too old to use one (`runTargetTakesMasks`).
  var runTargetMaskProblem: String? {
    guard !runTargetTakesMasks, let name = runTargetServerName, screenFrameHasPaint else { return nil }
    return "\(name) can't take masks: its Atelier is older. Clear the mask or run on this device."
  }

  /// This device, as Run on and the Queue call it.
  static var thisDeviceName: String {
    #if os(macOS)
      "This Mac"
    #else
      "This iPad"
    #endif
  }

  /// Where a job runs, for the Queue: its server's name, or this device once there's a choice.
  func runLocationName(of job: JobQueue.Job) -> String? {
    switch job.target {
    case .remote(let id): remoteServers.name(of: id) ?? "Removed server"
    case .local: remoteServers.servers.isEmpty ? nil : Self.thisDeviceName
    }
  }

  /// Rereads the selected server's catalog and puts the pickers on it, keeping the selected model
  /// and its settings if the server has it. Back on this device, the same with local models.
  func loadRunTargetCatalog() async {
    let target = runTarget
    guard case .remote(let id) = target else {
      serverCatalog = nil
      reconcileModel()
      return
    }
    serverCatalog = nil
    guard let catalog = try? await remoteServers.backend(for: id).catalog(), target == runTarget else { return }
    serverCatalog = ServerCatalog(
      models: catalog.models.map {
        MediaGenerationResolvedModel(file: $0.file, name: $0.name, description: "", version: $0.version, isDownloaded: true)
      },
      loras: catalog.loras.map {
        // Only its name and family are read here: it lives on the server.
        ModelLibrary.LoRA(name: $0.name, file: $0.file, prefix: $0.prefix, version: $0.version, size: 1, registry: URL(filePath: "/"))
      },
      files: catalog.files, upscalers: catalog.upscalers, features: catalog.features)
    reconcileModel()
  }

  /// After Run on changes: the model the last session had on that server if it's there, the
  /// selected one if it's still offered (its defaults now come from where it'll run), else the first.
  private func reconcileModel() {
    let available = availableModels
    if let restoring = restoringRemoteSession, available.contains(where: { $0.file == restoring.model }) {
      restoringRemoteSession = nil
      pendingSettings = restoring.settings
      if selectedModel == restoring.model, let model = restoring.model {
        loadDefaults(for: model)
      } else {
        selectedModel = restoring.model
      }
    } else if let selectedModel, available.contains(where: { $0.file == selectedModel }) {
      loadDefaults(for: selectedModel)
    } else {
      selectedModel = available.first?.file
    }
  }

  /// A session that ended on a server, until that server has answered.
  @ObservationIgnored private var restoringRemoteSession: SessionState?

  /// Back on the server the last session ended on.
  private func restoreRunTarget(from session: SessionState) {
    guard let target = session.runTarget, case .remote(let id) = target, remoteServers.name(of: id) != nil else { return }
    restoringRemoteSession = session
    runTarget = target
  }

  /// Watches paired servers: whether each is there (Run on disables one that isn't), and when one
  /// comes back, what's waiting for it. Only asks once there are servers on the list.
  private func watchServers() {
    remoteServers.router = { [tailnet] in tailnet.bridge(to: $0) }
    remoteServers.onServerRemoved = { [weak self] id in self?.remoteStyles.remove(server: id) }
    remoteServers.onServerOnline = { [weak self] id in
      guard let self else { return }
      Task { await self.recoverRemoteJobs() }
      Task { await self.refreshRemoteStyles(server: id) }
      if runTarget == .remote(serverID: id), serverCatalog == nil {
        Task { await self.loadRunTargetCatalog() }
      }
    }
    remoteServers.loadIfNeeded()
    if !remoteServers.servers.isEmpty { remoteServers.startBrowsing() }
    Task { [weak self] in
      await self?.remoteServers.checkStatus()
      if let self {
        await waitUntil { [history] in history.isLoaded }
        await recoverRemoteJobs()
      }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(20))
        guard let self else { return }
        await remoteServers.checkStatus()
      }
    }
  }

  /// Puts jobs sent before this launch back in the queue to be collected: those whose server
  /// answers now, and those whose server isn't paired anymore, which then fail saying so. One
  /// that's merely offline waits for it to come back rather than holding the queue.
  func recoverRemoteJobs() async {
    remoteServers.loadIfNeeded()
    for record in clientJobs.all() {
      let isPaired = remoteServers.name(of: record.serverID) != nil
      guard !isPaired || remoteServers.status(of: record.serverID) == .online, let blank = try? await RemoteBackend.blankConfiguration(for: record.model) else { continue }
      var configuration = ModelDefaults.recommended(for: record.model, configuration: blank)
      SettingsRegistry.apply(dump: record.settings, to: &configuration)
      let sameProject = record.project == history.project.name
      var request = GenerationEngine.Request(
        model: record.model, prompt: record.prompt, negativePrompt: record.negativePrompt, seed: record.seed,
        configuration: configuration)
      request.parentTensorId = sameProject ? record.parentTensorId : nil
      request.canvas = clientJobs.canvas(of: record)
      if request.canvas != nil {
        request.canvasTensorId = sameProject ? record.canvasTensorId : nil
        request.canvasIsImported = record.canvasIsImported
        request.mask = clientJobs.mask(of: record)
        if let merge = record.merge, let source = clientJobs.mergeSource(of: record) {
          request.merge = RefineMerge(record: merge, source: source, sameProject: sameProject)
        }
        request.canvasSourceMask = record.canvasSourceMask.map { mask in
          var mask = mask
          if !sameProject { mask.tensorId = nil }
          return mask
        }
      }
      request.moodboard = clientJobs.moodboard(of: record)
      request.placement = sameProject ? record.placement : nil
      queue.appendResumed(request, id: record.jobID, server: record.serverID)
    }
    runNext()
  }

  /// Jobs sent to servers and not yet saved here.
  @ObservationIgnored var clientJobs = RemoteClientJobs()

  let history: HistoryStore
  /// Generate adds to it; jobs run one at a time, in order.
  let queue = JobQueue()
  /// The project's timelines; runs started from a timeline frame land back on them.
  let timelines: TimelineStore
  /// Set by Continue from Here and Bridge: the next Generate from that frame takes it.
  private var pendingPlacement: TimelinePlacement?
  /// How many images each Generate makes (the ×N beside Generate).
  var count = 1

  var models: [MediaGenerationResolvedModel] = []
  var selectedModel: String? {
    didSet {
      if selectedModel != oldValue, let selectedModel {
        loadDefaults(for: selectedModel)
        // Before the inspector asks, so Strength's hint rarely waits on it.
        startFixedGridCheck(selectedModel)
      }
      // The open layout follows to the new model's format, or closes for one without layouts.
      if selectedModel != oldValue, layout != nil {
        if layoutFormat == nil { closeLayout() } else { writeLayout() }
      }
    }
  }
  /// Where downloads and imports go, and the first folder a model file is looked up in.
  var modelsDirectory = AppSettings.modelsDirectory
  /// More folders models and LoRAs are read from, in lookup order after `modelsDirectory`.
  var additionalModelsDirectories = AppSettings.additionalModelsDirectories
  /// The models folders the engine reads now: the ones above that can be reached, in lookup
  /// order. A folder on a disconnected drive is left out until it's back.
  private(set) var availableModelsDirectories: [String] = []
  /// Called after the models folders are reread (ModelLibrary rereads its LoRAs).
  @ObservationIgnored var onModelsReloaded: (() -> Void)?
  #if os(iOS)
    /// The queue was paused for going to the background, not by the user.
    @ObservationIgnored private var pausedForBackground = false
    @ObservationIgnored private var savedForBackground = false
    @ObservationIgnored private let backgroundTask = BackgroundQueueTask()
    /// The job the background task last reported on, and how many it has finished.
    @ObservationIgnored private var backgroundJob: UUID?
    @ObservationIgnored private var backgroundJobsDone = 0
    /// What the engine was last told about a run being under way (`setEngineGenerating`).
    @ObservationIgnored private var engineIsGenerating = false
  #endif

  var prompt = "" {
    didSet { if prompt != oldValue, !writingLayout { readLayout() } }
  }
  /// The layout being drawn on the canvas, while the Layout editor is open. Every change is
  /// written into the prompt, and a layout prompt typed or pasted there comes back as boxes.
  var layout: LayoutPrompt? {
    didSet { if layout != oldValue, !writingLayout { writeLayout() } }
  }
  /// The box picked on the canvas or in the layout list.
  var selectedLayoutItem: UUID?
  @ObservationIgnored private var writingLayout = false
  var negativePrompt = ""
  /// The user's styles (set by the app).
  var styles: StyleStore? {
    didSet { styles?.reportFailure = { [weak self] in self?.errorMessage = $0 } }
  }
  /// The style Generate writes the prompt into; nil for the prompt as typed. Remembered across
  /// launches, except for what scripted runs set.
  var styleID: UUID? = UserDefaults.standard.string(forKey: "style").flatMap(UUID.init(uuidString:)) {
    didSet {
      if !Automation.isRequested { UserDefaults.standard.set(styleID?.uuidString, forKey: "style") }
    }
  }
  /// What the style's tags other than `SUBJECT` (which is `prompt`) take, by tag. Kept across
  /// style changes, so a tag two styles share keeps its text.
  var styleValues: [String: String] =
    UserDefaults.standard.dictionary(forKey: "styleValues") as? [String: String] ?? [:]
  {
    didSet {
      if !Automation.isRequested { UserDefaults.standard.set(styleValues, forKey: "styleValues") }
    }
  }
  var seed = UInt32.random(in: 0...UInt32.max)
  /// Off means "always random": every Generate rolls a new seed. Only the Random checkbox changes
  /// it; reusing an image, presets and pasted settings bring back a seed but leave this alone.
  /// Remembered across launches, except for what scripted runs set.
  var seedLocked = UserDefaults.standard.bool(forKey: "seedLocked") {
    didSet {
      if !Automation.isRequested { UserDefaults.standard.set(seedLocked, forKey: "seedLocked") }
    }
  }
  /// The inspector's values: every setting the next run uses (the seed lives in `seed`).
  var settings: PipelineConfiguration? {
    didSet {
      // MOSS boxes are in pixels and Ideogram names the aspect ratio: a new size rewrites them.
      if layout != nil, settings?.width != oldValue?.width || settings?.height != oldValue?.height {
        writeLayout()
      }
    }
  }
  /// The selected model's defaults, the baseline for changed markers, reset and presets.
  private(set) var recommended: PipelineConfiguration?
  /// MGK's template plus the app's fallbacks, before the model's default preset.
  private var modelDefaults: PipelineConfiguration?
  /// Source of each model's default preset (set by the app).
  var presets: PresetStore?
  /// The canvas's zoom and position.
  let canvas = CanvasState()
  /// The clip the canvas plays, here so the canvas menu reaches the frame on screen wherever it opens.
  let canvasPlayback = ClipPlayback()
  /// Reference images, sent in both modes to models that take them.
  let moodboard = Moodboard()
  /// The audio file for video models that take one.
  let audio = AudioClip()
  var canvasMode: CanvasMode = CreateModel.storedCanvasMode {
    didSet { UserDefaults.standard.set(canvasMode.rawValue, forKey: "canvasMode") }
  }
  private static var storedCanvasMode: CanvasMode {
    UserDefaults.standard.string(forKey: "canvasMode").flatMap(CanvasMode.init(rawValue:)) ?? .generate
  }
  /// The inpainting mask painted on the canvas image (`CanvasTools.swift` changes it). Each image
  /// remembers the last one it had (`persistCanvasMask`, `restoreCanvasMask`).
  var canvasMask: CanvasMask?
  /// The mask Copy Mask took, with the size of the image it was on, for Paste Mask. Kept in the
  /// app: a mask means nothing to other apps.
  var copiedMask: CopiedMask?
  /// The canvas image whose remembered mask hasn't been brought back yet (it's loading, or its
  /// image is): leaving it with no mask then says nothing about its mask, so it isn't cleared.
  @ObservationIgnored private var maskPendingTensorId: Int64?
  /// The mask the canvas image arrived with (brought back, a result's, or none), so leaving it
  /// unchanged writes nothing.
  @ObservationIgnored private var landedMask: (tensorId: Int64, mask: CanvasMask?)?
  /// The undo targets of the canvas images with mask or Select steps (`registerCanvasUndo`).
  @ObservationIgnored var canvasUndoTargets: [CanvasUndoTarget] = []
  /// Whether the mask paints inside the frame, for the mask and placement it was worked out for
  /// (`screenFrameHasPaint`).
  @ObservationIgnored var frameMaskCache: (key: String, hasPaint: Bool)?
  /// What a drag on the canvas does (on iPad the Pencil always paints and fingers move it).
  var canvasTool = CanvasTool.move
  /// The Select tool's clicks, box and preview (`AutoMaskSession`).
  let autoMask = AutoMaskSession()
  /// The brush's width in frame pixels.
  var brushSize = UserDefaults.standard.object(forKey: "brushSize") as? Double ?? 64 {
    didSet { UserDefaults.standard.set(brushSize, forKey: "brushSize") }
  }
  /// Merge into Image: an Edit run on part of the image, past its edges or with a mask merges
  /// its result back into the whole image (`RefineMerge`) instead of saving the frame alone.
  var mergeIntoImage = UserDefaults.standard.object(forKey: "mergeIntoImage") as? Bool ?? true {
    didSet { UserDefaults.standard.set(mergeIntoImage, forKey: "mergeIntoImage") }
  }
  /// The canvas image came from outside the project (drop, paste, Open), not yet saved as a step.
  private var canvasIsImported = false
  /// The generation settings an imported canvas image carries, with that image.
  private var importedSettings: (image: CGImage, settings: ImageMetadata.Settings)?
  /// Where images picked in the Open panel go; set to show the panel.
  var imageImport: ImageImportTarget?
  /// Where images picked from the photo library go; set to show the picker.
  var photosImport: ImageImportTarget?

  enum ImageImportTarget {
    case canvas, moodboard
  }
  /// Bumped to ask the prompt composer to take focus (⌘L).
  var focusPromptRequest = 0
  /// Set to ask before forgetting the recent prompts (Image ▸ Clear Prompt History…).
  var confirmClearRecentPrompts = false

  private(set) var phase: Phase = .idle
  /// The selected model's defaults are loading (a job may be running meanwhile).
  private(set) var isLoadingModel = false
  private(set) var step = 0
  private(set) var totalSteps = 0
  private(set) var image: CGImage? {
    didSet {
      awaitsStepImage = false
      canvasPlaceholder = nil
      // The detail belongs to the image it was loaded with.
      if image !== canvasDetailImage, !canvasDetail.isEmpty {
        canvasDetail = []
        canvasDetailImage = nil
      }
    }
  }
  /// The canvas image's layers finer than its pixels (a zoomed refine's frame, a Draw Things
  /// upscale; `Project.detailLayers`), in its pixels: the canvas draws them over it where it's
  /// zoomed in, and the next Edit run's frame takes them (`setRefineInputs`). Only with the
  /// image they were loaded for (`loadCanvasDetail`); any other image clears them.
  private(set) var canvasDetail: [Project.DetailLayer] = []
  /// Bumped when an H3 file's schedule has been read (`StrengthSteps.checkFixedGrid`), so
  /// Strength's hint shows; the files being read meanwhile.
  var fixedGridChecks = 0
  @ObservationIgnored var fixedGridsChecking: Set<String> = []
  @ObservationIgnored private var canvasDetailImage: CGImage?
  /// The detail to draw over what the canvas shows: none over a placeholder or preview.
  var canvasDisplayDetail: [Project.DetailLayer] {
    canvasDisplayImage === image && !imageIsPreview ? canvasDetail : []
  }

  /// Loads the detail layers of the step whose image is on the canvas now, `image` loaded from
  /// it, unless another image has taken its place meanwhile. Most steps have none.
  private func loadCanvasDetail(tensorId: Int64, project: String) async {
    guard let shown = image else { return }
    let detail = await history.detailLayers(tensorId: tensorId, in: project)
    guard image === shown, !detail.isEmpty else { return }
    canvasDetailImage = shown
    canvasDetail = detail
  }
  /// The step's stored full-size JPEG, shown in place of `image` while its exact pixels decode
  /// (`showStoredJPEG`). Only for display: everything that uses the canvas image waits for
  /// `image`.
  private(set) var canvasPlaceholder: CGImage?
  /// What the canvas draws: the placeholder while the step's image loads, else `image`.
  var canvasDisplayImage: CGImage? {
    if let canvasPlaceholder, !imageIsPreview { return canvasPlaceholder }
    return image
  }
  /// The running `show` load, cancelled when another image takes its place, so a decode that
  /// hasn't started is skipped (`Project.isCanvasRead`).
  @ObservationIgnored private var showTask: Task<Void, Never>?
  /// `imageStep` changed and its image hasn't landed yet: the canvas still shows the one before,
  /// which is no longer the step's, so nothing is painted or selected on it meanwhile.
  private var awaitsStepImage = false
  /// Set while `projectRenamed` relabels `imageStep`.
  @ObservationIgnored private var relabelsImageStep = false
  /// The canvas image is open full size (`ImageViewer`).
  var viewingCanvasImage = false
  /// The image of the step the last run saved.
  private var lastSavedTensorId: Int64?
  /// The step the last run saved (its number may change when a fork or delete renumbers steps).
  var lastSavedStep: StepID? {
    lastSavedTensorId.flatMap { history.item(tensorId: $0)?.id }
  }
  /// When the running generation started.
  private(set) var runStartedAt: Date?
  /// The first sampling step seen and when, and when the latest one arrived, for the estimate.
  private var samplingStart: (date: Date, step: Int)?
  private var lastStepAt: Date?
  /// Each running local job's phase timings, as its progress arrives (see `GenerationTimings`).
  private var timingRecorders: [UUID: GenerationTimingRecorder] = [:]
  /// The project step behind `image` once it's a finished image (not a step preview), by its
  /// image tensor, which stays the same when steps are renumbered.
  private var imageStep: (project: String, tensorId: Int64)? {
    didSet {
      // A project rename only relabels it (`projectRenamed`).
      guard !relabelsImageStep else { return }
      // Before anything else changes: the size it's kept at comes from what the canvas shows.
      if let oldValue { persistCanvasMask(for: oldValue) }
      // The old image's mask and Select steps leave the history with it, and its selection.
      retireCanvasUndo()
      autoMask.follow(nil)
      awaitsStepImage = imageStep != nil
      landedMask = nil
      maskPendingTensorId = imageStep?.tensorId
      imageIsPreview = false
      showsFrame = false
      canvasImageLoad = nil
      canvasPlaceholder = nil
      showTask?.cancel()
      // The mask belongs to the image it was painted on, which remembers it; the new image's own
      // comes back once it's there (`restoreCanvasMask`). A run whose result merges back puts the
      // source's back on the result, as Draw Things keeps it.
      canvasMask = nil
    }
  }
  /// The load the canvas is waiting on. Decoding a large image (an upscale, say) can take seconds,
  /// with the old image still showing. A newer load, or anything else landing on the canvas,
  /// takes over, so a slow older load can't end the wait for the newer one.
  private var canvasImageLoad: UUID?
  /// The canvas shows a finished image of its own (not a step preview or a playing clip): the one
  /// a mask is painted on.
  var canvasShowsImage: Bool { image != nil && !imageIsPreview && canvasClip == nil }
  /// An image is on its way to the canvas and no preview has taken its place.
  var isLoadingCanvasImage: Bool { canvasImageLoad != nil && !imageIsPreview }
  /// The canvas shows one frame of a clip (`useFrame`), not the clip playing.
  private var showsFrame = false
  /// The canvas shows a step preview, not `imageStep`'s image.
  private var imageIsPreview = false
  var errorMessage: String?
  /// A short note for the status bar, until the next run or Use Settings.
  var statusNote: String?

  private var generationTask: Task<Void, Never>?
  /// An agent's progress and result callbacks, by its job.
  private var agentCallbacks:
    [UUID: (progress: (GenerationEngine.Progress) -> Void, completion: (Result<HistoryItem, Error>) -> Void)] = [:]
  /// The frames a paired device sent to be upscaled, by job.
  private var deviceFrames: [UUID: [CGImage]] = [:]
  /// Paired devices' jobs (`RemoteServer`), which get the output itself instead of a saved step.
  private var deviceCallbacks:
    [UUID: (progress: (GenerationEngine.Progress) -> Void, completion: (Result<GenerationEngine.Output, Error>) -> Void)] = [:]
  /// Where each style thumbnail job's image goes, by its job.
  private var thumbnailCallbacks: [UUID: (Result<CGImage, Error>) -> Void] = [:]
  /// What the canvas held when the running job's first preview covered it, with its placement:
  /// Edit jobs queued meanwhile start from it, not from a preview.
  private var canvasBeforePreview: CanvasSnapshot?
  private var previewCoversCanvas = false
  /// The canvas shows the running job's previews and result. Looking at something else while it
  /// runs (a history image, an imported image, Clear Canvas) stops that until `followRun()` or the
  /// queue empties.
  private(set) var canvasFollowsRun = true
  /// The running job's latest step preview, whether or not the canvas shows it.
  private(set) var livePreview: CGImage?
  /// A video run's latest preview, one image per latent frame (`livePreview` is the first).
  private(set) var livePreviewFrames: [CGImage] = []
  /// The frames the canvas plays while it shows a video run's preview.
  var canvasPreviewFrames: [CGImage] {
    imageIsPreview && canvasFollowsRun ? livePreviewFrames : []
  }
  private var loadTask: Task<Void, Never>?
  /// A history item's configuration dump to apply once the model's defaults finish loading.
  private var pendingSettings: [String: JSONValue]?
  /// The last launch's session, until the model list loads and its model and settings apply.
  private var restored: SessionState?
  /// While a slider drags, its changes share the undo step registered when the drag began.
  private var coalescingEdit = false
  private var generateWhenLoaded = false

  /// The saved history item behind the canvas image, when it's a finished image in the current
  /// project (not a step preview).
  var imageItem: HistoryItem? {
    guard !imageIsPreview, let imageStep, imageStep.project == history.project.name else {
      return nil
    }
    return history.item(tensorId: imageStep.tensorId)
  }

  /// The video the canvas image is a frame of, when it shows one (`useFrame`): only its first
  /// frame is a History item of its own.
  private var canvasFrameClip: HistoryItem? {
    guard !imageIsPreview, let imageStep, imageStep.project == history.project.name else {
      return nil
    }
    return history.clipItem(frame: imageStep.tensorId)
  }

  /// The clip behind the canvas, when it shows a finished video: the canvas plays it.
  var canvasClip: HistoryItem? {
    showsFrame ? nil : imageItem.flatMap { $0.isVideo ? $0 : nil }
  }

  /// The selected model, when it makes video.
  var videoModel: VideoModel? {
    guard let selectedModel else { return nil }
    return VideoModel(model: selectedModel, loras: (settings?.loras ?? []).compactMap(\.file))
  }

  /// Puts one frame of a clip on the canvas as the input of the next run, in Edit mode: the
  /// frame is a step of its own, so the run follows it (from the last frame, it extends the
  /// clip; from any other, it branches there).
  func useFrame(_ index: Int, of item: HistoryItem) {
    guard let frames = item.clip?.frames, frames.indices.contains(index) else { return }
    let tensorId = frames[index]
    let projectName = history.project.name
    statusNote = nil
    pendingPlacement = nil
    stopFollowingRun()
    history.setCurrent(tensorId: tensorId, exact: true)
    canvasIsImported = false
    Task {
      let frame = await whileLoadingCanvasImage { await history.image(tensorId: tensorId, in: projectName) }
      guard let frame else { return }
      imageStep = (projectName, tensorId)
      showsFrame = true
      lastSavedTensorId = nil
      image = frame
      canvas.zoomToFit()
      canvasMode = .edit
      await restoreCanvasMask()
    }
  }

  /// Puts a timeline frame on the canvas as `useFrame` does; the next run from it goes on the
  /// timeline right after that frame. A bridge (MiniMax H3 FL2VA) also puts the next entry's
  /// first frame at the front of the moodboard, as the frame the run ends on, and the run goes
  /// between the two.
  func continueTimeline(
    _ timeline: Timeline, entry: Timeline.Entry, frame: Int, of item: HistoryItem,
    bridgingTo next: (entry: Timeline.Entry, item: HistoryItem)? = nil
  ) {
    guard let frames = item.clip?.frames, frames.indices.contains(frame) else { return }
    useFrame(frame, of: item)
    pendingPlacement = TimelinePlacement(
      project: history.project.name, timeline: timeline.id, entry: entry.id, frame: frame,
      frameTensorId: frames[frame], bridgesTo: next?.entry.id)
    if let next, let nextFrames = next.item.clip?.frames, nextFrames.indices.contains(next.entry.start) {
      let tensorId = nextFrames[next.entry.start]
      let projectName = history.project.name
      Task {
        if let image = await history.image(tensorId: tensorId, in: projectName) {
          moodboard.insert(image, at: 0)
        }
      }
      statusNote = "The next run goes on “\(timeline.name)” between the two clips."
    } else {
      statusNote = "The next run goes on “\(timeline.name)” after this frame."
    }
  }

  /// A job is running or the model's defaults are loading.
  var isBusy: Bool { isRunning || isLoadingModel }

  var isRunning: Bool { phase != .idle }

  /// What quitting now would stop, for asking first; nil when nothing is under way. Jobs held in
  /// a paused queue don't count: they're kept for the next launch.
  var workUnderway: String? {
    var parts: [String] = []
    if let running = queue.running {
      parts.append(
        running.export != nil
          ? "an upscaled export is running"
          : running.request?.colorMatch != nil ? "colors are being matched" : "a generation is running")
    }
    if !queue.isPaused, !queue.waiting.isEmpty {
      parts.append(queue.waiting.count == 1 ? "1 job is queued" : "\(queue.waiting.count) jobs are queued")
    }
    if timelines.isExporting { parts.append("a video is exporting") }
    guard !parts.isEmpty else { return nil }
    let list = parts.formatted(.list(type: .and))
    return list.prefix(1).uppercased() + list.dropFirst() + "."
  }

  /// Generate works while a job runs: it queues the next one. An empty prompt is fine: a model can
  /// run on no text at all, and an edit or a video may need none.
  var canGenerate: Bool {
    !isLoadingModel && selectedModel != nil && settings != nil && runTargetProblem == nil
  }

  var style: Style? { styles?.style(id: styleID) ?? remoteStyles.style(id: styleID) }

  /// Refreshes a server's styles, or every server's.
  func refreshRemoteStyles(server: UUID? = nil) async {
    remoteServers.loadIfNeeded()
    for id in server.map({ [$0] }) ?? remoteServers.servers.map(\.id) {
      await remoteStyles.refresh(server: id, backend: remoteServers.backend(for: id))
    }
  }

  /// Keeps a server's style as this device's own, with a new id so the two stay separate, and its
  /// thumbnail. Returns the copy.
  @discardableResult
  func copyRemoteStyle(_ remote: RemoteStyle, server: UUID) async -> Style? {
    guard let styles else { return nil }
    var copy = remote.style
    copy.id = UUID()
    styles.save(copy)
    let backend = remoteServers.backend(for: server)
    if let full = try? await backend.styleSource(remote.id) {
      styles.setThumbnail(full.image, for: copy.id, source: full.source)
    } else if let image = await remoteStyles.thumbnail(of: remote, server: server, backend: backend) {
      styles.setThumbnail(image, for: copy.id)
    }
    return copy
  }

  /// Why a server's style can't open its thumbnail in Create: its model isn't where jobs go now.
  /// The style itself works with any model, so this is all a missing one affects.
  func remoteStyleProblem(_ remote: RemoteStyle) -> String? {
    guard let model = remote.thumbnailModel, !availableModels.contains(where: { $0.file == model }) else { return nil }
    return "\(model) isn't on \(runTargetServerName ?? Self.thisDeviceName)."
  }

  /// The prompt and negative prompt a run sends: written into the selected style, if any.
  var styledPrompts: (prompt: String, negativePrompt: String) {
    guard let style else { return (prompt, negativePrompt) }
    var values = styleValues
    values[Style.subject] = prompt
    return style.apply(values, negativePrompt: negativePrompt)
  }

  /// Writes the style's tag boxes out as the full prompt and negative prompt in the plain prompt
  /// box, and drops the style, so the whole prompt can be edited. One way: the style isn't put
  /// back, since the edited text no longer fits its template, but Undo right after brings it back.
  func expandStyle(undoManager: UndoManager?) {
    guard style != nil else { return }
    let styled = styledPrompts
    let before = (styleID, prompt, negativePrompt)
    undoManager?.registerUndo(withTarget: self) { model in
      model.styleID = before.0
      model.prompt = before.1
      model.negativePrompt = before.2
    }
    undoManager?.setActionName("Edit Full Prompt")
    styleID = nil
    prompt = styled.prompt
    negativePrompt = styled.negativePrompt
  }

  /// Puts a saved image's prompts on the Create screen. A prompt one of the styles wrote comes
  /// back as its subject with that style selected; any other clears the style, so the prompt
  /// isn't styled twice.
  private func restorePrompts(_ savedPrompt: String, _ savedNegative: String) {
    for style in (styles?.allStyles ?? []) + remoteStyles.all.map(\.style) {
      if let matched = style.match(prompt: savedPrompt, negativePrompt: savedNegative) {
        prompt = matched.values[Style.subject] ?? ""
        negativePrompt = matched.negativePrompt
        styleID = style.id
        for (tag, value) in matched.values where tag != Style.subject { styleValues[tag] = value }
        return
      }
    }
    prompt = savedPrompt
    negativePrompt = savedNegative
    styleID = nil
  }

  var selectedModelInfo: MediaGenerationResolvedModel? {
    availableModels.first { $0.file == selectedModel }
  }

  /// The selected model's layout prompt format; nil when it doesn't read layouts.
  var layoutFormat: LayoutPrompt.Format? { LayoutPrompt.Format(version: selectedModelInfo?.version) }

  /// The size layouts are drawn for: the configured output size.
  var layoutSize: (width: Int, height: Int) {
    guard let settings, settings.width > 0, settings.height > 0 else { return (1024, 1024) }
    return (settings.width, settings.height)
  }

  /// Opens the Layout editor on the prompt's layout, or a new one captioned with the prompt.
  func openLayout() {
    guard let format = layoutFormat else { return }
    let size = layoutSize
    if let read = LayoutPrompt(prompt: prompt, format: format, width: size.width, height: size.height) {
      // The prompt keeps its own formatting until a box changes.
      writingLayout = true
      layout = read
      writingLayout = false
    } else {
      layout = LayoutPrompt(caption: prompt)
    }
  }

  /// Adds a box in the middle of the frame and picks it.
  func addLayoutItem() {
    guard let format = layoutFormat, var layout else { return }
    let kind = format.kinds[0]
    let item = LayoutPrompt.Item(
      name: layout.newName(for: kind), kind: kind, rect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
    layout.items.append(item)
    self.layout = layout
    selectedLayoutItem = item.id
  }

  /// Closes the Layout editor. The prompt keeps the layout it wrote.
  func closeLayout() {
    layout = nil
    selectedLayoutItem = nil
  }

  private func writeLayout() {
    guard let layout, let format = layoutFormat else { return }
    let size = layoutSize
    writingLayout = true
    prompt = layout.prompt(format, width: size.width, height: size.height)
    writingLayout = false
  }

  /// A layout prompt typed, pasted or brought back (Reuse, the recent prompts) while the editor
  /// is open replaces the boxes; other text is left for the next box edit to overwrite.
  private func readLayout() {
    guard layout != nil, let format = layoutFormat else { return }
    let size = layoutSize
    guard var read = LayoutPrompt(prompt: prompt, format: format, width: size.width, height: size.height)
    else { return }
    // Boxes keep their identity by position, so typing in the prompt keeps the selection.
    for (index, item) in (layout?.items ?? []).enumerated() where index < read.items.count {
      read.items[index].id = item.id
    }
    writingLayout = true
    layout = read
    writingLayout = false
    if let selectedLayoutItem, !read.items.contains(where: { $0.id == selectedLayoutItem }) {
      self.selectedLayoutItem = nil
    }
  }

  var traits: ModelTraits { ModelTraits(selectedModelInfo, sampler: settings?.sampler) }

  /// Whether the model (or one of its LoRAs) reads the canvas and moodboard as reference images:
  /// edit models, the FLUX.2 family and Qwen Image 2.1. ModelZoo knows a community model once its
  /// pipeline has loaded.
  var usesReferences: Bool {
    guard let file = selectedModel else { return false }
    if RemoteModelTraits.version(of: file) == .qwenImage2_1 { return true }
    let modifiers =
      [RemoteModelTraits.modifier(of: file)]
        + (settings?.loras ?? []).compactMap(\.file).map(RemoteModelTraits.modifier(ofLoRA:))
    return modifiers.contains {
      switch $0 {
      case .kontext, .kontextKv, .qwenimageEditPlus, .qwenimageEdit2511, .fl2va, .ref2va: true
      default: false
      }
    }
  }

  /// Whether Edit means anything: the model reads the canvas as a reference, Strength is below
  /// 100% so any model starts from it, or a mask is painted (inpainting regenerates it at any
  /// Strength, as in Draw Things).
  var canEdit: Bool {
    usesReferences || videoModel?.needsImage == true || (settings?.strength ?? 1) < 1
      || (videoModel == nil && canvasMask?.mayHavePaint == true)
  }
  /// The mode runs use: Generate while Edit means nothing, keeping the chosen mode for when it does.
  /// A model that only animates an image (LongCat, Stable Video) has no Generate to fall back to.
  var effectiveCanvasMode: CanvasMode {
    if videoModel?.needsImage == true { return .edit }
    return canEdit ? canvasMode : .generate
  }

  /// Puts an image from outside the project on the canvas, fitted to the frame, and switches to
  /// Edit so the next run starts from it. Settings it carries (`metadata`) can then be loaded.
  func setCanvasImage(_ newImage: CGImage, metadata: ImageMetadata.Embedded? = nil) {
    stopFollowingRun()
    imageStep = nil
    lastSavedTensorId = nil
    image = newImage
    canvasIsImported = true
    importedSettings = metadata.flatMap(ImageMetadata.settings(from:)).map { (newImage, $0) }
    if importedSettings != nil {
      statusNote = "This image carries its generation settings: Load Settings from Image applies them."
    }
    canvas.zoomToFit()
    canvasMode = .edit
  }

  /// Empties the canvas (Generate mode then has nothing to show it with).
  func clearCanvas() {
    stopFollowingRun()
    imageStep = nil
    lastSavedTensorId = nil
    image = nil
    canvasIsImported = false
    canvas.zoomToFit()
  }

  /// Sets the output size to the canvas image's, in whole 64-pixel units.
  func matchSizeToImage(undoManager: UndoManager?) {
    guard let image, let descriptor = SettingsRegistry.byID["size"] else { return }
    func units(_ value: Int) -> Int { max(Int((Double(value) / 64).rounded()), 1) * 64 }
    set(
      descriptor,
      to: .object(["width": .number(Double(units(image.width))), "height": .number(Double(units(image.height)))]),
      undoManager: undoManager)
    canvas.zoomToFit()
  }

  func addCanvasToMoodboard() {
    if let image { moodboard.add(image) }
  }

  func pasteImage() {
    if let data = Clipboard.imageData, let image = ImageLoader.image(from: data) {
      setCanvasImage(image, metadata: ImageMetadata.embedded(in: data))
    } else if let url = Clipboard.fileURL, let image = ImageLoader.image(at: url) {
      setCanvasImage(image, metadata: ImageMetadata.embedded(at: url))
    }
  }

  /// Images chosen in the Open panel: one for the canvas, any number for the moodboard.
  func importImages(_ urls: [URL], into target: ImageImportTarget) {
    for url in urls {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      guard let image = ImageLoader.image(at: url) else { continue }
      if target == .moodboard {
        moodboard.add(image)
      } else {
        setCanvasImage(image, metadata: ImageMetadata.embedded(at: url))
      }
    }
  }

  /// Images picked from the photo library: one for the canvas, any number for the moodboard.
  func importPhotos(_ photos: [Data], failed: Int, into target: ImageImportTarget) {
    var failed = failed
    for data in photos {
      guard let image = ImageLoader.image(from: data) else {
        failed += 1
        continue
      }
      if target == .moodboard {
        moodboard.add(image)
      } else {
        setCanvasImage(image, metadata: ImageMetadata.embedded(in: data))
      }
    }
    if failed > 0 { errorMessage = "Couldn't load \(failed == 1 ? "the photo" : "\(failed) photos")." }
  }

  /// The generation settings behind the canvas image: those an imported image carries, while it's
  /// the image they came with, else its History step's sidecar (an image made here), so Load
  /// Settings from Image can bring them back after the inspector changed. A video frame on the
  /// canvas (`useFrame`, any frame) has the video's settings, from the clip's item, which History
  /// lists by its first frame. A playing clip is left to the video's own menu (`ClipPlayer`).
  var canvasImageSettings: ImageMetadata.Settings? {
    if let importedSettings, importedSettings.image === image { return importedSettings.settings }
    if canvasClip == nil, let sidecar = (imageItem ?? canvasFrameClip)?.sidecar, !sidecar.configuration.isEmpty {
      return ImageMetadata.settings(from: sidecar)
    }
    return nil
  }

  /// How the canvas image was made, when that's known: its History step, or the settings an
  /// imported image carries. Kept with a style thumbnail taken from the canvas.
  var canvasThumbnailSource: ThumbnailSource? {
    if let sidecar = imageItem?.sidecar {
      return ThumbnailSource(
        prompt: sidecar.prompt, negativePrompt: sidecar.negativePrompt, model: sidecar.model,
        seed: sidecar.seed, settings: sidecar.configuration)
    }
    return canvasImageSettings.map(ThumbnailSource.init)
  }

  /// Opens a style thumbnail: its image on the canvas, and its model, settings, seed and prompts
  /// (with its style and tag text, when one of the styles wrote the prompt). Generate or Edit
  /// stays as it was.
  func openThumbnail(_ image: CGImage, source: ThumbnailSource, undoManager: UndoManager?) {
    let mode = canvasMode
    setCanvasImage(image)
    canvasMode = mode
    importedSettings = (image, source.metadata)
    loadCanvasImageSettings(undoManager: undoManager)
  }

  /// Loads the prompts, model, seed and settings the canvas image carries, like Paste Settings
  /// plus the prompts. The Random checkbox stays as it is.
  func loadCanvasImageSettings(undoManager: UndoManager?) {
    guard let loaded = canvasImageSettings else { return }
    restorePrompts(loaded.prompt, loaded.negativePrompt)
    errorMessage = nil
    statusNote = nil
    paste(loaded.pasted, undoManager: undoManager)
    if let file = loaded.pasted.model, !availableModels.contains(where: { $0.file == file }) {
      statusNote = "\(file) isn't downloaded, so its settings apply to the current model."
    }
  }

  private(set) var modelFiles: [String] = []

  var settingContext: SettingContext {
    SettingContext(models: availableModels, files: availableFiles)
  }

  /// The file a refiner/upscaler checkbox turns on: the one last picked if still offered, else the
  /// first offered.
  func enableFile(for descriptor: SettingDescriptor) -> String? {
    guard case .file(let source) = descriptor.control else { return nil }
    let files = source(settingContext).compactMap { option -> String? in
      if case .string(let file) = option.value { return file }
      return nil
    }
    let last = UserDefaults.standard.string(forKey: "lastFile." + descriptor.id)
    return files.first { $0 == last } ?? files.first
  }

  init(history: HistoryStore) {
    self.history = history
    timelines = TimelineStore(history: history)
    defer { moodboard.reportFailure = { [weak self] in self?.errorMessage = $0 } }
    if let session = SessionState.load() {
      restored = session
      prompt = session.prompt
      negativePrompt = session.negativePrompt
      if let seed = session.seed { self.seed = seed }
      if let project = session.imageProject,
         session.imageTensorId != nil || session.imageStep != nil
      {
        Task {
          let loaded: (tensorId: Int64, image: CGImage)? = await whileLoadingCanvasImage {
            var tensorId = session.imageTensorId
            if tensorId == nil, let step = session.imageStep {
              tensorId = await history.tensorId(at: step, in: project)
            }
            guard let tensorId, let image = await history.image(tensorId: tensorId, in: project) else { return nil }
            return (tensorId, image)
          }
          guard let (tensorId, restoredImage) = loaded, image == nil else { return }
          await restoreSessionImage(restoredImage, tensorId: tensorId, project: project)
        }
      }
    }
    AppLifecycle.onWillTerminate { [weak self] in self?.saveSession() }
    AppLifecycle.onResignActive { [weak self] in self?.saveSession() }
    AppLifecycle.onWillTerminate { [weak self] in self?.saveQueue() }
    #if os(iOS)
      backgroundTask.onStart = { [weak self] in self?.backgroundTaskStarted() }
      backgroundTask.onExpire = { [weak self] in self?.backgroundTaskExpired() }
      // The request has to come from the foreground, and the system's display shows from then on, so
      // it's made at the last moment and the task ends on return. Control Center and the like come
      // through here too: the display just shows until the app is active again.
      AppLifecycle.onResignActive { [weak self] in
        guard let self, let job = queue.running else { return }
        let text = backgroundTaskText(for: job)
        backgroundTask.begin(title: text.title, subtitle: text.subtitle)
      }
      AppLifecycle.onBecomeActive { [weak self] in self?.backgroundTask.end() }
      // iPadOS stops GPU work in the background, unless a background task is running: hold the
      // queue there and pick it up on return (or when the task starts, if that's later).
      AppLifecycle.onEnterBackground { [weak self] in
        guard let self else { return }
        // iPadOS can end the app from here on, without warning.
        saveQueue()
        savedForBackground = true
        guard !queue.isPaused, !backgroundTask.isRunning else { return }
        pausedForBackground = true
        setQueuePaused(true)
      }
      AppLifecycle.onEnterForeground { [weak self] in
        guard let self else { return }
        // Still running: what was saved would come back at the next launch as well. Not at launch,
        // which also comes through here, when what was saved is yet to be restored.
        if savedForBackground, SessionState.isEnabled { SavedQueue.save([], project: history.project.name) }
        savedForBackground = false
        guard pausedForBackground else { return }
        pausedForBackground = false
        setQueuePaused(false)
      }
    #endif
    Task {
      await reloadModels()
      await restoreQueue()
    }
    AppLifecycle.onBecomeActive { [weak self] in
      Task { await self?.checkModelsDirectories() }
    }
    if SessionState.isEnabled {
      let session = restored
      watchServers()
      if let session { restoreRunTarget(from: session) }
    }
    // Notices a drive with a models folder being connected or disconnected.
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self else { return }
        await checkModelsDirectories()
      }
    }
  }

  /// Keeps the running and waiting jobs for the next launch (not for scripted runs).
  private func saveQueue() {
    guard SessionState.isEnabled else { return }
    SavedQueue.save(queue.unfinished, project: history.project.name)
    // Finished jobs' copies only served Run Again, which doesn't outlast the app.
    AudioClip.removeSnapshots(keeping: queue.unfinished.compactMap { $0.request?.audio })
  }

  /// Brings back the jobs kept at the last quit, paused. Jobs for models no longer downloaded
  /// are dropped.
  private func restoreQueue() async {
    guard SessionState.isEnabled else { return }
    await waitUntil { [history] in history.isLoaded }
    let requests = await savedRequests(SavedQueue.load(project: history.project.name))
    AudioClip.removeSnapshots(keeping: requests.compactMap(\.audio))
    guard !requests.isEmpty else { return }
    queue.isPaused = true
    queue.append(requests, currentTensorId: history.currentTensorId)
  }

  /// Saved jobs' requests, their settings put back on their models' defaults. A Match Colors to
  /// Original job never loads its model, so it stays when the model is gone, on the current
  /// settings instead.
  func savedRequests(_ saved: [SavedQueue.Job]) async -> [GenerationEngine.Request] {
    var defaults: [String: PipelineConfiguration] = [:]
    var requests: [GenerationEngine.Request] = []
    for job in saved {
      let downloaded = models.contains(where: { $0.file == job.model })
      guard downloaded || job.colorMatch != nil else { continue }
      if downloaded, defaults[job.model] == nil, let configuration = try? await engine.loadPipeline(for: job.model) {
        defaults[job.model] = ModelDefaults.recommended(for: job.model, configuration: configuration)
      }
      guard var configuration = defaults[job.model] ?? (job.colorMatch != nil ? settings : nil) else { continue }
      SettingsRegistry.apply(dump: job.settings, to: &configuration)
      requests.append(job.request(configuration: configuration))
    }
    return requests
  }

  /// Remembers the model, prompts, seed, inspector values and canvas image for the next launch.
  func saveSession() {
    // The canvas image's mask, so it's there after a relaunch too.
    rememberCanvasMask()
    // Until the models load, the last session's model and settings are still waiting to apply.
    guard restored == nil else { return }
    SessionState(
      model: selectedModel, prompt: prompt, negativePrompt: negativePrompt, seed: seed,
      settings: settings.map(JSONValue.fields(of:)) ?? pendingSettings,
      imageProject: imageStep?.project,
      imageStep: imageStep.flatMap { history.tree.step(tensorId: $0.tensorId) },
      imageTensorId: imageStep?.tensorId,
      runTarget: runTarget
    ).save()
  }

  /// Whether `item`'s model is downloaded, so its settings can be loaded here.
  func canUse(_ item: HistoryItem) -> Bool {
    !isBusy && !item.sidecar.configuration.isEmpty
      && availableModels.contains { $0.file == item.sidecar.model }
  }

  /// Loads a history item's prompt, model, seed and settings into Create, and with `loadImage` its
  /// image onto the canvas (an Edit step's input instead, with `restoreInput`). With `newSeed`,
  /// rolls a fresh seed and generates as soon as the model is ready.
  func use(
    _ item: HistoryItem, newSeed: Bool = false, loadImage: Bool = true, restoreInput: Bool = true,
    undoManager: UndoManager? = nil
  ) {
    guard canUse(item) else { return }
    if newSeed { rerunUndoManager = undoManager }
    let sidecar = item.sidecar
    restorePrompts(sidecar.prompt, sidecar.negativePrompt)
    errorMessage = nil
    if newSeed {
      rollSeed()
    } else {
      seed = sidecar.seed
    }
    statusNote = nil
    let projectName = history.project.name
    if loadImage {
      stopFollowingRun()
      imageStep = (projectName, item.tensorId)
      history.setCurrent(tensorId: item.tensorId)
      canvasIsImported = false
      // A new image starts fitted to the frame (the model places every image it puts there).
      canvas.zoomToFit()
    }
    // An Edit step brings back its input, fitted, in Edit mode, so rerunning reproduces it.
    // Without its input (deleted since) it shows the result, as for a Generate step.
    let restoreImage = Task {
      guard loadImage else { return }
      if restoreInput, item.inputTensorId != nil {
        if let input = await whileLoadingCanvasImage({ await history.input(of: item, in: projectName) }),
           let inputTensorId = item.inputTensorId
        {
          guard imageStep?.tensorId == item.tensorId else { return }
          // The input becomes the current step, so a rerun branches beside this one.
          imageStep = (projectName, inputTensorId)
          history.setCurrent(tensorId: inputTensorId)
          image = input.image
          Task { await loadCanvasDetail(tensorId: inputTensorId, project: projectName) }
          if let refine = item.sidecar.refine, refine.offset.count == 2 {
            // A refined region merged back: the frame on that region again, with its mask.
            let offset = CGSize(width: refine.offset[0], height: refine.offset[1])
            canvas.scale = refine.scale
            canvas.offset = offset
            // The run's own mask, to reproduce it, rather than what the input had last.
            canvasMask = refine.mask
            maskPendingTensorId = nil
          } else {
            canvas.zoomToFit()
            await restoreCanvasMask()
          }
          canvasMode = .edit
          return
        }
        guard imageStep?.tensorId == item.tensorId else { return }
        statusNote = "The image this was made from is no longer in the project."
      }
      let full = await whileLoadingCanvasImage { await history.image(at: item.id, in: projectName) }
      if let full, imageStep?.tensorId == item.tensorId {
        image = full
        await restoreCanvasMask()
        await loadCanvasDetail(tensorId: item.tensorId, project: projectName)
      } else if full == nil, imageStep?.tensorId == item.tensorId {
        canvasImageDidNotLoad("This image couldn't be read from the project.")
      }
    }
    let restoreMoodboard = Task {
      let references = await history.moodboard(at: item.id, in: projectName)
      moodboard.replace(with: references)
      // A video run's audio file comes back too.
      if let samples = await history.audioInput(of: item),
         let rate = VideoModel(model: item.sidecar.model)?.audioSampleRate
      {
        let failure = Log.attempt(Log.create, "Bringing back a run's audio") {
          try audio.set(samples: samples, sampleRate: rate, name: "Audio from \(history.fileName(for: item)).wav")
        }
        if let failure { errorMessage = "Couldn't bring back the audio: \(failure.localizedDescription)" }
      }
    }
    if selectedModel == sidecar.model, !isLoadingModel, var settings = recommended {
      SettingsRegistry.apply(dump: sidecar.configuration, to: &settings)
      self.settings = settings
      if newSeed {
        Task {
          await restoreMoodboard.value
          await restoreImage.value
          generate(undoManager: rerunUndoManager)
        }
      }
    } else {
      pendingSettings = sidecar.configuration
      generateWhenLoaded = newSeed
      if selectedModel == sidecar.model {
        loadDefaults(for: sidecar.model)
      } else {
        selectedModel = sidecar.model
      }
    }
  }

  #if os(iOS)
    /// Back to the models folder in the app's Documents, forgetting a picked one.
    func useDefaultModelsDirectory() {
      FolderBookmarks.forget(modelsDirectory)
      AppSettings.useDefaultModelsDirectory()
      modelsDirectory = AppSettings.modelsDirectory
      FolderBookmarks.keepOpen(allModelsDirectories)
      Task { await reloadModels() }
    }
  #endif

  func setModelsDirectory(_ directory: String) {
    AppSettings.modelsDirectory = directory
    modelsDirectory = directory
    FolderBookmarks.keepOpen(allModelsDirectories)
    Task { await reloadModels() }
  }

  func setAdditionalModelsDirectories(_ directories: [String]) {
    AppSettings.additionalModelsDirectories = directories
    additionalModelsDirectories = directories
    FolderBookmarks.keepOpen(allModelsDirectories)
    Task { await reloadModels() }
  }

  private var allModelsDirectories: [String] { [modelsDirectory] + additionalModelsDirectories }

  /// The models folders that can be reached now. Checked off the main thread: a folder on a
  /// drive that's going away can take a while to answer.
  private func reachableModelsDirectories() async -> [String] {
    let primary = modelsDirectory
    let additional = additionalModelsDirectories
    return await Self.availableModelsDirectories(primary: primary, additional: additional)
  }

  @concurrent private nonisolated static func availableModelsDirectories(
    primary: String, additional: [String]
  ) async -> [String] {
    AppSettings.availableModelsDirectories(primary: primary, additional: additional)
  }

  /// Rereads the models when a models folder has come or gone since the last read.
  private var isReloadingModels = false
  private func checkModelsDirectories() async {
    guard !isReloadingModels else { return }
    let reachable = await reachableModelsDirectories()
    if reachable != availableModelsDirectories, !isReloadingModels {
      await reloadModels()
    }
  }

  func reloadModels() async {
    isReloadingModels = true
    defer { isReloadingModels = false }
    let directories = await reachableModelsDirectories()
    availableModelsDirectories = directories
    // SAM 2.1 may be in, or go to, another folder now.
    SAMDownload.shared.refresh()
    await engine.setModelsDirectories(directories)
    await loadModelList()
    onModelsReloaded?()
    // The pickers are on a server's models: this device's changing doesn't touch them.
    guard runTarget == .local else { return }
    if let restored, let model = restored.model, models.contains(where: { $0.file == model }) {
      self.restored = nil
      pendingSettings = restored.settings
      selectedModel = model
      return
    }
    restored = nil
    // The model picked before its folder's drive went away comes back with the drive, unless
    // another model was picked meanwhile.
    if let lost = modelLostWithFolder, models.contains(where: { $0.file == lost.model }) {
      modelLostWithFolder = nil
      if selectedModel == lost.replacement {
        selectedModel = lost.model
        return
      }
    }
    if let selectedModel, models.contains(where: { $0.file == selectedModel }) {
      loadDefaults(for: selectedModel)
    } else {
      if let selectedModel { modelLostWithFolder = (selectedModel, models.first?.file) }
      selectedModel = models.first?.file
    }
  }

  /// The selected model when it went missing on a reload, and the one picked in its place.
  @ObservationIgnored private var modelLostWithFolder: (model: String, replacement: String?)?

  /// Rereads the downloaded models after a download or delete, keeping the current settings
  /// unless the selected model is gone.
  func refreshModelList() async {
    await loadModelList()
    guard runTarget == .local else { return }
    if selectedModel == nil || !models.contains(where: { $0.file == selectedModel }) {
      selectedModel = models.first?.file
    }
  }

  @concurrent private nonisolated static func fileNames(in directories: [String]) async -> [String] {
    Set(directories.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] })
      .sorted()
  }

  private func loadModelList() async {
    let models = await backend(for: .local).downloadedModels()
    let directories = availableModelsDirectories
    let modelFiles = await Self.fileNames(in: directories)
    // Assigned after the last await, so callers pick a selection before the model picker redraws.
    self.models = models
    self.modelFiles = modelFiles
  }

  // MARK: - Settings

  func value(_ descriptor: SettingDescriptor) -> JSONValue? {
    settings.map(descriptor.get)
  }

  func defaultValue(_ descriptor: SettingDescriptor) -> JSONValue? {
    recommended.map(descriptor.get)
  }

  func isChanged(_ descriptor: SettingDescriptor) -> Bool {
    guard let settings, let recommended else { return false }
    return descriptor.get(settings) != descriptor.get(recommended)
  }

  /// Settings that differ from the model's defaults, in registry order.
  var changedSettings: [SettingDescriptor] {
    SettingsRegistry.all.filter(isChanged)
  }

  func set(_ descriptor: SettingDescriptor, to value: JSONValue, undoManager: UndoManager?) {
    guard var settings else { return }
    let before = settings
    descriptor.set(&settings, value)
    guard descriptor.get(settings) != descriptor.get(before) else { return }
    if case .file = descriptor.control, case .string(let file) = value {
      UserDefaults.standard.set(file, forKey: "lastFile." + descriptor.id)
    }
    // Text fields keep their own typing undo.
    if !coalescingEdit, !isText(descriptor) {
      registerUndo(restoring: before, undoManager, actionName: "Change \(descriptor.title)")
    }
    self.settings = settings
  }

  func reset(_ descriptor: SettingDescriptor, undoManager: UndoManager?) {
    guard let recommended else { return }
    set(descriptor, to: descriptor.get(recommended), undoManager: undoManager)
  }

  func resetToModelDefaults(undoManager: UndoManager?) {
    guard let recommended, let settings else { return }
    registerUndo(restoring: settings, undoManager, actionName: "Reset to Model Defaults")
    self.settings = recommended
  }

  /// The model's defaults with its default preset (if any) applied on top.
  private func withDefaultPreset(_ base: PipelineConfiguration, for model: String)
    -> PipelineConfiguration
  {
    var configuration = base
    for (id, value) in presets?.defaultPreset(for: model)?.values ?? [:] {
      SettingsRegistry.byID[id]?.set(&configuration, value)
    }
    return configuration
  }

  /// Makes `preset` (or none) the selected model's default preset. The baseline for changed
  /// markers and reset moves with it; the current values stay as they are.
  func setDefaultPreset(_ preset: Preset?) {
    guard let selectedModel, let presets else { return }
    presets.setDefault(preset, for: selectedModel)
    if let modelDefaults, modelDefaults.model == settings?.model {
      recommended = withDefaultPreset(modelDefaults, for: selectedModel)
    }
  }

  /// Applies a preset on top of the model's defaults; settings it doesn't name keep the defaults.
  /// A preset for another downloaded model switches to that model first, then applies on top of
  /// its defaults (and its default preset) once they load. One whose model isn't here changes
  /// nothing: its values were saved for that model, so they don't go on whatever's selected.
  func apply(_ preset: Preset, undoManager: UndoManager?) {
    if let model = preset.model, model != selectedModel {
      guard availableModels.contains(where: { $0.file == model }) else {
        errorMessage = "“\(preset.name)” is for \(model), which isn't available."
        return
      }
      pendingSettings = DrawThingsJSON.Pasted(preset).dump
      selectedModel = model
      return
    }
    guard var configuration = recommended, let settings else { return }
    for (id, value) in preset.values {
      SettingsRegistry.byID[id]?.set(&configuration, value)
    }
    registerUndo(restoring: settings, undoManager, actionName: "Apply Preset “\(preset.name)”")
    self.settings = configuration
  }

  /// Every setting as Draw Things configuration JSON, with the model and seed, for its Paste.
  func settingsJSON() -> Data? {
    guard settings != nil, let model = selectedModel else { return nil }
    return DrawThingsJSON.encode(
      values(for: SettingsRegistry.all.map(\.id)), model: model, seed: seed)
  }

  /// Applies pasted settings on top of the model defaults, like a preset. A pasted model that's
  /// downloaded is switched to first; a pasted seed is kept for the following generations.
  func paste(_ pasted: DrawThingsJSON.Pasted, undoManager: UndoManager?) {
    if let seed = pasted.seed { self.seed = seed }
    if let model = pasted.model, model != selectedModel, availableModels.contains(where: { $0.file == model }) {
      pendingSettings = pasted.dump
      selectedModel = model
      return
    }
    guard var configuration = recommended, let settings else { return }
    SettingsRegistry.apply(dump: pasted.dump, to: &configuration)
    registerUndo(restoring: settings, undoManager, actionName: "Paste Settings")
    self.settings = configuration
  }

  /// Replaces the inspector's values as one undo step, for an agent's edits. Undo goes back to
  /// `restoring` (by default the values now): an agent that applied a preset without undo first
  /// makes the preset and its edits one step.
  func replaceSettings(
    with configuration: PipelineConfiguration, restoring: PipelineConfiguration? = nil, actionName: String,
    undoManager: UndoManager?
  ) {
    guard let settings else { return }
    registerUndo(restoring: restoring ?? settings, undoManager, actionName: actionName)
    self.settings = configuration
  }

  /// Returns once a model switch has loaded the new model's defaults into the inspector.
  func modelLoaded() async {
    await loadTask?.value
  }

  /// Current values of `ids`, for saving a preset.
  func values(for ids: [String]) -> [String: JSONValue] {
    guard let settings else { return [:] }
    var values: [String: JSONValue] = [:]
    for id in ids {
      if let descriptor = SettingsRegistry.byID[id] { values[id] = descriptor.get(settings) }
    }
    return values
  }

  /// Starts a slider drag: one undo step for the whole drag.
  func beginCoalescedEdit(_ descriptor: SettingDescriptor, undoManager: UndoManager?) {
    guard let settings, !coalescingEdit else { return }
    registerUndo(restoring: settings, undoManager, actionName: "Change \(descriptor.title)")
    coalescingEdit = true
  }

  func endCoalescedEdit() {
    coalescingEdit = false
  }

  private func isText(_ descriptor: SettingDescriptor) -> Bool {
    if case .text = descriptor.control { return true }
    return false
  }

  private func registerUndo(
    restoring snapshot: PipelineConfiguration, _ undoManager: UndoManager?, actionName: String
  ) {
    guard let undoManager else { return }
    undoManager.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        // A snapshot from another model no longer applies.
        guard let current = target.settings, current.model == snapshot.model else { return }
        target.registerUndo(restoring: current, undoManager, actionName: actionName)
        target.settings = snapshot
      }
    }
    undoManager.setActionName(actionName)
  }

  func rollSeed() {
    seed = UInt32.random(in: 0...UInt32.max)
  }

  /// The request Generate would queue now, from the Create screen: the model, styled prompts,
  /// seed, settings, moodboard, and in Edit mode the canvas frame (with its mask, and how to merge
  /// the result back, see `setRefineInputs`). Agents start from it too. Nil without a model or
  /// settings. The seed is the screen's; Generate rolls or counts it per image.
  func screenRequest() -> GenerationEngine.Request? {
    guard let model = selectedModel, let settings else { return nil }
    // Each job snapshots the settings, canvas and moodboard, so edits made after queuing it apply
    // to the next one.
    let styled = styledPrompts
    var base = GenerationEngine.Request(
      model: model, prompt: styled.prompt, negativePrompt: styled.negativePrompt, seed: seed,
      configuration: settings)
    // A clip playing on the canvas isn't an input: Use Last Frame as Input picks a frame.
    if effectiveCanvasMode == .edit, canvasClip == nil, let source = canvasSource {
      let step = !source.isImported && !source.isPreview && source.step?.project == history.project.name
        ? source.step?.tensorId : nil
      // Video models take the frame as is: they refuse a mask, and a clip has nothing to merge into.
      let refines = videoModel == nil
      base.setRefineInputs(
        source: source.image, sourceTensorId: step, isImported: source.isImported, scale: source.scale,
        offset: source.offset, mask: refines && runTargetTakesMasks ? canvasMask : nil,
        merge: refines && mergeIntoImage, detail: source.detail)
      // The image remembers its mask even when this run can't take it (a video model, an older
      // server).
      base.canvasSourceMask = canvasMask.map {
        CanvasSourceMask(tensorId: step, width: Double(source.image.width), height: Double(source.image.height), mask: $0)
      }
      if let pending = pendingPlacement, source.step?.tensorId == pending.frameTensorId,
         source.step?.project == pending.project, !source.isPreview
      {
        base.placement = pending
        pendingPlacement = nil
      }
    }
    if usesReferences { base.moodboard = moodboard.references }
    return base
  }

  /// Queues `count` images of the prompt; runs right away when nothing else is. A Select
  /// selection not yet put into the mask goes in first, as Add does (`addPendingSelection`):
  /// leaving it out would surprise. One still being worked out is waited for (`waitsForSelection`,
  /// which holds Generate meanwhile); the run then takes the prompt and settings as they are when
  /// the selection goes in. It's dropped, with a note, if the canvas image or Edit mode changes
  /// during the wait.
  func generate(undoManager: UndoManager? = nil) {
    guard canGenerate, !waitsForSelection else { return }
    let undoManager = undoManager ?? rerunUndoManager ?? Self.windowUndoManager
    guard hasPendingSelection, autoMask.isBusy else {
      let note = addPendingSelection(undoManager: undoManager)
      queueGeneration()
      if let note { statusNote = note }
      return
    }
    let waitedImage = image, waitedMode = canvasMode
    waitsForSelection = true
    statusNote = "Adding the selection…"
    Task {
      let settled = await settlePendingSelection()
      waitsForSelection = false
      if statusNote == "Adding the selection…" { statusNote = nil }
      guard image === waitedImage, canvasMode == waitedMode else {
        statusNote = "The run was cancelled because the canvas changed while its selection was being worked out."
        return
      }
      guard canGenerate else {
        statusNote = "The run didn't start: \(runTargetProblem ?? "there's no model or settings to run with now")."
        return
      }
      let note = settled ? addPendingSelection(undoManager: undoManager) : Self.selectionTimedOutNote
      queueGeneration()
      if let note { statusNote = note }
    }
  }

  /// Generate is waiting for a Select selection to be worked out, to add it first: Generate is
  /// disabled meanwhile, so a second press doesn't queue a second run.
  private(set) var waitsForSelection = false
  /// The undo manager of the view that asked for a rerun (Rerun with New Seed), for its
  /// selection's undo step once the model loads.
  @ObservationIgnored weak var rerunUndoManager: UndoManager?
  /// How long Generate waits for a selection before running without it.
  static let selectionWait: Duration = .seconds(30)
  static let selectionTimedOutNote = "The selection took too long to work out, so the run went without it."

  /// Generate can be pressed now (the button and ⌘↩).
  var canPressGenerate: Bool { canGenerate && !waitsForSelection }

  /// The window's undo manager, for runs started without one at hand (Use Settings' rerun).
  static var windowUndoManager: UndoManager? {
    #if os(macOS)
      AgentTools.mainWindowUndoManager
    #else
      nil
    #endif
  }

  /// The Select tool has a selection (or one being worked out) that isn't in the mask, on the
  /// image an Edit run would take. In Edit as the user set it: at Strength 100% Edit only takes
  /// effect with a mask, which this is about to make.
  /// A selection that failed counts too (its points still there), so the run says it went without
  /// it.
  var hasPendingSelection: Bool {
    guard canvasMode == .edit, videoModel == nil, canvasClip == nil, let image else { return false }
    if let preview = autoMask.preview { return preview.image === image }
    return autoMask.image === image && (autoMask.isBusy || (autoMask.failure != nil && !autoMask.prompt.isEmpty))
  }

  /// Waits for a selection still being worked out (SAM's decoder, or the image's first encoding),
  /// at most `selectionWait`. False when it gave up: the wait was cancelled (an agent's call) or
  /// ran out of time.
  func settlePendingSelection() async -> Bool {
    let deadline = ContinuousClock.now + Self.selectionWait
    while autoMask.isBusy {
      guard !Task.isCancelled, ContinuousClock.now < deadline,
            (try? await Task.sleep(for: .milliseconds(20))) != nil
      else { return false }
    }
    return true
  }

  /// Puts a waiting Select selection into the mask, as Add does: one “Add Selection” undo step,
  /// the points cleared. Returns a status note when there was one to add and it couldn't be: it
  /// failed or selects nothing (the run goes without it). Where the mask can't be painted (an
  /// older server), it's left alone and Generate follows the usual rules for masks.
  @discardableResult
  func addPendingSelection(undoManager: UndoManager?) -> String? {
    guard hasPendingSelection, !autoMask.isBusy else { return nil }
    guard let preview = autoMask.preview, preview.stroke != nil else {
      let reason = autoMask.failure.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? "it selects nothing"
      return "The selection wasn't added to the mask: \(reason). The run went without it."
    }
    guard canPaintMask else { return nil }
    commitAutoMaskPreview(mode: .add, undoManager: undoManager)
    return nil
  }

  /// Queues the run from the screen as it is now.
  private func queueGeneration() {
    guard canGenerate, let base = screenRequest() else { return }
    // The canvas image remembers the mask it's queued with now, not when the run is saved (the
    // mask may have changed, or been cleared, by then).
    rememberCanvasMask()
    statusNote = nil
    let takesAudio = videoModel?.takesAudio == true && audio.url != nil
    remember(prompt: prompt)
    // Always random rolls a seed per image; a set seed counts up from itself, as in Draw Things.
    let firstSeed = seed
    let requests = (0..<max(count, 1)).map { index in
      if !seedLocked { rollSeed() }
      var request = base
      request.seed = seedLocked ? firstSeed &+ UInt32(index) : seed
      if takesAudio { request.audio = audio.snapshot() }
      return request
    }
    queue.append(requests, currentTensorId: history.currentTensorId, target: runTarget)
    runNext()
    // After `runNext`, which clears the message as a job starts.
    if takesAudio, requests.contains(where: { $0.audio == nil }) {
      errorMessage = "Couldn't copy the audio file, so a queued video runs without it."
    }
  }

  /// The canvas as a run would take it.
  private struct CanvasSnapshot {
    var image: CGImage
    /// `canvasDetail`, with the image it's for.
    var detail: [Project.DetailLayer]
    var step: (project: String, tensorId: Int64)?
    var isImported: Bool
    var isPreview: Bool
    var scale: Double?
    var offset: CGSize
  }

  /// The canvas Edit runs start from: while a preview covers it, what it held before.
  private var canvasSource: CanvasSnapshot? {
    if previewCoversCanvas { return canvasBeforePreview }
    return image.map {
      CanvasSnapshot(
        image: $0, detail: canvasDetail, step: imageStep, isImported: canvasIsImported, isPreview: imageIsPreview,
        scale: canvas.scale, offset: canvas.offset)
    }
  }

  /// Queues an agent's request (AgentTools) like Generate: progress, previews and the result show
  /// on the canvas and in the status bar, and Stop or the Queue cancel it. The prompt, inspector
  /// and moodboard are left alone. Cancelling the caller cancels the job. `target` defaults to
  /// this device for its own models; a request taken from the screen (`screenRequest`) passes
  /// Run on, so it runs where Generate would.
  func generate(
    forAgent request: GenerationEngine.Request, target: JobTarget? = nil,
    progress: @escaping (GenerationEngine.Progress) -> Void
  ) async throws -> HistoryItem {
    // A model only the selected server has runs there; any other runs on this device, as agents
    // choose among this device's models.
    let target = target ?? (models.contains(where: { $0.file == request.model }) ? JobTarget.local : runTarget)
    let id = queue.append([request], currentTensorId: history.currentTensorId, target: target, fromAgent: true)[0]
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        agentCallbacks[id] = (progress, { continuation.resume(with: $0) })
        runNext()
      }
    } onCancel: {
      Task { @MainActor in self.cancel(id) }
    }
  }

  /// Queues a paired device's request (`RemoteServer`), labelled with its name. Progress shows in
  /// the status bar but never on the canvas, and the output goes to `completion` rather than into
  /// the project. Returns the job's id, for `cancel(_:)`.
  func runForDevice(
    _ request: GenerationEngine.Request, frames: [CGImage] = [], device: String,
    progress: @escaping (GenerationEngine.Progress) -> Void,
    completion: @escaping (Result<GenerationEngine.Output, Error>) -> Void
  ) -> UUID {
    let id = queue.append(request, remoteDevice: device)
    deviceCallbacks[id] = (progress, completion)
    deviceFrames[id] = frames
    runNext()
    return id
  }

  /// Queues `request` for `target`, for scripted checks that need inputs Generate takes from the
  /// screen.
  func queueForCheck(_ request: GenerationEngine.Request, target: JobTarget) {
    queue.append([request], currentTensorId: history.currentTensorId, target: target)
    runNext()
  }

  /// Starts what can start: the next job for this device when none is running, and the next for
  /// each server not running one.
  private func runNext() {
    #if os(iOS)
      // A job can end after the app went to the background: don't bring it back at the next launch.
      defer { if savedForBackground { saveQueue() } }
    #endif
    defer { syncBackgroundTask() }
    for job in queue.startRemote() { run(job) }
    if let job = queue.startNext() { run(job) }
  }

  /// Keeps the background task in step with the queue. Called as jobs start and end and as they
  /// make progress.
  private func syncBackgroundTask() {
    #if os(iOS)
      if (queue.running != nil) != engineIsGenerating, GenerationEngine.setEngineGenerating(!engineIsGenerating) {
        engineIsGenerating.toggle()
      }
      guard let job = queue.running else {
        backgroundTask.end()
        backgroundJob = nil
        backgroundJobsDone = 0
        return
      }
      if job.id != backgroundJob {
        if backgroundJob != nil { backgroundJobsDone += 1 }
        backgroundJob = job.id
      }
      let text = backgroundTaskText(for: job)
      let jobs = backgroundJobsDone + 1 + (queue.isPaused ? 0 : localJobsWaiting)
      let fraction = Double(step) / Double(max(totalSteps, 1))
      backgroundTask.update(
        completed: (Double(backgroundJobsDone) + min(fraction, 1)) / Double(jobs), title: text.title,
        subtitle: text.subtitle)
    #endif
  }

  #if os(iOS)
    /// The background task is about GPU work here; a job on a server needs none.
    private var localJobsWaiting: Int { queue.waiting.count { $0.target == .local } }

    /// What the system's display says about the queue.
    private func backgroundTaskText(for job: JobQueue.Job) -> (title: String, subtitle: String) {
      let title =
        if job.export != nil {
          "Exporting a video"
        } else if job.request?.colorMatch != nil {
          "Matching colors"
        } else if job.request?.configuration.videoModel != nil {
          "Generating a video"
        } else {
          "Generating images"
        }
      let jobs = backgroundJobsDone + 1 + (queue.isPaused ? 0 : localJobsWaiting)
      let subtitle =
        jobs > 1 ? "\(backgroundJobsDone + 1) of \(jobs)" : "Step \(step) of \(max(totalSteps, step))"
      return (title, subtitle)
    }

    /// The task can start after the app already went to the background and held the queue.
    private func backgroundTaskStarted() {
      syncBackgroundTask()
      guard pausedForBackground else { return }
      pausedForBackground = false
      setQueuePaused(false)
    }

    /// The system ended the background task: hold the queue as if the app had gone to the
    /// background without one, with the running generation back in front to run again. In the
    /// foreground the user may have stopped it from the system's display, so it stays paused
    /// until they resume it.
    private func backgroundTaskExpired() {
      if !AppLifecycle.isActive { pausedForBackground = true }
      queue.isPaused = true
      // A job on a server has nothing to stop here, and carries on there.
      guard queue.running != nil else { return }
      queue.returnRunningToFront()
      cancel()
    }
  #endif

  /// A running job's progress, for the Queue. The status bar and canvas show one run at a time, the
  /// foreground one (`foregroundJobID`), which is what the shared state below describes; jobs on
  /// servers also keep their own here, so one can take over when the foreground run ends.
  struct RunProgress {
    var message = "Preparing…"
    var step = 0
    var totalSteps = 0
    var preview: CGImage?
    var previewFrames: [CGImage] = []
    var transfer: (title: String, fraction: Double)?
    var startedAt = Date()
  }

  private(set) var remoteRuns: [UUID: RunProgress] = [:]
  /// The run the status bar, canvas and Stop are about: the one on this device, else a server's.
  private(set) var foregroundJobID: UUID?
  private var runTasks: [UUID: Task<Void, Never>] = [:]

  func runProgress(of job: JobQueue.Job) -> RunProgress? {
    if job.id == foregroundJobID {
      var progress = RunProgress(step: step, totalSteps: totalSteps, preview: livePreview, previewFrames: livePreviewFrames, transfer: transfer)
      if let runStartedAt { progress.startedAt = runStartedAt }
      return progress
    }
    return remoteRuns[job.id]
  }

  /// Sets up a run's progress, taking the foreground if it's this device's or nothing else has it.
  private func beginRun(_ job: JobQueue.Job, message: String, totalSteps: Int, startedAt: Date = Date()) {
    if job.target != .local {
      remoteRuns[job.id] = RunProgress(message: message, totalSteps: totalSteps, startedAt: startedAt)
    }
    guard job.target == .local || foregroundJobID == nil else { return }
    foregroundJobID = job.id
    errorMessage = nil
    phase = .running(message)
    transfer = nil
    step = 0
    self.totalSteps = totalSteps
    runStartedAt = startedAt
    samplingStart = nil
    lastStepAt = nil
  }

  private func setRunMessage(_ message: String, _ job: JobQueue.Job) {
    if job.target != .local { remoteRuns[job.id]?.message = message }
    if job.id == foregroundJobID { phase = .running(message) }
  }

  /// A task for `job`, which `cancel` reaches. Assigned before the task's body can run: both are on
  /// the main actor.
  private func track(_ task: Task<Void, Never>, for job: JobQueue.Job) {
    runTasks[job.id] = task
    if job.id == foregroundJobID { generationTask = task }
  }

  /// Records a remote run's progress under its own id.
  private func noteRemoteProgress(_ progress: GenerationEngine.Progress, _ job: JobQueue.Job) {
    guard job.target != .local, var run = remoteRuns[job.id] else { return }
    switch progress {
    case .preview(let preview, let step, let total):
      run.preview = preview
      run.previewFrames = []
      run.step = step
      run.totalSteps = total
    case .previewFrames(let frames, let step, let total):
      run.preview = frames.first
      run.previewFrames = frames
      run.step = step
      run.totalSteps = total
    case .state(let state):
      run.message = Self.describe(state)
      run.transfer = Self.transfer(in: state)
      if case .generating(let step, let total) = state {
        run.step = step
        run.totalSteps = total
      }
    }
    remoteRuns[job.id] = run
  }

  private static func transfer(in state: MediaGenerationPipeline.State) -> (title: String, fraction: Double)? {
    switch state {
    case .uploading(let sent, let total): (title: "Uploading", fraction: total > 0 ? Double(sent) / Double(total) : 0)
    case .downloading(let received, let total): (title: "Downloading", fraction: total > 0 ? Double(received) / Double(total) : 0)
    default: nil
    }
  }

  /// With nothing in the foreground, the status bar and canvas go to a job still on a server.
  private func adoptRemoteRun() {
    guard foregroundJobID == nil, let job = queue.runningRemote.first, let run = remoteRuns[job.id] else { return }
    foregroundJobID = job.id
    generationTask = runTasks[job.id]
    phase = .running(run.message)
    transfer = run.transfer
    step = run.step
    totalSteps = run.totalSteps
    runStartedAt = run.startedAt
    samplingStart = nil
    lastStepAt = nil
    livePreview = run.preview
    livePreviewFrames = run.previewFrames
    if canvasFollowsRun, let preview = run.preview { coverCanvas(with: preview) }
  }

  /// Saves one result at a time. Results from servers arrive whenever they're ready, alongside a
  /// local run's, and saving reads and writes the project's steps across several awaits.
  private var saving: Task<Void, Never>?

  private func oneSaveAtATime<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
    let previous = saving
    let task = Task { @MainActor in
      await previous?.value
      return try await work()
    }
    saving = Task { _ = try? await task.value }
    return try await task.value
  }

  private func run(_ job: JobQueue.Job) {
    if let export = job.export { return run(export, job: job) }
    guard let request = job.request else { return }
    if let match = request.colorMatch { return run(match, request: request, job: job) }
    let startedAt = Date()
    beginRun(job, message: "Preparing…", totalSteps: request.configuration.steps, startedAt: startedAt)
    let backend = self.backend(for: job.target)
    // Style thumbnails and agents answer callers a quit ends, so there's nothing to come back to.
    // An upscale's output still needs its soundtrack from the source clip here.
    let keepsRemoteJob = job.target != .local && job.styleThumbnail == nil && !job.fromAgent && request.upscale == nil
    let task = Task {
      var status = JobQueue.Job.Status.cancelled
      var inputTensorId: Int64?
      var tipTensorId: Int64?
      do {
        timingRecorders[job.id] = GenerationTimingRecorder(startedAt: startedAt)
        let progress: @Sendable (GenerationEngine.Progress) -> Void = { progress in
          let arrived = Date()
          Task { @MainActor in
            if case .state(let state) = progress { self.timingRecorders[job.id]?.note(state, at: arrived) }
            self.noteRemoteProgress(progress, job)
            if job.id == self.foregroundJobID {
              self.handle(progress, showsOnCanvas: job.remoteDevice == nil)
            }
            self.agentCallbacks[job.id]?.progress(progress)
            self.deviceCallbacks[job.id]?.progress(progress)
          }
        }
        var output: GenerationEngine.Output
        if let imageUpscale = request.imageUpscale, let image = request.canvas {
          setRunMessage("Upscaling…", job)
          output = try await upscaled(image: image, as: imageUpscale, request: request, progress: progress)
        } else if job.remoteDevice != nil, request.upscale != nil {
          // A device's frames came with its job; its source clip isn't in any project here.
          output = try await backend.upscale(request, frames: deviceFrames.removeValue(forKey: job.id) ?? [], progress: progress)
        } else if let upscale = request.upscale {
          output = try await upscaled(request, upscale, job: job, on: backend, progress: progress)
        } else if let remote = backend as? RemoteBackend, keepsRemoteJob, case .remote(let server) = job.target {
          // Kept until it's saved below, so a quit in between loses nothing.
          if job.resumesRemoteJob {
            output = try await remote.resume(job: job.id, progress: progress)
          } else {
            await clientJobs.add(request, job: job.id, server: server, project: history.project.name)
            output = try await remote.generate(request, job: job.id, acknowledges: false, progress: progress)
          }
        } else {
          output = try await backend.generate(request, progress: progress)
        }
        // A paired device's job goes back to it, not into the project.
        if job.remoteDevice != nil {
          status = .ranForDevice
          deviceCallbacks.removeValue(forKey: job.id)?.completion(.success(output))
          finish(job, status: status)
          return
        }
        // A style thumbnail goes back to the Styles screen, not into the project.
        if job.styleThumbnail != nil {
          guard let made = output.frames.first.flatMap(ImageTensor.cgImage(from:)) else {
            throw CocoaError(.fileWriteUnknown)
          }
          status = .madeThumbnail
          thumbnailCallbacks.removeValue(forKey: job.id)?(.success(made))
          finish(job, status: status)
          return
        }
        // A refined region goes back into the image it came from, here, where its project is.
        var refined: RefinedStep?
        var mergedOrigin: CGPoint?
        if let merge = request.merge, !output.isVideo, let frame = output.frames.first {
          setRunMessage("Merging into the image…", job)
          let merged = try await CanvasMerge.merged(
            frame, into: merge, input: request.canvas, maskBlur: Double(request.configuration.maskBlur),
            maskBlurOutset: request.configuration.maskBlurOutset)
          output.frames = [merged.tensor]
          refined = merged.step
          mergedOrigin = merged.sourceOrigin
        }
        let returnedAt = Date()
        // Runs on a server report the server's states, so their timings would mislead.
        var timings = job.target == .local ? timingRecorders[job.id]?.timings(returnedAt: returnedAt) : nil
        if output.isVideo { setRunMessage("Saving \(output.frames.count) frames…", job) }
        let followsRun = { self.canvasFollowsRun && job.id == self.foregroundJobID }
        let history = history
        // The mask painted on the source stays with the result, moved as the image grew.
        let keptMask = mergedOrigin.flatMap { origin in request.merge?.canvasMask?.translated(by: origin) }
        let item = try await oneSaveAtATime {
          try await history.save(
            output, request: request, startedAt: startedAt, finishedAt: Date(), timings: timings,
            refined: refined, resultMask: keptMask, makeCurrent: followsRun)
        }
        if timings != nil {
          timings?.save = Date().timeIntervalSince(returnedAt)
          timings?.total = Date().timeIntervalSince(startedAt)
          queue.setTimings(timings, id: job.id)
        }
        lastSavedTensorId = item.tensorId
        // A merged refine shows as its project shows it: its whole canvas, transparent where empty.
        let finished = refined?.composite ?? output.frames.first.flatMap(ImageTensor.cgImage(from:))
          ?? runProgress(of: job)?.preview
        if followsRun() {
          imageStep = (history.project.name, item.tensorId)
          // The result takes the preview's place: the image beneath it is the run's input, no
          // longer the canvas's (its mask and Select steps went with the step change above).
          canvasBeforePreview = nil
          previewCoversCanvas = false
          canvasIsImported = false
          if let finished { image = finished }
          if let merge = request.merge, let mergedOrigin, let finished {
            keepRefinePlacement(
              merge: merge, sourceOrigin: mergedOrigin, resultSize: CGSize(width: finished.width, height: finished.height))
            canvasMask = keptMask
          } else {
            canvas.zoomToFit()
          }
          if finished == nil { canvasImageDidNotLoad("The result couldn't be shown.") }
          // Saved with it just now (or none, for a result that isn't merged).
          landedMask = (item.tensorId, canvasMask)
          maskPendingTensorId = nil
          // Its own frame, or the detail carried from its source, whatever the zoom.
          if refined?.layers != nil {
            await loadCanvasDetail(tensorId: item.tensorId, project: history.project.name)
          }
        }
        if let placement = request.placement, item.isVideo { timelines.place(item, at: placement) }
        if let failure = await history.writeToOutputFolder(item, image: finished) {
          errorMessage = failure
        }
        saveSession()
        FinishedNotice.post(
          prompt: request.prompt, seconds: item.sidecar.durationSeconds, isVideo: item.isVideo)
        status = .finished(tensorId: item.tensorId)
        inputTensorId = item.inputTensorId
        tipTensorId = item.clip?.frames.last
        agentCallbacks.removeValue(forKey: job.id)?.completion(.success(item))
        if keepsRemoteJob, let remote = backend as? RemoteBackend {
          clientJobs.remove(job.id)
          // The server keeps a clip's frames a while, so upscaling it there needn't send them back.
          if output.isVideo, case .remote(let server) = job.target {
            clientJobs.rememberClip(tensorId: item.tensorId, project: history.project.name, server: server, job: job.id)
          }
          await remote.acknowledge(job: job.id)
        }
      } catch is CancellationError {
        // Stopped; keep the last preview on the canvas (when it's showing the run).
        agentCallbacks.removeValue(forKey: job.id)?.completion(.failure(CancellationError()))
        thumbnailCallbacks.removeValue(forKey: job.id)?(.failure(CancellationError()))
        deviceCallbacks.removeValue(forKey: job.id)?.completion(.failure(CancellationError()))
        if keepsRemoteJob { clientJobs.remove(job.id) }
      } catch {
        // A paired device's failure is reported to it, not as an error on this screen.
        if job.remoteDevice == nil { errorMessage = error.localizedDescription }
        status = .failed(error.localizedDescription)
        if keepsRemoteJob { clientJobs.remove(job.id) }
        agentCallbacks.removeValue(forKey: job.id)?.completion(.failure(error))
        thumbnailCallbacks.removeValue(forKey: job.id)?(.failure(error))
        deviceCallbacks.removeValue(forKey: job.id)?.completion(.failure(error))
      }
      finish(job, status: status, inputTensorId: inputTensorId, tipTensorId: tipTensorId)
    }
    track(task, for: job)
  }

  /// Ends the running job and starts the next.
  private func finish(
    _ job: JobQueue.Job, status: JobQueue.Job.Status, inputTensorId: Int64? = nil, tipTensorId: Int64? = nil,
    inOpenProject: Bool = true
  ) {
    queue.finishRunning(status, id: job.id, inputTensorId: inputTensorId, tipTensorId: tipTensorId, inOpenProject: inOpenProject)
    timingRecorders[job.id] = nil
    remoteRuns[job.id] = nil
    runTasks[job.id] = nil
    deviceFrames[job.id] = nil
    // Another run's ending doesn't touch what the status bar and canvas are showing.
    guard job.id == foregroundJobID else { return runNext() }
    foregroundJobID = nil
    phase = .idle
    transfer = nil
    generationTask = nil
    runStartedAt = nil
    canvasBeforePreview = nil
    previewCoversCanvas = false
    livePreview = nil
    livePreviewFrames = []
    runNext()
    adoptRemoteRun()
    // Once the queue is empty, the next run shows on the canvas again.
    if generationTask == nil { canvasFollowsRun = true }
  }

  /// Queues a style thumbnail (StyleStore) like Generate, with progress and previews in the status
  /// bar, and returns its image. It isn't saved to the project. Cancelling the caller cancels
  /// the job.
  func generateStyleThumbnail(_ request: GenerationEngine.Request, style: String) async throws -> CGImage {
    let id = queue.append([request], currentTensorId: history.currentTensorId, target: runTarget, styleThumbnail: style)[0]
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        thumbnailCallbacks[id] = { continuation.resume(with: $0) }
        runNext()
      }
    } onCancel: {
      Task { @MainActor in self.cancel(id) }
    }
  }

  /// Queues an upscaled timeline export, after what's already queued.
  func queue(_ export: TimelineExportJob) {
    queue.append(export, target: runTarget)
    runNext()
  }

  /// Runs an export job, its progress in the status bar like a generation's.
  private func run(_ export: TimelineExportJob, job: JobQueue.Job) {
    beginRun(job, message: "Exporting “\(export.title)” upscaled…", totalSteps: 1_000)
    let backend = backend(for: job.target)
    let task = Task {
      var status = JobQueue.Job.Status.cancelled
      do {
        try await export.run(backend: backend) { fraction in
          Task { @MainActor in
            self.remoteRuns[job.id]?.step = Int(fraction * 1_000)
            guard job.id == self.foregroundJobID, self.phase != .cancelling else { return }
            self.step = Int(fraction * 1_000)
            self.syncBackgroundTask()
          }
        }
        status = .exported(export.destination)
      } catch is CancellationError {
        export.discardPlaceholder()
      } catch {
        export.discardPlaceholder()
        if (error as? AVError)?.code != .operationCancelled {
          errorMessage = "Couldn't export: \(error.localizedDescription)"
          status = .failed(error.localizedDescription)
        }
      }
      finish(job, status: status)
    }
    track(task, for: job)
  }

  /// Queues upscaling `item`, a clip, `scale` times with `method` (FlashVSR+ as `variant`). The
  /// result is a new clip after it, with its model, prompt, seed and settings at the new size.
  func upscale(
    _ item: HistoryItem, method: ClipUpscale.Method, scale: Int,
    variant: FlashVSRFiles.Variant = .turbo, frameLimit: Int? = nil
  ) async {
    guard item.isVideo else { return }
    let sidecar = item.sidecar
    let model = sidecar.model
    var configuration: PipelineConfiguration
    let target = runTarget
    if let loaded = try? await backend(for: target).loadPipeline(for: model) {
      configuration = ModelDefaults.recommended(for: model, configuration: loaded)
    } else if let settings {
      configuration = settings
    } else {
      return
    }
    SettingsRegistry.apply(dump: sidecar.configuration, to: &configuration)
    let size = ClipUpscale.outputSize(
      width: sidecar.width, height: sidecar.height, scale: scale, method: method)
    configuration.width = size.width
    configuration.height = size.height
    var request = GenerationEngine.Request(
      model: model, prompt: sidecar.prompt, negativePrompt: sidecar.negativePrompt,
      seed: sidecar.seed, configuration: configuration)
    request.parentTensorId = HistoryStore.tip(of: item)
    request.upscale = ClipUpscale(
      method: method, scale: scale, sourceTensorId: item.tensorId, frameLimit: frameLimit,
      variant: method == .flashVSR ? variant : nil)
    statusNote = nil
    queue.append([request], currentTensorId: history.currentTensorId, target: target)
    runNext()
  }

  /// Upscale… on the canvas image is choosing how.
  var upscalingCanvasImage = false

  /// Whether the canvas holds an image Upscale… can take: a finished one, not a playing video.
  var canUpscaleCanvasImage: Bool { image != nil && !imageIsPreview && canvasClip == nil }

  /// Queues upscaling the canvas image. The result is a new History entry after it.
  func upscaleCanvasImage(_ upscale: ImageUpscale) {
    guard canUpscaleCanvasImage, let image else { return }
    self.upscale(image: image, item: imageItem, as: upscale)
  }

  /// Queues upscaling `image`, which is `item` when it's a saved image; a frame of a video or an
  /// imported image has no settings of its own to carry, and goes after the current step.
  func upscale(image: CGImage, item: HistoryItem?, as upscale: ImageUpscale) {
    let source = item?.isVideo == true ? nil : item
    guard var configuration = settings, let model = source?.sidecar.model ?? selectedModel else { return }
    if let source { SettingsRegistry.apply(dump: source.sidecar.configuration, to: &configuration) }
    let size = upscale.outputSize(width: image.width, height: image.height)
    configuration.width = size.width
    configuration.height = size.height
    var request = GenerationEngine.Request(
      model: model, prompt: source?.sidecar.prompt ?? "", negativePrompt: source?.sidecar.negativePrompt ?? "",
      seed: source?.sidecar.seed ?? seed, configuration: configuration)
    request.canvas = image
    request.canvasIsImported = source == nil
    request.canvasTensorId = source?.tensorId
    request.parentTensorId = source.map(HistoryStore.tip(of:))
    request.imageUpscale = upscale
    statusNote = nil
    queue.append([request], currentTensorId: history.currentTensorId, target: .local)
    runNext()
  }

  // MARK: - Match Colors to Original

  /// Whether Match Colors to Original can take the canvas: a finished image saved in the project
  /// (not a video) that has an original to match, and that isn't waiting or being matched already
  /// (matching it twice would make the same image).
  var canMatchCanvasColors: Bool {
    guard canOpenMatchColors, let item = imageItem else { return false }
    return pendingColorMatch(for: item) == nil
  }

  /// The step the Match Colors… sheet (`ColorMatchSheet`) is open for. The sheet keeps it: the
  /// canvas can change while it's open.
  var colorMatchSheetItem: HistoryItem?

  /// Whether Match Colors… can open for the canvas: a finished image saved in the project (not a
  /// video) that has an original to match. A match already waiting or running doesn't keep it
  /// shut, since the sheet can queue one with other settings.
  var canOpenMatchColors: Bool {
    guard canvasShowsImage, let item = imageItem else { return false }
    return hasOriginal(item)
  }

  /// The waiting or running Match Colors to Original job for `item`, a step of the current
  /// project, with the same settings as `options` (by default the one-click item's).
  func pendingColorMatch(for item: HistoryItem, options: ColorMatch.Options = ColorMatch.Options()) -> JobQueue.Job? {
    queue.pendingColorMatch(colorMatchJob(for: item, options: options))
  }

  /// Its settings in whole percents, so the same ones always make the same job (`isSameMatch`).
  private func colorMatchJob(for item: HistoryItem, options: ColorMatch.Options) -> ColorMatch.Job {
    ColorMatch.Job(project: history.project.name, sourceTensorId: item.tensorId, options: options.snapped)
  }

  /// What the Match Colors… sheet previews `item` with: the step and its original, read and
  /// measured as the job does (`run(_:request:job:)`); nil when either can't be read. `read`
  /// hears the original as soon as it's read, before the measuring, which takes longer: the
  /// sheet shows it meanwhile.
  func colorMatchPreview(for item: HistoryItem, read: (CGImage) -> Void = { _ in }) async -> ColorMatch.Preview? {
    let project = history.project
    guard let original = await originalImage(for: item, in: project) else { return nil }
    read(original.image)
    guard let edited = await project.read({ $0.image(tensorId: item.tensorId) }) else { return nil }
    return await ColorMatch.Preview.make(edited: edited, original: original.image)
  }

  /// Whether a step has an image its colors can be matched to (see `originalImage(for:)`). A
  /// moodboard counts only with an image of weight above 0, the one `originalImage` would take.
  func hasOriginal(_ item: HistoryItem) -> Bool {
    !item.isVideo && (item.sidecar.colorMatch != nil || item.inputTensorId != nil || item.weightedMoodboardCount > 0)
  }

  /// The image an edit was made from: a Match Colors result's own original, else the step's input
  /// (the canvas it was edited from), else its first moodboard image with weight. The parent isn't
  /// used: a step that took no canvas wasn't made from it. Also says which tensor it is (nil for a
  /// moodboard image), which the result records, and the moodboard image to carry along. Read from
  /// `project`, the step's own, which by default is the current one.
  func originalImage(for item: HistoryItem, in project: Project? = nil) async -> (
    image: CGImage, tensorId: Int64?, moodboard: GenerationEngine.Reference?
  )? {
    guard !item.isVideo else { return nil }
    let project = project ?? history.project
    func firstMoodboardImage() async -> (image: CGImage, tensorId: Int64?, moodboard: GenerationEngine.Reference?)? {
      guard item.weightedMoodboardCount > 0,
            let entry = await project.read({ $0.moodboard(at: item.id) }).first(where: { $0.weight > 0 })
      else { return nil }
      return (entry.image, nil, GenerationEngine.Reference(image: entry.image, weight: entry.weight))
    }
    // Matching a match again goes back to its original, not to the image it was matched from.
    if let record = item.sidecar.colorMatch {
      if let tensorId = record.originalTensorId {
        return await project.read { $0.image(tensorId: tensorId) }.map { ($0, tensorId, nil) }
      }
      return await firstMoodboardImage()
    }
    if let tensorId = item.inputTensorId {
      if let input = await project.read({ $0.input(of: item.id, tensorId: tensorId) }) { return (input.image, tensorId, nil) }
      if let image = await project.read({ $0.image(tensorId: tensorId) }) { return (image, tensorId, nil) }
    }
    return await firstMoodboardImage()
  }

  /// Queues matching `item`'s colors to its original's (`ColorMatch`), a step of the current
  /// project. It runs on this device whatever Run on says (it needs no model or GPU), in turn with
  /// the other jobs, and saves into that project even if another is open by then
  /// (`run(_:request:job:)`). Returns the job's id: the one already waiting or running for the
  /// same step with the same settings when there is one, since a second would make the same
  /// image. Other settings make another image, so they queue beside it.
  @discardableResult
  func queueColorMatch(_ item: HistoryItem, options: ColorMatch.Options = ColorMatch.Options(), fromAgent: Bool = false) throws
    -> UUID
  {
    guard !item.isVideo else { throw ColorMatchError.video }
    guard hasOriginal(item) else { throw ColorMatchError.noOriginal }
    let match = colorMatchJob(for: item, options: options)
    if let pending = queue.pendingColorMatch(match) { return pending.id }
    guard var configuration = settings else { throw ColorMatchError.noSettings }
    // Its settings, as an upscale carries them; the size is the step's own.
    SettingsRegistry.apply(dump: item.sidecar.configuration, to: &configuration)
    var request = GenerationEngine.Request(
      model: item.sidecar.model, prompt: item.sidecar.prompt, negativePrompt: item.sidecar.negativePrompt,
      seed: item.sidecar.seed, configuration: configuration)
    request.parentTensorId = HistoryStore.tip(of: item)
    request.colorMatch = match
    statusNote = nil
    let id = queue.append([request], currentTensorId: history.currentTensorId, target: .local, fromAgent: fromAgent)[0]
    runNext()
    return id
  }

  /// Match Colors to Original on the canvas image, with the default options.
  func matchCanvasColors() {
    guard canMatchCanvasColors, let item = imageItem else { return }
    do {
      try queueColorMatch(item)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Match Colors… on `item` with the sheet's settings.
  func matchColors(_ item: HistoryItem, options: ColorMatch.Options) {
    do {
      try queueColorMatch(item, options: options)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Queues a match for an agent (AgentTools), or joins the one already waiting or running for the
  /// step with the same settings, and returns the step it saved. `progress` hears the step (of 1,000) and what it's
  /// doing. Cancelling the caller cancels the job.
  func matchColors(
    forAgent item: HistoryItem, options: ColorMatch.Options, progress: @escaping (Int, String) -> Void
  ) async throws -> HistoryItem {
    let pending = pendingColorMatch(for: item, options: options)?.id
    let id = try queueColorMatch(item, options: options, fromAgent: true)
    // A match someone else queued (the canvas menu) is theirs: giving up on it only ends this wait.
    let joined = id == pending
    return try await withTaskCancellationHandler {
      try await colorMatchResult(of: id, progress: progress)
    } onCancel: {
      if !joined { Task { @MainActor in self.cancel(id) } }
    }
  }

  /// Waits for Match Colors job `id` to end, and returns the step it saved, read from its own project.
  private func colorMatchResult(of id: UUID, progress: (Int, String) -> Void) async throws -> HistoryItem {
    var reported: (Int, String)?
    while true {
      if let job = queue.recent.first(where: { $0.id == id }) {
        switch job.status {
        case .finished(let tensorId):
          guard let name = job.request?.colorMatch?.project, let project = history.project(named: name) else {
            throw ColorMatchError.unreadable
          }
          if project === history.project, let item = history.item(tensorId: tensorId) { return item }
          let tree = await project.read { $0.tree() }
          guard let item = tree.step(tensorId: tensorId).flatMap({ tree.items[$0] }) else { throw ColorMatchError.unreadable }
          return item
        case .failed(let message): throw ColorMatchError.failed(message)
        default: throw CancellationError()
        }
      }
      if let job = queue.running, job.id == id, let run = runProgress(of: job) {
        let message = if case .running(let message) = phase { message } else { "Matching colors" }
        if reported?.0 != run.step || reported?.1 != message {
          reported = (run.step, message)
          progress(run.step, message)
        }
      } else if !queue.waiting.contains(where: { $0.id == id }) {
        // Taken off the lists without ending here (Clear Finished, say).
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Runs a Match Colors to Original job on this device: reads the step and its original from the
  /// job's own project, matches off the main actor with progress (step out of 1,000, as an export
  /// reports), and saves the result as a new step after it with its settings. Into the open
  /// project it saves as a generation does, showing on the canvas when that follows the queue;
  /// into another it saves through `HistoryStore.project(named:)` and leaves the screen alone, so
  /// the step is there when that project is opened.
  private func run(_ match: ColorMatch.Job, request queued: GenerationEngine.Request, job: JobQueue.Job) {
    let startedAt = Date()
    beginRun(job, message: "Reading images…", totalSteps: 1_000, startedAt: startedAt)
    let task = Task {
      var status = JobQueue.Job.Status.cancelled
      var inputTensorId: Int64?
      var inOpenProject = true
      do {
        guard let project = history.project(named: match.project), project.isOpen else {
          throw ColorMatchError.projectMissing(match.project)
        }
        let item: HistoryItem
        if project === history.project, let listed = history.item(tensorId: match.sourceTensorId) {
          item = listed
        } else {
          let tree = await project.read { $0.tree() }
          guard let found = tree.step(tensorId: match.sourceTensorId).flatMap({ tree.items[$0] }) else {
            throw ColorMatchError.stepMissing(match.project)
          }
          item = found
        }
        guard !item.isVideo else { throw ColorMatchError.video }
        guard let original = await originalImage(for: item, in: project) else { throw ColorMatchError.noOriginal }
        guard let edited = await project.read({ $0.image(tensorId: item.tensorId) }) else { throw ColorMatchError.unreadable }
        try Task.checkCancellation()
        setRunMessage("Measuring colors…", job)
        let report: @Sendable (Double) -> Void = { fraction in
          Task { @MainActor in
            guard job.id == self.foregroundJobID, self.phase != .cancelling else { return }
            self.step = Int(fraction * 950)
            self.syncBackgroundTask()
          }
        }
        guard let result = try await ColorMatch.matching(edited, to: original.image, options: match.options, progress: report),
              let tensor = ImageTensor.tensor(from: result.image)
        else { throw ColorMatchError.unreadable }
        try Task.checkCancellation()
        setRunMessage("Saving…", job)
        if job.id == foregroundJobID { step = 950 }
        let matched = result.image
        let shift = result.shift
        var request = queued
        SettingsRegistry.apply(dump: item.sidecar.configuration, to: &request.configuration)
        request.configuration.width = matched.width
        request.configuration.height = matched.height
        request.canvas = edited
        request.canvasTensorId = item.tensorId
        request.canvasIsImported = false
        request.parentTensorId = HistoryStore.tip(of: item)
        // A moodboard original goes along, so matching the result again finds it there.
        request.moodboard = original.moodboard.map { [$0] } ?? []
        let record = ColorMatch.Record(
          options: match.options, counted: result.counted, originalTensorId: original.tensorId, shift: shift)
        request.colorMatch?.record = record
        let followsRun = { self.canvasFollowsRun && job.id == self.foregroundJobID && project === self.history.project }
        let history = history
        let saved = try await oneSaveAtATime {
          // A rename since it started closed the project it read from (`renameCurrent`): saving
          // there would write to a closed file.
          guard history.project(named: match.project) === project, project.isOpen else {
            throw ColorMatchError.projectMissing(match.project)
          }
          return try await history.save(
            GenerationEngine.Output(frames: [tensor]), request: request, startedAt: startedAt, finishedAt: Date(),
            into: project, makeCurrent: followsRun)
        }
        queue.setColorMatchRecord(record, id: job.id)
        if job.id == foregroundJobID { step = 1_000 }
        if project === history.project {
          lastSavedTensorId = saved.tensorId
          if followsRun() {
            imageStep = (history.project.name, saved.tensorId)
            canvasBeforePreview = nil
            previewCoversCanvas = false
            canvasIsImported = false
            image = matched
            canvas.zoomToFit()
            // A new step, with no mask of its own yet.
            landedMask = (saved.tensorId, canvasMask)
            maskPendingTensorId = nil
          }
          statusNote = shift.summary
        }
        if let failure = await history.writeToOutputFolder(saved, image: matched, in: project) { errorMessage = failure }
        saveSession()
        FinishedNotice.post(prompt: shift.summary, seconds: Date().timeIntervalSince(startedAt), title: "Colors matched")
        status = .finished(tensorId: saved.tensorId)
        inputTensorId = saved.inputTensorId
        inOpenProject = project === history.project
      } catch is CancellationError {
      } catch {
        errorMessage = error.localizedDescription
        status = .failed(error.localizedDescription)
      }
      finish(job, status: status, inputTensorId: inputTensorId, inOpenProject: inOpenProject)
    }
    track(task, for: job)
  }

  nonisolated enum ColorMatchError: LocalizedError {
    case video, noOriginal, unreadable, noSettings, projectMissing(String), stepMissing(String), failed(String)

    var errorDescription: String? {
      switch self {
      case .video: "Match Colors to Original works on images, not videos."
      case .noOriginal: "This image has no original to match: it wasn't made from the canvas or a moodboard image, or that image is no longer in the project."
      case .unreadable: "The image or its original couldn't be read."
      case .noSettings: "There are no settings to save the result with yet: wait for the model list to load."
      case .projectMissing(let name): "The project “\(name)” the image was in is no longer there."
      case .stepMissing(let name): "The image is no longer in the project “\(name)”."
      case .failed(let message): message
      }
    }
  }

  /// Runs an image upscale job on this device: with a model, or as a video upscaler's one-frame clip.
  private func upscaled(
    image: CGImage, as upscale: ImageUpscale, request: GenerationEngine.Request,
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output {
    switch upscale.upscaler {
    case .model(let file):
      return try await engine.upscale(image: image, model: file, scale: upscale.scale, progress: progress)
    case .video(let method, let variant):
      var clip = request
      // The image comes as the frame; a clip's source isn't read here.
      clip.upscale = ClipUpscale(
        method: method, scale: upscale.scale, sourceTensorId: 0, variant: variant, isImage: true)
      let output = try await engine.upscale(clip, frames: [image], progress: progress)
      guard let frame = output.frames.first else { throw ProjectError.badImage }
      return GenerationEngine.Output(frames: [frame])
    case .seedVR2(let file):
      // The sheet already says so; a queued job may come from a saved queue or a script.
      if let problem = upscale.problem(width: image.width, height: image.height) {
        throw ImageUpscaleError(message: problem)
      }
      // One step at the new size with the model's own defaults, as the catalog runs it.
      let size = upscale.outputSize(width: image.width, height: image.height)
      guard let stretched = ImageUpscale.stretched(image, width: size.width, height: size.height) else {
        throw ProjectError.badImage
      }
      var configuration = ModelDefaults.recommended(
        for: file, configuration: try await engine.loadPipeline(for: file))
      configuration.width = size.width
      configuration.height = size.height
      configuration.steps = 1
      configuration.strength = 1
      // Whole, past about 2896×2896 the decoder's attention is too large to reshape, and the engine
      // asserts building it (`SeedVR2AttentionBlock2D`, until flash attention takes over at
      // `FirstStage.decode`'s 256×176 latents). Tiles stay well under that.
      if max(size.width, size.height) > 2048 {
        configuration.tiledDecoding = true
        configuration.decodingTileWidth = 1024
        configuration.decodingTileHeight = 1024
        configuration.decodingTileOverlap = 128
      }
      var run = GenerationEngine.Request(
        model: file, prompt: "", negativePrompt: "", seed: request.seed, configuration: configuration)
      run.canvas = stretched
      run.canvasIsImported = true
      let output = try await engine.generate(run, progress: progress)
      guard let frame = output.frames.first else { throw ProjectError.badImage }
      return GenerationEngine.Output(frames: [frame])
    }
  }

  /// Runs an upscale job: the source clip's frames through the engine, with its soundtrack (at
  /// the result model's sample rate) and frame rate.
  private func upscaled(
    _ request: GenerationEngine.Request, _ upscale: ClipUpscale, job: JobQueue.Job, on backend: any GenerationBackend,
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output {
    guard let source = history.item(tensorId: upscale.sourceTensorId), let clip = source.clip else {
      throw UpscaleError.sourceMissing
    }
    var output: GenerationEngine.Output
    // A clip made on this server may still be there, which saves sending its frames back.
    let remote = backend as? RemoteBackend
    var cachedClip: UUID?
    if let remote, case .remote(let server) = job.target,
       let clipJob = clientJobs.clip(tensorId: upscale.sourceTensorId, project: history.project.name, server: server),
       await remote.hasClip(clipJob)
    {
      cachedClip = clipJob
    }
    if let remote, let cachedClip {
      output = try await remote.upscale(request, frames: [], sourceClip: cachedClip, job: job.id, progress: progress)
    } else {
      setRunMessage("Reading \(clip.frames.count) frames…", job)
      var frames = await history.frames(of: source)
      guard frames.count == clip.frames.count else { throw ProjectError.badImage }
      if let limit = upscale.frameLimit, limit < frames.count { frames = Array(frames.prefix(limit)) }
      output = try await backend.upscale(request, frames: frames, progress: progress)
    }
    let frameCount = output.frames.count
    output.framesPerSecond = clip.framesPerSecond
    if let audio = await history.audio(of: source) {
      let rate = RemoteModelTraits.audioSampleRate(of: request.model)
      var samples = ClipUpscale.resample(audio.samples, from: audio.sampleRate, to: rate)
      if frameCount < clip.frames.count {
        let length = min(
          samples.shape[1], Int(Double(frameCount) / clip.framesPerSecond * Double(rate)))
        samples = samples[0..<samples.shape[0], 0..<length].copied()
      }
      output.audio = samples
      output.audioSampleRate = rate
    }
    return output
  }

  nonisolated struct ImageUpscaleError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
  }

  nonisolated enum UpscaleError: LocalizedError {
    case sourceMissing

    var errorDescription: String? { "The clip to upscale is no longer in this project." }
  }

  /// Seconds left in sampling, from the pace of the steps so far; nil until two steps are in.
  func estimatedRemaining(at now: Date) -> TimeInterval? {
    guard let samplingStart, let lastStepAt, step > samplingStart.step, totalSteps > step
    else { return nil }
    let perStep = lastStepAt.timeIntervalSince(samplingStart.date) / Double(step - samplingStart.step)
    return max(0, perStep * Double(totalSteps - step) - now.timeIntervalSince(lastStepAt))
  }

  // MARK: - Recent prompts

  /// Prompts generated with, newest first (⌘↑ and ⌘↓ step through them).
  private(set) var recentPrompts = UserDefaults.standard.stringArray(forKey: "recentPrompts") ?? []
  /// Where ⌘↑/⌘↓ is in `recentPrompts`; nil while editing a prompt of your own.
  private var recentIndex: Int?
  /// The prompt being written before ⌘↑, restored by ⌘↓ past the newest.
  private var draftPrompt = ""

  private func remember(prompt: String) {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    recentPrompts.removeAll { $0 == prompt }
    recentPrompts.insert(prompt, at: 0)
    recentPrompts = Array(recentPrompts.prefix(50))
    UserDefaults.standard.set(recentPrompts, forKey: "recentPrompts")
    recentIndex = nil
  }

  /// ⌘↑: the next older prompt.
  func previousPrompt() {
    if let recentIndex, recentPrompts.indices.contains(recentIndex), prompt != recentPrompts[recentIndex] {
      self.recentIndex = nil  // Edited since recalling: start over from the newest.
    }
    let next = recentIndex.map { $0 + 1 } ?? (recentPrompts.first == prompt ? 1 : 0)
    guard recentPrompts.indices.contains(next) else { return }
    if recentIndex == nil { draftPrompt = prompt }
    recentIndex = next
    prompt = recentPrompts[next]
  }

  /// Forgets the recent prompts; the prompt being written stays.
  func clearRecentPrompts() {
    recentPrompts = []
    UserDefaults.standard.removeObject(forKey: "recentPrompts")
    recentIndex = nil
  }

  /// ⌘↓: the next newer prompt, then back to the draft.
  func nextPrompt() {
    guard let recentIndex else { return }
    if recentIndex == 0 {
      self.recentIndex = nil
      prompt = draftPrompt
    } else {
      self.recentIndex = recentIndex - 1
      prompt = recentPrompts[recentIndex - 1]
    }
  }

  /// Shows a history image on the canvas and restores its prompt, negative prompt and size,
  /// leaving the model, seed and other settings alone.
  func showWithPrompt(_ item: HistoryItem, undoManager: UndoManager?) {
    let sidecar = item.sidecar
    restorePrompts(sidecar.prompt, sidecar.negativePrompt)
    if let descriptor = SettingsRegistry.byID["size"] {
      set(
        descriptor,
        to: .object(["width": .number(Double(sidecar.width)), "height": .number(Double(sidecar.height))]),
        undoManager: undoManager)
    }
    show(item)
  }

  /// Shows a history image on the canvas without touching the prompt or settings, and makes it
  /// the current step.
  func show(_ item: HistoryItem) {
    statusNote = nil
    stopFollowingRun()
    let projectName = history.project.name
    imageStep = (projectName, item.tensorId)
    history.setCurrent(tensorId: item.tensorId)
    canvasIsImported = false
    canvas.zoomToFit()
    showStoredJPEG(of: item, in: projectName)
    showTask = Task {
      let full = await whileLoadingCanvasImage {
        await Project.$isCanvasRead.withValue(true) { await history.image(at: item.id, in: projectName) }
      }
      // Another image took its place: it's that one's turn now.
      guard !Task.isCancelled else { return }
      if let full, imageStep?.tensorId == item.tensorId, !imageIsPreview {
        image = full
        await restoreCanvasMask()
        await loadCanvasDetail(tensorId: item.tensorId, project: projectName)
      } else if full == nil, imageStep?.tensorId == item.tensorId {
        canvasImageDidNotLoad("This image couldn't be read from the project.")
      }
    }
  }

  /// Puts a History step's image on the canvas as the input of the next Edit run (it becomes the
  /// current step), for callers without the view, with the mask it last had unless `restoresMask`
  /// is false. Returns once it's there; false for a video or an image that can't be read.
  func placeOnCanvas(_ item: HistoryItem, restoresMask: Bool = true) async -> Bool {
    guard !item.isVideo else { return false }
    let projectName = history.project.name
    guard let full = await whileLoadingCanvasImage({ await history.image(at: item.id, in: projectName) }) else {
      return false
    }
    statusNote = nil
    stopFollowingRun()
    imageStep = (projectName, item.tensorId)
    history.setCurrent(tensorId: item.tensorId)
    canvasIsImported = false
    image = full
    canvas.zoomToFit()
    canvasMode = .edit
    await loadCanvasDetail(tensorId: item.tensorId, project: projectName)
    if restoresMask {
      await restoreCanvasMask()
    } else {
      // Left without its mask on purpose: leaving it unchanged keeps the one it had.
      maskPendingTensorId = nil
      landedMask = (item.tensorId, nil)
    }
    return true
  }

  /// Runs a load of the canvas image, marking the canvas as waiting on it.
  private func whileLoadingCanvasImage<T>(_ load: () async -> T) async -> T {
    let id = UUID()
    canvasImageLoad = id
    let result = await load()
    if canvasImageLoad == id {
      canvasImageLoad = nil
      // Whatever the load brought (or didn't), the stand-in is done.
      canvasPlaceholder = nil
    }
    return result
  }

  /// Puts `item`'s stored full-size JPEG on the canvas while its exact pixels decode. The project
  /// keeps one beside every image (Draw Things' `ThumbnailHistoryNode`), and it decodes in tens of
  /// milliseconds where the image's tensor can take seconds (fpzip, for an upscale). Only when it's
  /// the image's own size, so the canvas's fit doesn't move when the exact pixels replace it.
  private func showStoredJPEG(of item: HistoryItem, in projectName: String) {
    guard !item.isVideo else { return }
    Task {
      guard let jpeg = await history.thumbnail(for: item, half: false),
            jpeg.width == item.sidecar.width, jpeg.height == item.sidecar.height,
            let decoded = await Self.decoded(jpeg),
            awaitsStepImage, isLoadingCanvasImage, !imageIsPreview,
            imageStep?.project == projectName, imageStep?.tensorId == item.tensorId
      else { return }
      canvasPlaceholder = decoded
    }
  }

  /// `image` with its pixels decoded now, off the main actor, so drawing it doesn't stall.
  @concurrent private static func decoded(_ image: CGImage) async -> CGImage? {
    guard let context = CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
  }

  /// The canvas is about to show something else: the running job's previews and result stop
  /// landing on it.
  private func stopFollowingRun() {
    guard isRunning else { return }
    canvasFollowsRun = false
    canvasBeforePreview = nil
    previewCoversCanvas = false
  }

  /// Puts the running job back on the canvas (clicking the live thumbnail); its previews and
  /// result show there again.
  func followRun() {
    guard isRunning, !canvasFollowsRun else { return }
    canvasFollowsRun = true
    if let livePreview { coverCanvas(with: livePreview) }
  }

  private func coverCanvas(with preview: CGImage) {
    // A style thumbnail's previews show in the status bar only: the canvas keeps your image.
    guard queue.running?.styleThumbnail == nil else { return }
    if !previewCoversCanvas {
      canvasBeforePreview = canvasSource
      previewCoversCanvas = true
      // Previews fill the frame; the input's placement no longer applies.
      if !imageIsPreview { canvas.zoomToFit() }
    }
    image = preview
    imageIsPreview = true
  }

  /// Stops the running job; the queue goes on with the next.
  func cancel() {
    guard let generationTask else { return }
    phase = .cancelling
    generationTask.cancel()
  }

  /// Stops a job if it's running, or takes it out of the queue.
  func cancel(_ id: UUID) {
    if foregroundJobID == id {
      cancel()
    } else if let task = runTasks[id] {
      task.cancel()
    } else if queue.removeWaiting(id) != nil {
      agentCallbacks.removeValue(forKey: id)?.completion(.failure(CancellationError()))
      thumbnailCallbacks.removeValue(forKey: id)?(.failure(CancellationError()))
      deviceCallbacks.removeValue(forKey: id)?.completion(.failure(CancellationError()))
    }
  }

  /// Empties the queue and stops the running job.
  func cancelAll() {
    for id in queue.removeAllWaiting() {
      agentCallbacks.removeValue(forKey: id)?.completion(.failure(CancellationError()))
      thumbnailCallbacks.removeValue(forKey: id)?(.failure(CancellationError()))
      deviceCallbacks.removeValue(forKey: id)?.completion(.failure(CancellationError()))
    }
    for (id, task) in runTasks where id != foregroundJobID { task.cancel() }
    cancel()
  }

  /// Pausing holds the waiting jobs; the running one finishes.
  func setQueuePaused(_ paused: Bool) {
    queue.isPaused = paused
    runNext()
  }

  /// Queues a finished, failed or cancelled job again, same settings and seed.
  func retry(_ id: UUID) {
    // A match already waiting or running for the same step and settings would make the same image.
    if let match = queue.recent.first(where: { $0.id == id })?.request?.colorMatch, queue.pendingColorMatch(match) != nil {
      statusNote = "Colors are already being matched for that image with those settings, so it wasn't queued again."
      return
    }
    queue.retry(id)
    runNext()
  }

  /// A running job's files moving to or from its server, while they are.
  private(set) var transfer: (title: String, fraction: Double)?

  private func handle(_ progress: GenerationEngine.Progress, showsOnCanvas: Bool = true) {
    guard phase != .idle, phase != .cancelling else { return }
    switch progress {
    case .preview(let preview, let step, let total):
      livePreview = preview
      if canvasFollowsRun, showsOnCanvas { coverCanvas(with: preview) }
      noteStep(step, of: total)
    case .previewFrames(let frames, let step, let total):
      guard let first = frames.first else { return }
      livePreview = first
      livePreviewFrames = frames
      if canvasFollowsRun, showsOnCanvas { coverCanvas(with: first) }
      noteStep(step, of: total)
    case .state(let state):
      switch state {
      case .generating(let step, let total) where step == self.step && step == total && lastStepAt != nil:
        // The engine reports the last step again once sampling has ended (`GenerationTimings`).
        phase = .running(Self.describe(.decoding))
      case .decoding:
        // The engine signals `.imageDecoded` once decoding is done; saving is what's left.
        phase = .running("Finishing…")
      default:
        phase = .running(Self.describe(state))
      }
      transfer = Self.transfer(in: state)
      if case .generating(let step, let total) = state {
        noteStep(step, of: total)
      }
    }
    syncBackgroundTask()
  }

  private func noteStep(_ step: Int, of total: Int) {
    if step != self.step || lastStepAt == nil {
      let now = Date()
      if samplingStart == nil { samplingStart = (now, step) }
      lastStepAt = now
    }
    self.step = step
    totalSteps = total
  }

  private func loadDefaults(for model: String) {
    loadTask?.cancel()
    isLoadingModel = true
    let backend = self.backend(for: runTarget)
    loadTask = Task {
      do {
        let configuration = try await backend.loadPipeline(for: model)
        guard !Task.isCancelled, selectedModel == model else { return }
        let modelDefaults = ModelDefaults.recommended(for: model, configuration: configuration)
        self.modelDefaults = modelDefaults
        let recommended = withDefaultPreset(modelDefaults, for: model)
        self.recommended = recommended
        var settings = recommended
        if let pendingSettings {
          SettingsRegistry.apply(dump: pendingSettings, to: &settings)
        } else if let current = self.settings {
          // Switching models keeps the current values; Reset brings back this model's defaults.
          for descriptor in SettingsRegistry.all { descriptor.set(&settings, descriptor.get(current)) }
        }
        self.settings = settings
      } catch {
        errorMessage = error.localizedDescription
      }
      guard selectedModel == model else { return }
      let shouldGenerate = generateWhenLoaded && pendingSettings != nil && errorMessage == nil
      pendingSettings = nil
      generateWhenLoaded = false
      isLoadingModel = false
      if shouldGenerate { generate() }
    }
  }

  private static func describe(_ state: MediaGenerationPipeline.State) -> String {
    switch state {
    case .resolvingBackend, .resolvingModel, .preparing, .ensuringResources: return "Preparing…"
    case .uploading(let sent, let total):
      return total > 0 ? "Uploading \(sent * 100 / total)%…" : "Uploading…"
    case .downloading(let received, let total):
      return total > 0 ? "Downloading \(received * 100 / total)%…" : "Downloading…"
    case .encodingText: return "Encoding prompt…"
    case .encodingInputs: return "Encoding inputs…"
    case .generating(let step, let total): return "Step \(step) of \(total)"
    case .decoding: return "Decoding…"
    case .postprocessing: return "Processing…"
    case .cancelling: return "Cancelling…"
    case .completed: return "Saving…"
    case .cancelled: return "Cancelled"
    }
  }
}

/// Tells you a generation finished while Atelier was in the background: a badge on the app icon
/// (cleared when you come back) and a notification, if allowed and turned on in Settings.
@MainActor
enum FinishedNotice {
  private static var unseen = 0
  private static var observing = false

  /// `title` replaces "Image ready" / "Video ready" for work that isn't a generation.
  static func post(prompt: String, seconds: Double, isVideo: Bool = false, title: String? = nil) {
    guard !AppLifecycle.isActive, AppSettings.notifies else { return }
    let center = UNUserNotificationCenter.current()
    unseen += 1
    let count = unseen
    if !observing {
      observing = true
      AppLifecycle.onBecomeActive {
        unseen = 0
        Task { try? await center.setBadgeCount(0) }
      }
    }
    let content = UNMutableNotificationContent()
    content.title = title ?? (isVideo ? "Video ready" : "Image ready")
    content.body = "\(prompt.prefix(120)) (\(GenerationTime.text(seconds)))"
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    Task {
      // Asked the first time there's a badge to show; skipped if not allowed.
      if (try? await center.requestAuthorization(options: [.badge])) == true {
        try? await center.setBadgeCount(count)
      }
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
      try? await center.add(request)
    }
  }
}

// MARK: - Masks kept per image

/// A mask copied from the canvas (Copy Mask), with the size of the image it was on, so Paste Mask
/// can stretch it onto another.
struct CopiedMask {
  var mask: CanvasMask
  var size: CGSize
}

extension CreateModel {
  /// How a mask from elsewhere goes onto the canvas's.
  enum MaskApplication: String {
    case replace, add, subtract
  }

  /// The image the canvas is leaving remembers the mask it has now (`HistoryStore.setMask`):
  /// painted, Selected or brought back, used by a run or not; clearing it clears that. Images
  /// from outside the project (not yet a step) remember nothing. Nothing is written when the mask
  /// is the one it arrived with, or when its own hasn't come back yet.
  private func persistCanvasMask(for step: (project: String, tensorId: Int64)) {
    guard step.project == history.project.name else { return }
    if canvasMask == nil, maskPendingTensorId == step.tensorId { return }
    if let landedMask, landedMask.tensorId == step.tensorId, landedMask.mask == canvasMask { return }
    // At the image's size, for compacting: the image under a run's preview, else the one showing.
    var size: CGSize?
    if previewCoversCanvas, let before = canvasBeforePreview, before.step?.tensorId == step.tensorId {
      size = CGSize(width: before.image.width, height: before.image.height)
    } else if !imageIsPreview, let image {
      size = CGSize(width: image.width, height: image.height)
    }
    history.setMask(canvasMask, forImage: step.tensorId, size: size)
    landedMask = (step.tensorId, canvasMask)
  }

  /// The canvas image remembers its mask now (`persistCanvasMask`): before a job is queued from
  /// it, the project changes, or the app goes away.
  func rememberCanvasMask() {
    if let imageStep { persistCanvasMask(for: imageStep) }
  }

  /// The image mask and Select steps belong to: the canvas image, or while a run's preview covers
  /// it, the image beneath (whose mask the canvas still holds). Nil while the step's image is on
  /// its way, or with no image of its own.
  var canvasUndoImage: CGImage? {
    // Only while the preview is what shows: once the result lands, it's the canvas's image.
    if previewCoversCanvas, imageIsPreview { return canvasBeforePreview?.image }
    guard !awaitsStepImage, !isLoadingCanvasImage, canvasClip == nil, !imageIsPreview else { return nil }
    return image
  }

  /// The step's image didn't arrive: the canvas keeps showing the one before, so it says so, and
  /// why the mask tools are off.
  private func canvasImageDidNotLoad(_ note: String) {
    // The mask tools stay off: what shows is the image before, and anything painted or selected
    // on it would be kept as the new step's.
    statusNote = note + " Put another image on the canvas to paint a mask."
  }

  /// The step on the canvas is in the project now called `name`, renamed from `old`: it's the same
  /// image, so nothing about it changes.
  func projectRenamed(from old: String, to name: String) {
    queue.renameColorMatchProject(from: old, to: name)
    guard let step = imageStep, step.project == old else { return }
    relabelsImageStep = true
    imageStep = (name, step.tensorId)
    relabelsImageStep = false
  }

  /// The canvas shows its step's own image, loaded: what mask tools may change
  /// (`canEditMask`).
  var canvasImageIsCurrent: Bool { !awaitsStepImage && !isLoadingCanvasImage }

  /// Brings back the mask the canvas image last had (`HistoryStore.storedMask`), once the image is
  /// on the canvas: it's the image's, so it registers no undo step. Not when another image took
  /// its place while it loaded, or something was painted meanwhile. Returns whether a mask came
  /// back.
  @discardableResult
  func restoreCanvasMask() async -> Bool {
    guard let step = imageStep, step.project == history.project.name else { return false }
    let mask = await history.storedMask(tensorId: step.tensorId)
    guard let current = imageStep, current.project == step.project, current.tensorId == step.tensorId else { return false }
    if maskPendingTensorId == step.tensorId { maskPendingTensorId = nil }
    guard canvasMask == nil else { return false }
    landedMask = (step.tensorId, mask)
    guard let mask else { return false }
    canvasMask = mask
    return true
  }

  /// The last session's canvas image, back on the canvas after a relaunch with the mask it had.
  func restoreSessionImage(_ restoredImage: CGImage, tensorId: Int64, project: String) async {
    lastSavedTensorId = tensorId
    imageStep = (project, tensorId)
    image = restoredImage
    canvas.zoomToFit()
    await restoreCanvasMask()
    await loadCanvasDetail(tensorId: tensorId, project: project)
  }

  /// Whether `item` has a mask that can go on the canvas now (`applyMask(from:how:undoManager:)`).
  func canApplyMask(from item: HistoryItem) -> Bool {
    !item.isVideo && canPaintMask && history.hasStoredMask(tensorId: item.tensorId)
  }

  /// `item`'s remembered mask and the size of its image, which it's in the pixels of.
  func storedMask(of item: HistoryItem) async -> (mask: CanvasMask, size: CGSize)? {
    guard !item.isVideo, history.hasStoredMask(tensorId: item.tensorId) else { return nil }
    let projectName = history.project.name
    guard let mask = await history.storedMask(tensorId: item.tensorId) else { return nil }
    if canvasShowsImage, imageStep?.tensorId == item.tensorId, imageStep?.project == projectName, let image {
      return (mask, CGSize(width: image.width, height: image.height))
    }
    guard let source = await history.image(tensorId: item.tensorId, in: projectName) else { return nil }
    return (mask, CGSize(width: source.width, height: source.height))
  }

  /// Puts `item`'s remembered mask on the canvas image, stretched to fill it, replacing the mask
  /// there or added to it: one undo step, “Use Mask”. False when it has none, or the canvas
  /// changed while it was read.
  @discardableResult
  func applyMask(from item: HistoryItem, how: MaskApplication, undoManager: UndoManager?) async -> Bool {
    guard canApplyMask(from: item), let target = image.map(ObjectIdentifier.init), let stored = await storedMask(of: item), image.map(ObjectIdentifier.init) == target else { return false }
    return applyMask(stored.mask, from: stored.size, how: how, undoManager: undoManager)
  }

  /// Puts a mask made on an image of `sourceSize` on the canvas image, stretched to fill it
  /// (`CanvasMask.scaled`): replacing the mask there, or adding or subtracting what it paints,
  /// then with `invert` flipped. One undo step named `actionName`. Subtracting needs a mask to
  /// take from; the others, a canvas that can be painted (`canPaintMask`).
  @discardableResult
  func applyMask(
    _ mask: CanvasMask, from sourceSize: CGSize, how: MaskApplication, invert: Bool = false,
    actionName: String = "Use Mask", undoManager: UndoManager?
  ) -> Bool {
    guard canvasShowsImage, let image, how == .subtract ? canEditMask && canvasMask != nil : canPaintMask else { return false }
    let strokes = Self.strokes(applying: mask, from: sourceSize, to: CGSize(width: image.width, height: image.height), how: how)
    var result = how == .replace ? CanvasMask() : canvasMask ?? CanvasMask()
    result.strokes += strokes
    if invert { result.strokes.append(.invert) }
    setMask(result.strokes.isEmpty ? nil : result, actionName: actionName, undoManager: undoManager)
    return true
  }

  /// The strokes that put `mask`, made on an image of `sourceSize`, on one of `size`, stretched to
  /// fill it: for replace, the mask's own; to add or subtract, only what it paints (its own erasing
  /// and inverting strokes would reach the mask there is, so a mask with any is flattened to one
  /// bitmap first), painting or erasing.
  nonisolated static func strokes(applying mask: CanvasMask, from sourceSize: CGSize, to size: CGSize, how: MaskApplication)
    -> [CanvasMask.Stroke]
  {
    let fitted = mask.scaled(from: sourceSize, to: size)
    guard how != .replace else { return fitted.strokes }
    let erases = how == .subtract
    if fitted.strokes.contains(where: { $0.erases || $0.kind == .invert }) {
      return fitted.flattenedStroke(width: Int(size.width), height: Int(size.height), erases: erases).map { [$0] } ?? []
    }
    return fitted.strokes.map { stroke in
      var stroke = stroke
      stroke.erases = erases
      return stroke
    }
  }

  /// Copy Mask: there's a mask on the canvas image.
  var canCopyMask: Bool {
    canvasShowsImage && canvasMask?.mayHavePaint == true
  }

  func copyMask() {
    guard canCopyMask, let canvasMask, let image else { return }
    copiedMask = CopiedMask(mask: canvasMask, size: CGSize(width: image.width, height: image.height))
  }

  /// Paste Mask: a copied mask and a canvas that can be painted.
  var canPasteMask: Bool {
    copiedMask != nil && canPaintMask
  }

  /// Replaces the canvas mask with the copied one, stretched to fill the image: one undo step.
  func pasteMask(undoManager: UndoManager?) {
    guard canPasteMask, let copiedMask else { return }
    applyMask(copiedMask.mask, from: copiedMask.size, how: .replace, actionName: "Paste Mask", undoManager: undoManager)
  }
}
