import AppKit
import Observation
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
  /// "Use settings" and typing a seed turn it on.
  var seedLocked = UserDefaults.standard.bool(forKey: "seedLocked") {
    didSet { UserDefaults.standard.set(seedLocked, forKey: "seedLocked") }
  }
  /// The inspector's values: every setting the next run uses (the seed lives in `seed`).
  var settings: PipelineConfiguration?
  /// The selected model's defaults, the baseline for changed markers, reset and presets.
  private(set) var recommended: PipelineConfiguration?
  /// Bumped to ask the prompt composer to take focus (⌘L).
  var focusPromptRequest = 0

  private(set) var phase: Phase = .idle
  private(set) var step = 0
  private(set) var totalSteps = 0
  private(set) var image: CGImage?
  private(set) var lastSavedURL: URL?
  var errorMessage: String?

  private var generationTask: Task<Void, Never>?
  private var loadTask: Task<Void, Never>?
  /// A history item's configuration dump to apply once the model's defaults finish loading.
  private var pendingSettings: [String: JSONValue]?
  /// While a slider drags, its changes share the undo step registered when the drag began.
  private var coalescingEdit = false
  private var generateWhenLoaded = false

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

  var settingContext: SettingContext {
    SettingContext(models: models, modelsDirectory: modelsDirectory)
  }

  init(history: HistoryStore) {
    self.history = history
    Task { await reloadModels() }
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
    image = NSImage(contentsOf: item.imageURL)?.cgImage(
      forProposedRect: nil, context: nil, hints: nil)
    if selectedModel == sidecar.model, phase != .loadingModel, var settings = recommended {
      SettingsRegistry.apply(dump: sidecar.configuration, to: &settings)
      self.settings = settings
      if newSeed { generate() }
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
    models = await engine.downloadedModels()
    if let selectedModel, models.contains(where: { $0.file == selectedModel }) {
      loadDefaults(for: selectedModel)
    } else {
      selectedModel = models.first?.file
    }
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

  /// Applies a preset on top of the model's defaults; settings it doesn't name keep the defaults.
  func apply(_ preset: Preset, undoManager: UndoManager?) {
    guard var configuration = recommended, let settings else { return }
    for (id, value) in preset.values {
      SettingsRegistry.byID[id]?.set(&configuration, value)
    }
    registerUndo(restoring: settings, undoManager, actionName: "Apply Preset “\(preset.name)”")
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

  func generate() {
    guard canGenerate, let model = selectedModel, let settings else { return }
    if !seedLocked { rollSeed() }
    errorMessage = nil
    // The request snapshots the settings, so inspector edits during the run apply to the next one.
    let request = GenerationEngine.Request(
      model: model, prompt: prompt, negativePrompt: negativePrompt, seed: seed,
      configuration: settings)
    phase = .running("Preparing…")
    step = 0
    totalSteps = settings.steps
    generationTask = Task { [engine] in
      let startedAt = Date()
      do {
        let result = try await engine.generate(request) { progress in
          Task { @MainActor [weak self] in self?.handle(progress) }
        }
        let url = try history.save(
          result, request: request, startedAt: startedAt, finishedAt: Date()
        ).imageURL
        lastSavedURL = url
        image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
      } catch is CancellationError {
        // Cancelled by the user; keep the last preview on the canvas.
      } catch {
        errorMessage = error.localizedDescription
      }
      phase = .idle
      generationTask = nil
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
      image = preview
      self.step = step
      totalSteps = total
    case .state(let state):
      phase = .running(Self.describe(state))
      if case .generating(let step, let total) = state {
        self.step = step
        totalSteps = total
      }
    }
  }

  private func loadDefaults(for model: String) {
    loadTask?.cancel()
    phase = .loadingModel
    loadTask = Task { [engine] in
      do {
        let configuration = try await engine.loadPipeline(for: model)
        guard !Task.isCancelled, selectedModel == model else { return }
        let recommended = ModelDefaults.recommended(for: model, configuration: configuration)
        self.recommended = recommended
        var settings = recommended
        if let pendingSettings { SettingsRegistry.apply(dump: pendingSettings, to: &settings) }
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
