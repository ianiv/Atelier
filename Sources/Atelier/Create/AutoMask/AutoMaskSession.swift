import CoreGraphics
import Foundation
import Observation

/// How a selection goes into the canvas mask.
nonisolated enum AutoMaskMode: String, CaseIterable, Sendable, Codable {
  case add, subtract, replace

  var title: String {
    switch self {
    case .add: "Add"
    case .subtract: "Subtract"
    case .replace: "Replace"
    }
  }

  /// The undo step the Select tool's button makes.
  var actionName: String {
    switch self {
    case .add: "Add Selection"
    case .subtract: "Subtract Selection"
    case .replace: "Replace Mask"
    }
  }

  /// The mask after committing `selection` (a bitmap stroke, `CanvasMask.Stroke.bitmap`) to
  /// `mask` this way. Replace starts over from the selection alone; subtracting from no mask
  /// leaves none.
  func applied(_ selection: CanvasMask.Stroke, to mask: CanvasMask?) -> CanvasMask? {
    var stroke = selection
    stroke.erases = self == .subtract
    switch self {
    case .add:
      return CanvasMask(strokes: (mask?.strokes ?? []) + [stroke])
    case .subtract:
      guard let mask else { return nil }
      return CanvasMask(strokes: mask.strokes + [stroke])
    case .replace:
      return CanvasMask(strokes: [stroke])
    }
  }
}

/// What the Select tool selects from: SAM's clicks and box, or Vision's subject (under a point, or
/// all of them). Each change is an undo step (`AutoMaskSession.change`).
struct AutoMaskPrompt: Equatable {
  var points: [SAMSegmenter.Point] = []
  var box: CGRect?
  var subject = false
  var subjectPoint: CGPoint?

  var isEmpty: Bool { points.isEmpty && box == nil && !subject }

  /// The clicks the decoder can take beside the box (`SAMGeometry.promptInputs`), so the dots on
  /// the canvas are the ones used: the earliest go.
  func trimmed() -> AutoMaskPrompt {
    var trimmed = self
    let limit = SAMGeometry.maxPromptPoints - (box == nil ? 0 : 2)
    if trimmed.points.count > limit { trimmed.points.removeFirst(trimmed.points.count - limit) }
    return trimmed
  }
}

/// A selection worked out on the canvas image, before it goes into the mask.
struct AutoMaskSelection {
  /// One byte per image pixel, top row first: 255 selected.
  var coverage: [UInt8]
  var width: Int
  var height: Int
  /// The canvas image it was worked out on: committing it to another image would be wrong. Held
  /// and compared by identity (`===`): an object identifier alone could be reused by a new image
  /// once this one is freed.
  var image: CGImage
  /// The selection tinted for the canvas (`AutoMaskSession.tint`).
  var tint: CGImage?
  /// Pixels selected.
  var selectedPixels: Int
  /// The selection as a mask stroke (`CanvasMask.Stroke.bitmap`), made with the rest off the main
  /// actor (encoding a 4K mask as PNG takes a while); nil when nothing is selected.
  var stroke: CanvasMask.Stroke?
}

/// What an auto mask did, for callers without the view (scripted checks, agents).
struct AutoMaskOutcome {
  /// The canvas mask afterwards (`CreateModel.canvasMaskStats`).
  var stats: CanvasMask.Stats?
  /// Pixels the selection itself covers.
  var selectedPixels: Int
  /// SAM's own quality estimate; nil for Select Subject.
  var score: Float?
  /// SAM's image encoder, when it ran (nil when the image was encoded already or for Select
  /// Subject), and its prompt encoder and decoder (or Vision's request, for Select Subject).
  var encodeTime: Duration?
  var decodeTime: Duration
}

enum AutoMaskError: LocalizedError {
  case cannotPaint, notDownloaded(SAMFiles.Size), emptyPrompt, nothingSelected, imageChanged, noMaskToSubtract

  var errorDescription: String? {
    switch self {
    case .cannotPaint: "The mask can't be changed now: an image must be on the canvas in Edit mode, for an image model."
    case .notDownloaded(let size): "SAM 2.1 \(size.title) isn't downloaded."
    case .emptyPrompt: "Click the image or drag a box to select."
    case .nothingSelected: "Nothing was selected."
    case .imageChanged: "The canvas image changed."
    case .noMaskToSubtract: "There's no mask to subtract from."
    }
  }
}

/// The Select tool's state: the clicks and box on the canvas image, the preview they select and
/// whether SAM or Vision is working on it. Points and box are in the image's pixels; a new canvas
/// image starts over (`follow`). Every change to them is an undo step in the window's history,
/// among the mask's and the settings' own: undoing one puts the clicks and box back and selects
/// again (the image's encoding is cached, so only the decoder runs).
@MainActor
@Observable
final class AutoMaskSession {
  static let sizeKey = "autoMaskModelSize"

  /// Which SAM 2.1 to use (Small unless picked otherwise). Changing it starts over: a selection
  /// is the model's (`setSize` makes that an undo step).
  var size = UserDefaults.standard.string(forKey: AutoMaskSession.sizeKey).flatMap(SAMFiles.Size.init(rawValue:)) ?? .small {
    didSet {
      UserDefaults.standard.set(size.rawValue, forKey: Self.sizeKey)
      reset()
    }
  }

  private(set) var points: [SAMSegmenter.Point] = []
  private(set) var box: CGRect?
  /// The preview is Vision's subject (under `subjectPoint`, else all of them), not SAM's.
  private var subject = false
  private var subjectPoint: CGPoint?
  /// The points came back (an undo) while a run's preview covered their image: selecting waits
  /// until the image shows again (`resumeSelecting`).
  private(set) var selectionWaits = false
  /// iPad has no Option key: this makes taps negative points instead.
  var negative = false
  private(set) var preview: AutoMaskSelection?
  private(set) var isBusy = false
  private(set) var failure: String?
  /// The canvas image the points are on, held so its identity can't pass to another image.
  private(set) var image: CGImage?
  private var task: Task<Void, Never>?

  var hasPrompt: Bool { !points.isEmpty || box != nil }

  /// What the preview is selected from now.
  var prompt: AutoMaskPrompt {
    AutoMaskPrompt(points: points, box: box, subject: subject, subjectPoint: subjectPoint)
  }

  /// Starts over when the canvas shows another image. Not an undo step: the steps on the old
  /// image leave the history with it (`CreateModel.retireCanvasUndo`).
  func follow(_ image: CGImage?) {
    guard image !== self.image else { return }
    reset()
    self.image = image
  }

  /// Clears the points, box and preview, with no undo step.
  private func reset() {
    task?.cancel()
    task = nil
    points = []
    box = nil
    subject = false
    subjectPoint = nil
    selectionWaits = false
    preview = nil
    failure = nil
    isBusy = false
  }

  /// Clear Points (and Esc): one undo step when there was anything to clear.
  func clearPoints(model: CreateModel, undoManager: UndoManager?) {
    guard !prompt.isEmpty || preview != nil else { return }
    guard model.canEditMask else { return reset() }
    follow(model.image)
    change(to: AutoMaskPrompt(), actionName: "Clear Points", model: model, undoManager: undoManager)
  }

  /// Adds a click (image pixels) and selects again: one undo step, “Add Point” or “Exclude
  /// Point”. Ignored until SAM is downloaded: clicking is SAM's (the controls say so).
  func addPoint(_ location: CGPoint, positive: Bool, model: CreateModel, undoManager: UndoManager? = nil) {
    // Not while another image is loading in: the points would be on the one going.
    guard SAMDownload.shared.isInstalled(size), model.canPaintMask else { return }
    follow(model.image)
    var next = AutoMaskPrompt(points: points, box: box)
    next.points.append(SAMSegmenter.Point(location: location, positive: positive))
    change(to: next.trimmed(), actionName: positive ? "Add Point" : "Exclude Point", model: model, undoManager: undoManager)
  }

  /// Sets the box (image pixels) and selects again: one undo step, “Select Box”. Ignored until
  /// SAM is downloaded.
  func setBox(_ rect: CGRect, model: CreateModel, undoManager: UndoManager? = nil) {
    guard SAMDownload.shared.isInstalled(size), model.canPaintMask else { return }
    follow(model.image)
    let next = AutoMaskPrompt(points: points, box: rect.standardized)
    change(to: next.trimmed(), actionName: "Select Box", model: model, undoManager: undoManager)
  }

  /// Select Subject: Vision's subject (the one under `point`, else all of them) as the preview,
  /// one undo step. Clears SAM's points: the two don't combine.
  func selectSubject(at point: CGPoint? = nil, model: CreateModel, undoManager: UndoManager? = nil) {
    guard model.canPaintMask else { return }
    follow(model.image)
    change(
      to: AutoMaskPrompt(subject: true, subjectPoint: point), actionName: "Select Subject", model: model,
      undoManager: undoManager)
  }

  /// Picks SAM's size. With a selection under way that starts it over, so it's an undo step that
  /// puts the size and the selection back.
  func setSize(_ newSize: SAMFiles.Size, model: CreateModel, undoManager: UndoManager?) {
    guard newSize != size else { return }
    guard !prompt.isEmpty else {
      size = newSize
      return
    }
    swapSize(to: newSize, prompt: AutoMaskPrompt(), model: model, undoManager: undoManager)
  }

  /// Sets the size and the selection together, as one undo step that swaps back to the ones
  /// before (and its redo to these): undoing a size change brings back the size and the points
  /// it cleared.
  private func swapSize(to newSize: SAMFiles.Size, prompt newPrompt: AutoMaskPrompt, model: CreateModel, undoManager: UndoManager?) {
    let before = (size: size, prompt: prompt)
    // The size's own didSet starts over; then the selection to go with it.
    size = newSize
    select(newPrompt, model: model)
    guard let undoManager, let image = model.canvasUndoImage, image === self.image else { return }
    model.registerCanvasUndo(on: image, undoManager: undoManager, actionName: "Change SAM Size") { [weak self, weak model] in
      guard let self, let model, self.image === image else { return }
      self.swapSize(to: before.size, prompt: before.prompt, model: model, undoManager: undoManager)
    }
  }

  /// Makes `prompt` the selection's and selects again, as one undo step named `actionName` that
  /// puts back the one before (and redoes this). For the Select tool's own changes and a
  /// commit's clearing of the points.
  func change(to prompt: AutoMaskPrompt, actionName: String, model: CreateModel, undoManager: UndoManager?) {
    let before = self.prompt
    select(prompt, model: model)
    guard before != prompt, let undoManager, let image = model.canvasUndoImage, image === self.image else { return }
    model.registerCanvasUndo(on: image, undoManager: undoManager, actionName: actionName) { [weak self, weak model] in
      guard let self, let model, self.image === image else { return }
      self.change(to: before, actionName: actionName, model: model, undoManager: undoManager)
    }
  }

  /// Selects from points that waited under a run's preview, once their image shows again.
  func resumeSelecting(model: CreateModel) {
    guard selectionWaits, let image, model.image === image, model.canEditMask else { return }
    select(prompt, model: model)
  }

  /// Shows `prompt`'s selection: SAM's or Vision's, run again (the newest run wins, `run`), or
  /// none.
  private func select(_ prompt: AutoMaskPrompt, model: CreateModel) {
    task?.cancel()
    task = nil
    points = prompt.points
    box = prompt.box
    subject = prompt.subject
    subjectPoint = prompt.subjectPoint
    failure = nil
    selectionWaits = false
    // Under a run's preview the image can't be selected on; its points wait for it.
    if !prompt.isEmpty, !model.canEditMask, model.canvasUndoImage === image, model.image !== image {
      preview = nil
      isBusy = false
      selectionWaits = true
      return
    }
    if prompt.subject {
      let point = prompt.subjectPoint
      run(model) { model in try await model.subjectSelection(at: point).selection }
    } else if hasPrompt {
      segment(model)
    } else {
      preview = nil
      isBusy = false
    }
  }

  private func segment(_ model: CreateModel) {
    let prompt = SAMSegmenter.Prompt(points: points, box: box)
    let size = size
    run(model) { model in try await model.samSelection(prompt, size: size).selection }
  }

  private func run(_ model: CreateModel, _ work: @escaping @MainActor (CreateModel) async throws -> AutoMaskSelection) {
    task?.cancel()
    isBusy = true
    failure = nil
    task = Task {
      do {
        let selection = try await work(model)
        try Task.checkCancellation()
        preview = selection
      } catch is CancellationError {
        return
      } catch {
        // A newer selection took over: its own result (or failure) is the one to show.
        guard !Task.isCancelled else { return }
        preview = nil
        failure = error.localizedDescription
      }
      isBusy = false
    }
  }

  /// The preview tint: blue, so it reads apart from the mask's red.
  nonisolated static func tint(_ coverage: [UInt8], width: Int, height: Int, maxSide: Int = 1024) -> CGImage? {
    let scale = min(1, Double(maxSide) / Double(max(width, height, 1)))
    let tintWidth = max(Int((Double(width) * scale).rounded()), 1), tintHeight = max(Int((Double(height) * scale).rounded()), 1)
    var rgba = [UInt8](repeating: 0, count: tintWidth * tintHeight * 4)
    var any = false
    for y in 0..<tintHeight {
      let sourceRow = min(y * height / tintHeight, height - 1) * width
      for x in 0..<tintWidth where coverage[sourceRow + min(x * width / tintWidth, width - 1)] != 0 {
        // Premultiplied: a light blue at half strength.
        let index = (y * tintWidth + x) * 4
        rgba[index] = 20
        rgba[index + 1] = 90
        rgba[index + 2] = 128
        rgba[index + 3] = 128
        any = true
      }
    }
    guard any, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    return CGImage(
      width: tintWidth, height: tintHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tintWidth * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}

// MARK: - Auto masking from the Create screen

/// Auto masking for the Select tool and for callers without the view (scripted checks, and the
/// agent tool to come): select with SAM's points and box or Vision's subject, then put the
/// selection into the canvas mask as one undo step, as a brush stroke is.
extension CreateModel {
  /// The undo action name for auto masks.
  static let autoMaskActionName = "Auto Mask"

  /// SAM 2.1's selection for `prompt` (image pixels) on the canvas image, with its timing.
  func samSelection(_ prompt: SAMSegmenter.Prompt, size: SAMFiles.Size? = nil) async throws -> (selection: AutoMaskSelection, result: SAMSegmenter.Result) {
    guard canEditMask, let image else { throw AutoMaskError.cannotPaint }
    guard !prompt.isEmpty else { throw AutoMaskError.emptyPrompt }
    let size = size ?? autoMask.size
    guard let files = SAMFiles.installed(size) else { throw AutoMaskError.notDownloaded(size) }
    let result = try await SAMSegmenter.shared.segment(image, prompt: prompt, files: files)
    guard self.image === image else { throw AutoMaskError.imageChanged }
    let selection = await Self.selection(result.coverage, width: result.width, height: result.height, image: image)
    return (selection, result)
  }

  /// Vision's subject selection on the canvas image: the subject under `point` (image pixels),
  /// else every subject.
  func subjectSelection(at point: CGPoint? = nil) async throws -> (selection: AutoMaskSelection, time: Duration) {
    guard canEditMask, let image else { throw AutoMaskError.cannotPaint }
    let clock = ContinuousClock()
    let start = clock.now
    let coverage = try await Task.detached(priority: .userInitiated) { try SubjectMask.coverage(image, at: point) }.value
    guard self.image === image else { throw AutoMaskError.imageChanged }
    let selection = await Self.selection(coverage, width: image.width, height: image.height, image: image)
    return (selection, clock.now - start)
  }

  /// The selection with its tint, pixel count and mask stroke, all worked out off the main actor.
  private static func selection(_ coverage: [UInt8], width: Int, height: Int, image: CGImage) async -> AutoMaskSelection {
    let (tint, count, stroke) = await Task.detached(priority: .userInitiated) {
      let count = coverage.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
      let stroke = count == 0 ? nil : SAMGeometry.grayImage(coverage, width: width, height: height).flatMap { CanvasMask.Stroke.bitmap($0) }
      return (AutoMaskSession.tint(coverage, width: width, height: height), count, stroke)
    }.value
    return AutoMaskSelection(
      coverage: coverage, width: width, height: height, image: image, tint: tint, selectedPixels: count, stroke: stroke)
  }

  /// Puts `selection` into the canvas mask (`mode`), as one undo step. False when it can't: the
  /// image changed, the selection is empty, the mask can't be painted (adding and replacing need
  /// a target that takes masks; subtracting only a mask to subtract from).
  @discardableResult
  func commitAutoMask(_ selection: AutoMaskSelection, mode: AutoMaskMode, actionName: String = autoMaskActionName, undoManager: UndoManager?) -> Bool {
    guard let image, image === selection.image,
          mode == .subtract ? canEditMask && canvasMask != nil : canPaintMask,
          let stroke = selection.stroke
    else { return false }
    setMask(mode.applied(stroke, to: canvasMask), actionName: actionName, undoManager: undoManager)
    return true
  }

  /// The Select tool's Add / Subtract / Replace: commits the preview and clears the points, as one
  /// undo step (“Add Selection”, “Subtract Selection”, “Replace Mask”). Undoing it puts back both
  /// the mask and the clicks and box it was selected with, to go on refining the selection.
  @discardableResult
  func commitAutoMaskPreview(mode: AutoMaskMode, undoManager: UndoManager?) -> Bool {
    guard let preview = autoMask.preview else { return false }
    undoManager?.beginUndoGrouping()
    defer { undoManager?.endUndoGrouping() }
    guard commitAutoMask(preview, mode: mode, actionName: mode.actionName, undoManager: undoManager) else { return false }
    autoMask.change(to: AutoMaskPrompt(), actionName: mode.actionName, model: self, undoManager: undoManager)
    return true
  }

  /// Selects with SAM 2.1 (points and box in image pixels) and commits it to the mask.
  func autoMask(
    points: [SAMSegmenter.Point], box: CGRect? = nil, mode: AutoMaskMode, size: SAMFiles.Size? = nil,
    actionName: String = autoMaskActionName, undoManager: UndoManager?
  ) async throws -> AutoMaskOutcome {
    try checkCanCommit(mode)
    let (selection, result) = try await samSelection(SAMSegmenter.Prompt(points: points, box: box), size: size)
    let selected = selection.selectedPixels
    guard selected > 0 else { throw AutoMaskError.nothingSelected }
    try checkCanCommit(mode)
    guard commitAutoMask(selection, mode: mode, actionName: actionName, undoManager: undoManager) else { throw AutoMaskError.cannotPaint }
    return AutoMaskOutcome(
      stats: canvasMaskStats, selectedPixels: selected, score: result.score, encodeTime: result.encodeTime,
      decodeTime: result.decodeTime)
  }

  /// Selects the subject (under `point`, image pixels, else all) with Vision and commits it.
  func autoMaskSubject(
    at point: CGPoint? = nil, mode: AutoMaskMode, actionName: String = autoMaskActionName, undoManager: UndoManager?
  ) async throws -> AutoMaskOutcome {
    try checkCanCommit(mode)
    let (selection, time) = try await subjectSelection(at: point)
    let selected = selection.selectedPixels
    guard selected > 0 else { throw AutoMaskError.nothingSelected }
    try checkCanCommit(mode)
    guard commitAutoMask(selection, mode: mode, actionName: actionName, undoManager: undoManager) else { throw AutoMaskError.cannotPaint }
    return AutoMaskOutcome(stats: canvasMaskStats, selectedPixels: selected, score: nil, encodeTime: nil, decodeTime: time)
  }

  /// Why `mode` can't go into the mask now, checked before running a model and again after.
  private func checkCanCommit(_ mode: AutoMaskMode) throws {
    if mode == .subtract {
      guard canEditMask else { throw AutoMaskError.cannotPaint }
      guard canvasMask != nil else { throw AutoMaskError.noMaskToSubtract }
    } else {
      guard canPaintMask else { throw AutoMaskError.cannotPaint }
    }
  }
}
