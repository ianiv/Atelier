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
  var seedLocked = false
  var settings: GenerationSettings?
  private(set) var recommended: GenerationSettings?

  private(set) var phase: Phase = .idle
  private(set) var step = 0
  private(set) var totalSteps = 0
  private(set) var image: CGImage?
  private(set) var lastSavedURL: URL?
  var errorMessage: String?

  private var generationTask: Task<Void, Never>?
  private var loadTask: Task<Void, Never>?

  var isBusy: Bool {
    if case .idle = phase { return false }
    return true
  }

  var canGenerate: Bool {
    !isBusy && selectedModel != nil && settings != nil
      && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  init() {
    Task { await reloadModels() }
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

  func resetToModelDefaults() {
    guard let recommended, var settings else { return }
    // Keep the chosen size; reset only the sampling settings.
    let (width, height) = (settings.width, settings.height)
    settings = recommended
    settings.width = width
    settings.height = height
    self.settings = settings
  }

  func rollSeed() {
    seed = UInt32.random(in: 0...UInt32.max)
  }

  func generate() {
    guard canGenerate, let model = selectedModel, let settings else { return }
    if !seedLocked { rollSeed() }
    errorMessage = nil
    let request = GenerationEngine.Request(
      model: model, prompt: prompt, negativePrompt: negativePrompt, seed: seed,
      settings: settings)
    phase = .running("Preparing…")
    step = 0
    totalSteps = settings.steps
    generationTask = Task { [engine] in
      let startedAt = Date()
      do {
        let result = try await engine.generate(request) { progress in
          Task { @MainActor [weak self] in self?.handle(progress) }
        }
        let configuration = try await engine.loadPipeline(for: model)
        var used = configuration
        request.settings.apply(to: &used)
        used.seed = request.seed
        let url = try HistoryStore.save(
          result, request: request, configuration: used, startedAt: startedAt,
          finishedAt: Date())
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
        settings = recommended
      } catch {
        errorMessage = error.localizedDescription
      }
      if selectedModel == model { phase = .idle }
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
