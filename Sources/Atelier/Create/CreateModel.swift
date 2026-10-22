import AppKit
import Diffusion
import ModelZoo
import Observation
import UserNotifications
import _MediaGenerationKit

/// State behind the Create screen: the selected model, the inspector values, and the running job.
@MainActor
@Observable
final class CreateModel {
  enum Phase: Equatable {
    case idle
    case loadingModel
    case running(String)
    case cancelling
  }

  /// Generate starts from the prompt alone; Edit also sends the canvas to the model.
  enum CanvasMode: String {
    case generate, edit
  }

  let engine = GenerationEngine()
  let history: HistoryStore

  var models: [MediaGenerationResolvedModel] = []
  var selectedModel: String? {
    didSet {
      if selectedModel != oldValue, let selectedModel { loadDefaults(for: selectedModel) }
    }
  }
  var modelsDirectory = AppSettings.modelsDirectory

  var prompt = ""
  var negativePrompt = ""
  var seed = UInt32.random(in: 0...UInt32.max)
  /// Off means "always random": every Generate rolls a new seed. Remembered across launches;
  /// "Use settings", typing a seed and rolling one with the dice turn it on.
  var seedLocked = UserDefaults.standard.bool(forKey: "seedLocked") {
    didSet { UserDefaults.standard.set(seedLocked, forKey: "seedLocked") }
  }
  /// The inspector's values: every setting the next run uses (the seed lives in `seed`).
  var settings: PipelineConfiguration?
  /// The selected model's defaults, the baseline for changed markers, reset and presets.
  private(set) var recommended: PipelineConfiguration?
  /// MGK's template plus the app's fallbacks, before the model's default preset.
  private var modelDefaults: PipelineConfiguration?
  /// Source of each model's default preset (set by the app).
  var presets: PresetStore?
  /// The canvas's zoom and position.
  let canvas = CanvasState()
  /// Reference images, sent in both modes to models that take them.
  let moodboard = Moodboard()
  var canvasMode: CanvasMode = CreateModel.storedCanvasMode {
    didSet { UserDefaults.standard.set(canvasMode.rawValue, forKey: "canvasMode") }
  }
  private static var storedCanvasMode: CanvasMode {
    UserDefaults.standard.string(forKey: "canvasMode").flatMap(CanvasMode.init(rawValue:)) ?? .generate
  }
  /// The canvas image came from outside the project (drop, paste, Open), not yet saved as a step.
  private var canvasIsImported = false
  /// Where images picked in the Open panel go; set to show the panel.
  var imageImport: ImageImportTarget?

  enum ImageImportTarget {
    case canvas, moodboard
  }
  /// Bumped to ask the prompt composer to take focus (⌘L).
  var focusPromptRequest = 0

  private(set) var phase: Phase = .idle
  private(set) var step = 0
  private(set) var totalSteps = 0
  private(set) var image: CGImage?
  private(set) var lastSavedStep: StepID?
  /// When the running generation started.
  private(set) var runStartedAt: Date?
  /// The first sampling step seen and when, and when the latest one arrived, for the estimate.
  private var samplingStart: (date: Date, step: Int)?
  private var lastStepAt: Date?
  /// The project step behind `image` once it's a finished image (not a step preview).
  private var imageStep: (project: String, id: StepID)? {
    didSet { imageIsPreview = false }
  }
  /// The canvas shows a step preview, not `imageStep`'s image.
  private var imageIsPreview = false
  var errorMessage: String?
  /// A short note for the status bar, until the next run or Use Settings.
  var statusNote: String?

  private var generationTask: Task<Void, Never>?
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
    return history.items.first { $0.id == imageStep.id }
  }

  var isBusy: Bool {
    if case .idle = phase { return false }
    return true
  }

  var canGenerate: Bool {
    !isBusy && selectedModel != nil && settings != nil
      && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var selectedModelInfo: MediaGenerationResolvedModel? {
    models.first { $0.file == selectedModel }
  }

  var traits: ModelTraits { ModelTraits(selectedModelInfo) }

  /// Whether the model (or one of its LoRAs) reads the canvas and moodboard as reference images:
  /// edit models, the FLUX.2 family and Qwen Image 2.1. ModelZoo knows a community model once its
  /// pipeline has loaded.
  var usesReferences: Bool {
    guard let file = selectedModel else { return false }
    if ModelZoo.versionForModel(file) == .qwenImage2_1 { return true }
    let modifiers =
      [ModelZoo.modifierForModel(file)]
      + (settings?.loras ?? []).compactMap(\.file).map(LoRAZoo.modifierForModel)
    return modifiers.contains {
      switch $0 {
      case .kontext, .kontextKv, .qwenimageEditPlus, .qwenimageEdit2511, .fl2va, .ref2va: true
      default: false
      }
    }
  }

  /// Puts an image from outside the project on the canvas, fitted to the frame, and switches to
  /// Edit so the next run starts from it.
  func setCanvasImage(_ newImage: CGImage) {
    guard !isBusy else { return }
    imageStep = nil
    lastSavedStep = nil
    image = newImage
    canvasIsImported = true
    canvas.zoomToFit()
    canvasMode = .edit
  }

  /// Empties the canvas (Generate mode then has nothing to show it with).
  func clearCanvas() {
    guard !isBusy else { return }
    imageStep = nil
    lastSavedStep = nil
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
    let pasteboard = NSPasteboard.general
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
      if let data = pasteboard.data(forType: type), let image = ImageLoader.image(from: data) {
        setCanvasImage(image)
        return
      }
    }
    if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
      let image = ImageLoader.image(at: url)
    {
      setCanvasImage(image)
    }
  }

  private(set) var modelFiles: [String] = []

  var settingContext: SettingContext {
    SettingContext(models: models, files: modelFiles)
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
    if let session = SessionState.load() {
      restored = session
      prompt = session.prompt
      negativePrompt = session.negativePrompt
      if let seed = session.seed { self.seed = seed }
      if let project = session.imageProject, let step = session.imageStep {
        Task {
          guard let restoredImage = await history.image(at: step, in: project), image == nil
          else { return }
          lastSavedStep = step
          imageStep = (project, step)
          image = restoredImage
        }
      }
    }
    for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.saveSession() }
      }
    }
    Task { await reloadModels() }
  }

  /// Remembers the model, prompts, seed, inspector values and canvas image for the next launch.
  func saveSession() {
    // Until the models load, the last session's model and settings are still waiting to apply.
    guard restored == nil else { return }
    SessionState(
      model: selectedModel, prompt: prompt, negativePrompt: negativePrompt, seed: seed,
      settings: settings.map(JSONValue.fields(of:)) ?? pendingSettings,
      imageProject: imageStep?.project, imageStep: imageStep?.id
    ).save()
  }

  /// Whether `item`'s model is downloaded, so its settings can be loaded here.
  func canUse(_ item: HistoryItem) -> Bool {
    !isBusy && !item.sidecar.configuration.isEmpty
      && models.contains { $0.file == item.sidecar.model }
  }

  /// Loads a history item's prompt, model, seed and settings into Create. With `newSeed`, rolls a
  /// fresh seed and generates as soon as the model is ready.
  func use(_ item: HistoryItem, newSeed: Bool = false) {
    guard canUse(item) else { return }
    let sidecar = item.sidecar
    prompt = sidecar.prompt
    negativePrompt = sidecar.negativePrompt
    errorMessage = nil
    if newSeed {
      seedLocked = false
    } else {
      seed = sidecar.seed
      seedLocked = true
    }
    statusNote = nil
    let projectName = history.project.name
    imageStep = (projectName, item.id)
    canvasIsImported = false
    // An Edit step brings back its input, fitted, in Edit mode, so rerunning reproduces it.
    // Without its input (deleted since) it shows the result, as for a Generate step.
    let restoreImage = Task {
      if item.inputTensorId != nil {
        if let input = await history.input(of: item, in: projectName) {
          guard imageStep?.id == item.id else { return }
          imageStep = (projectName, input.id)
          image = input.image
          canvas.zoomToFit()
          canvasMode = .edit
          return
        }
        guard imageStep?.id == item.id else { return }
        statusNote = "The image this was made from is no longer in the project."
      }
      let full = await history.image(at: item.id, in: projectName)
      if let full, imageStep?.id == item.id { image = full }
    }
    let restoreMoodboard = Task {
      let references = await history.moodboard(at: item.id, in: projectName)
      moodboard.replace(with: references)
    }
    if selectedModel == sidecar.model, phase != .loadingModel, var settings = recommended {
      SettingsRegistry.apply(dump: sidecar.configuration, to: &settings)
      self.settings = settings
      if newSeed {
        Task {
          await restoreMoodboard.value
          await restoreImage.value
          generate()
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

  func setModelsDirectory(_ directory: String) {
    AppSettings.modelsDirectory = directory
    modelsDirectory = directory
    Task { await reloadModels() }
  }

  func reloadModels() async {
    await engine.setModelsDirectory(modelsDirectory)
    await loadModelList()
    if let restored, let model = restored.model, models.contains(where: { $0.file == model }) {
      self.restored = nil
      pendingSettings = restored.settings
      selectedModel = model
      return
    }
    restored = nil
    if let selectedModel, models.contains(where: { $0.file == selectedModel }) {
      loadDefaults(for: selectedModel)
    } else {
      selectedModel = models.first?.file
    }
  }

  /// Rereads the downloaded models after a download or delete, keeping the current settings
  /// unless the selected model is gone.
  func refreshModelList() async {
    await loadModelList()
    if selectedModel == nil || !models.contains(where: { $0.file == selectedModel }) {
      selectedModel = models.first?.file
    }
  }

  private func loadModelList() async {
    let models = await engine.downloadedModels()
    let directory = modelsDirectory
    let modelFiles = await Task.detached {
      ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }.value
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
    if let selectedModel, presets?.defaultPreset(for: selectedModel) != nil { seedLocked = false }
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
  func apply(_ preset: Preset, undoManager: UndoManager?) {
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
    if let seed = pasted.seed {
      self.seed = seed
      seedLocked = true
    }
    if let model = pasted.model, model != selectedModel, models.contains(where: { $0.file == model }) {
      pendingSettings = pasted.dump
      selectedModel = model
      return
    }
    guard var configuration = recommended, let settings else { return }
    SettingsRegistry.apply(dump: pasted.dump, to: &configuration)
    registerUndo(restoring: settings, undoManager, actionName: "Paste Settings")
    self.settings = configuration
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

  /// The dice and ⌘R: a new seed that every generation keeps until it changes.
  func rollAndLockSeed() {
    rollSeed()
    seedLocked = true
  }

  func generate() {
    guard canGenerate, let model = selectedModel, let settings else { return }
    if !seedLocked { rollSeed() }
    errorMessage = nil
    statusNote = nil
    // The request snapshots the settings, canvas and moodboard, so edits during the run apply to
    // the next one.
    var request = GenerationEngine.Request(
      model: model, prompt: prompt, negativePrompt: negativePrompt, seed: seed,
      configuration: settings)
    if canvasMode == .edit, let image {
      request.canvas = canvas.render(image, size: CGSize(width: settings.width, height: settings.height))
      request.canvasIsImported = canvasIsImported
      // The canvas is exactly its step's image when that's fitted at the output size.
      if !canvasIsImported, !imageIsPreview, let imageStep, imageStep.project == history.project.name,
        image.width == settings.width, image.height == settings.height,
        canvas.scale == nil || canvas.scale == 1, canvas.offset == .zero
      {
        request.canvasStep = imageStep.id
      }
    }
    if usesReferences { request.moodboard = moodboard.references }
    phase = .running("Preparing…")
    step = 0
    totalSteps = settings.steps
    let startedAt = Date()
    runStartedAt = startedAt
    samplingStart = nil
    lastStepAt = nil
    remember(prompt: prompt)
    generationTask = Task { [engine] in
      do {
        let result = try await engine.generate(request) { progress in
          Task { @MainActor in self.handle(progress) }
        }
        let item = try await history.save(
          result, request: request, startedAt: startedAt, finishedAt: Date())
        lastSavedStep = item.id
        imageStep = (history.project.name, item.id)
        canvasIsImported = false
        image = ImageTensor.cgImage(from: result.tensor) ?? image
        saveSession()
        FinishedNotice.post(prompt: request.prompt, seconds: item.sidecar.durationSeconds)
      } catch is CancellationError {
        // Cancelled by the user; keep the last preview on the canvas.
      } catch {
        errorMessage = error.localizedDescription
      }
      phase = .idle
      generationTask = nil
      runStartedAt = nil
    }
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

  /// Shows a history image on the canvas without touching the prompt or settings.
  func show(_ item: HistoryItem) {
    statusNote = nil
    let projectName = history.project.name
    imageStep = (projectName, item.id)
    canvasIsImported = false
    Task {
      let full = await history.image(at: item.id, in: projectName)
      if let full, imageStep?.id == item.id { image = full }
    }
  }

  func cancel() {
    guard let generationTask else { return }
    phase = .cancelling
    generationTask.cancel()
  }

  private func handle(_ progress: GenerationEngine.Progress) {
    guard generationTask != nil, phase != .cancelling else { return }
    switch progress {
    case .preview(let preview, let step, let total):
      // Previews fill the frame; the input's placement no longer applies.
      if !imageIsPreview { canvas.zoomToFit() }
      image = preview
      imageIsPreview = true
      noteStep(step, of: total)
    case .state(let state):
      phase = .running(Self.describe(state))
      if case .generating(let step, let total) = state {
        noteStep(step, of: total)
      }
    }
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
    phase = .loadingModel
    loadTask = Task { [engine] in
      do {
        let configuration = try await engine.loadPipeline(for: model)
        guard !Task.isCancelled, selectedModel == model else { return }
        let modelDefaults = ModelDefaults.recommended(for: model, configuration: configuration)
        self.modelDefaults = modelDefaults
        let recommended = withDefaultPreset(modelDefaults, for: model)
        self.recommended = recommended
        var settings = recommended
        if let pendingSettings {
          SettingsRegistry.apply(dump: pendingSettings, to: &settings)
        } else if presets?.defaultPreset(for: model) != nil {
          // A default preset always comes with Random on; pasted or reused settings keep their seed.
          seedLocked = false
        }
        self.settings = settings
      } catch {
        errorMessage = error.localizedDescription
      }
      guard selectedModel == model else { return }
      let shouldGenerate = generateWhenLoaded && pendingSettings != nil && errorMessage == nil
      pendingSettings = nil
      generateWhenLoaded = false
      phase = .idle
      if shouldGenerate { generate() }
    }
  }

  private static func describe(_ state: MediaGenerationPipeline.State) -> String {
    switch state {
    case .resolvingBackend, .resolvingModel, .preparing, .ensuringResources: return "Preparing…"
    case .uploading: return "Uploading…"
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

/// Tells you a generation finished while Atelier was in the background: a Dock badge (cleared when
/// you come back) and a notification, if allowed.
@MainActor
enum FinishedNotice {
  private static var unseen = 0
  private static var observing = false

  static func post(prompt: String, seconds: Double) {
    guard !NSApp.isActive else { return }
    unseen += 1
    NSApp.dockTile.badgeLabel = String(unseen)
    if !observing {
      observing = true
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          unseen = 0
          NSApp.dockTile.badgeLabel = nil
        }
      }
    }
    let center = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()
    content.title = "Image ready"
    content.body = "\(prompt.prefix(120)) (\(GenerationTime.text(seconds)))"
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    Task {
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
      try? await center.add(request)
    }
  }
}
