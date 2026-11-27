import CoreGraphics
import Foundation
import Observation

/// The Edit screen's state, owned by `AtelierApp` and handed down with `.environment`, as the
/// Video Editor's `TimelineStore` is: the image being edited, its look (`options`), and what the
/// look is rendered with (`context`: the profile's grain data, the match target's measurements,
/// the LUT). It lives as long as the app, so the image and look survive switching screens.
///
/// Editing is non-destructive: the screen always renders the *source* with the options. A step
/// saved from here records its look (`Edit.Record`), so opening it again goes back to its source
/// with that look rather than adding grain over grain.
///
/// Agents (`edit_image_look`) and scripted checks drive it through the calls the screen makes:
/// `open(_:)`, `open(image:name:)`, `options`, `applyProfile(_:)`, `setReference(image:name:tensorId:)`,
/// `matchReference()`, `loadLUT(from:)`, `save()`, `addToHistory()`, `exportPNG()`, `exportLUT(name:)`,
/// and for the tools `tool`, `setCrop(_:actionName:undoManager:)`, `setCropAspect(_:undoManager:)`,
/// `setHealSource(at:)`, `addHealStroke(points:undoManager:)`, `clearHeal(undoManager:)`.
///
/// The retouch (`Edit.Retouch`: Heal strokes, then the crop) is per image and goes on the source
/// before the look: the panes render `workingImage`, the source with it, as they rendered the
/// source before, so the renderer's caches need no change.
@MainActor
@Observable
final class EditModel {
  /// Where the image being edited came from.
  enum Source: Equatable {
    /// A step of a project, by its tensor (an input entry's key for an entry): what Save to
    /// History saves after.
    case step(project: String, tensorId: Int64)
    /// A file or photo that isn't in History: Export, or Add to History first.
    case file(name: String)
  }

  /// An image the matches move toward, measured once: a reference the user chose, or the
  /// step's original (`Match.Target`).
  struct Reference {
    var name: String
    /// Its step in the source's project, when it's one; the saved record names it.
    var tensorId: Int64?
    var lab: Edit.LabStats?
    var histogram: Edit.HistogramTable?
    /// The image, while it's at hand (not for one brought back from a saved record), for
    /// Match Reference.
    var image: CGImage?
  }

  /// The Create screen's model: History, the queue, the moodboard and the canvas.
  @ObservationIgnored weak var create: CreateModel?

  // MARK: Source

  private(set) var source: Source?
  /// The step, for a `.step` source.
  private(set) var item: HistoryItem?
  /// The source's pixels. One instance per source, which the renderer's caches are keyed by;
  /// `renderer.forget` drops them when it's replaced.
  private(set) var image: CGImage?
  /// A fitted copy of `workingOriginal` for the original's side of a comparison.
  private(set) var originalPreview: CGImage?
  /// The source with the retouch, which the panes render the look over: the crop applied, except
  /// while Crop is the tool, which shows the whole image with the crop drawn over it. One instance
  /// per retouch, as `image` is per source, for the renderer's caches.
  private(set) var workingImage: CGImage?
  /// The comparison's original: the source with the crop the panes show but not the Heal strokes,
  /// so Side by Side, the Slider and Hold for Original show the marks the strokes took out, pixel
  /// for pixel over the edit.
  private(set) var workingOriginal: CGImage?
  /// Where `workingImage` sits in the source: the applied crop's origin, (0, 0) uncropped. A
  /// fitted render stands in only for a working image at the same place (`EditRenderTarget.stands`).
  private(set) var workingOrigin: (x: Int, y: Int) = (0, 0)
  /// Reading a step or file.
  private(set) var isLoading = false

  // MARK: Tools and retouch

  /// The tool a drag on the image uses (the bottom bar's picker). Not remembered: the screen
  /// starts with Move. Picking a one-pane tool while Side by Side or the Slider is chosen goes to
  /// Hold for Original (D5); picking Crop shows the whole image fitted; leaving it applies it.
  var tool: EditTool = .move {
    didSet {
      guard tool != oldValue else { return }
      if tool.needsSinglePane, compareMode != .hold { compareMode = .hold }
      // Set Source is the Heal tool's: armed and left, it would catch the next tool's click.
      if oldValue == .heal { isSettingHealSource = false }
      // The whole image fitted the first time for an image; coming back, the zoom Crop was left
      // at (the image it shows is the same whole image again).
      if oldValue == .crop { cropView = (canvas.scale, canvas.offset) }
      if tool == .crop {
        if let cropView {
          canvas.scale = cropView.scale
          canvas.offset = cropView.offset
        } else {
          canvas.zoomToFit()
        }
      }
      updateWorking()
    }
  }

  /// What's done to the source's pixels before the look: Heal strokes, then the crop. Per image:
  /// cleared when another opens, brought back from a saved step's record. Changed through
  /// `setCrop` and `setHeal`.
  private(set) var retouch = Edit.Retouch.none

  /// The crop that applies to the source: nil for none, or one taking the whole image.
  var effectiveCrop: Edit.Crop? {
    guard let image else { return nil }
    return EditRetouch.effectiveCrop(retouch.crop, imageWidth: image.width, imageHeight: image.height)
  }

  /// The size the edit saves and exports at: the crop's, or the source's.
  var outputSize: (width: Int, height: Int)? {
    guard let image else { return nil }
    if let crop = effectiveCrop { return (crop.width, crop.height) }
    return (image.width, image.height)
  }

  /// Sets the crop (nil: none), one undo step named `actionName` on `undoManager` (the window's,
  /// shared with the other screens, D12). Kept inside the image and in whole pixels. The overlay
  /// calls it when a drag ends, as do the Crop bar, `crop_image`'s checks and the scripted check.
  func setCrop(_ crop: Edit.Crop?, actionName: String = "Crop", undoManager: UndoManager?) {
    guard let image else { return }
    let new = crop.flatMap { $0.clamped(imageWidth: image.width, imageHeight: image.height) }
    let old = retouch.crop
    guard new != old else { return }
    retouch.crop = new
    if let undoManager {
      retouchUndoManager = undoManager
      let source = ObjectIdentifier(image)
      undoManager.registerUndo(withTarget: self) { model in
        // Another image since: the step was dropped when it opened (`setSource`), but never put
        // this image's crop on another.
        guard model.image.map(ObjectIdentifier.init) == source else { return }
        model.setCrop(old, actionName: actionName, undoManager: undoManager)
      }
      undoManager.setActionName(actionName)
    }
    saveRetouchSession()
    updateWorking()
  }

  /// Reset Crop: no crop (D6: the bottom bar's Reset is the look's alone).
  func resetCrop(undoManager: UndoManager?) {
    setCrop(nil, actionName: "Reset Crop", undoManager: undoManager)
  }

  /// The Aspect menu's choice: Free (nil) keeps the rectangle and lets it go free; a ratio holds
  /// the crop to it about its centre at about its area, or with no crop takes the largest of it.
  func setCropAspect(_ aspect: Edit.CropAspect?, undoManager: UndoManager?) {
    guard let image else { return }
    guard let aspect else {
      if var crop = retouch.crop {
        crop.aspect = nil
        crop.swapped = false
        setCrop(crop, undoManager: undoManager)
      }
      return
    }
    setCrop(Self.held(retouch.crop, to: aspect, swapped: false, width: image.width, height: image.height), undoManager: undoManager)
  }

  /// Orientation: the crop's ratio turned on its side (4:5 to 5:4), about its centre.
  func swapCropOrientation(undoManager: UndoManager?) {
    guard let image, let crop = retouch.crop, let aspect = crop.aspect, aspect.canSwap else { return }
    let turned = aspect.swapping(crop.swapped)
    setCrop(Self.held(crop, to: turned.aspect, swapped: turned.swapped, width: image.width, height: image.height), undoManager: undoManager)
  }

  /// Whether Orientation can turn the crop: it's held to a ratio other than 1:1.
  var canSwapCropOrientation: Bool { retouch.crop?.aspect?.canSwap == true }

  /// `crop` (the whole image for none) held to `aspect`, as a crop of a `width` × `height` image.
  nonisolated static func held(_ crop: Edit.Crop?, to aspect: Edit.CropAspect, swapped: Bool, width: Int, height: Int) -> Edit.Crop? {
    let bounds = CGSize(width: width, height: height)
    let ratio = aspect.ratio(imageWidth: width, imageHeight: height, swapped: swapped)
    let rect = crop.map { CropGeometry.fitting($0.rect, ratio: ratio, in: bounds) } ?? CropGeometry.largest(ratio: ratio, in: bounds)
    return Edit.Crop(rect: rect, imageWidth: width, imageHeight: height, aspect: aspect, swapped: swapped)
  }

  // MARK: Heal

  /// The heal brush's radius in image pixels (D7: a 32 px spot is 32 px of the photo at any zoom;
  /// the outline scales with the zoom), apart from Create's two brush sizes. Remembered. Up to
  /// `HealBrush.maxRadius`, the most a stroke is applied with.
  var healBrushSize: Double {
    didSet {
      let kept = Self.keptHealBrushSize(healBrushSize)
      if kept != healBrushSize { healBrushSize = kept }
      if SessionState.isEnabled { UserDefaults.standard.set(healBrushSize, forKey: Self.healBrushSizeKey) }
    }
  }

  /// The Heal Brush Size menu's choices.
  static let healBrushSizes: [Double] = [4, 8, 16, 32, 64, 128, 256]

  nonisolated static func keptHealBrushSize(_ size: Double) -> Double {
    size.isFinite ? min(max(size, 1), Double(HealBrush.maxRadius)) : 32
  }

  /// Where the next stroke copies from (Aligned, `Edit.HealSource`): set by Option-click or Set
  /// Source, fixed as an offset by the first stroke after. The session's and this image's, never
  /// saved: only each stroke's offset is. Nil until one is set: painting then does nothing.
  private(set) var healSource: Edit.HealSource?
  /// Where the source crosshair rests while no stroke is being painted: the point set, or after a
  /// stroke its last point plus the offset (where the next stroke from there would copy from).
  private(set) var healSourceRest: SIMD2<Float>?
  /// The Heal bar's Set Source toggle: the next click or tap on the image sets the source rather
  /// than painting, and turns it off.
  var isSettingHealSource = false

  /// The strokes healed into `workingImage` so far: `retouch.heal` once healing has caught up.
  private(set) var appliedHeal = Edit.HealStrokes.empty

  /// Strokes are being healed into the picture.
  var isHealing: Bool { appliedHeal != retouch.heal }

  /// Strokes added but not healed in yet, which the overlay outlines meanwhile.
  var unappliedHealStrokes: ArraySlice<Edit.HealStroke> {
    let strokes = retouch.heal.strokes
    guard strokes.count > appliedHeal.strokes.count, strokes.starts(with: appliedHeal.strokes) else { return [] }
    return strokes[appliedHeal.strokes.count...]
  }

  /// The source point (Option-click, or a click with Set Source on), in image pixels, kept on the
  /// image; Set Source goes off.
  func setHealSource(at point: CGPoint) {
    guard let image, point.x.isFinite, point.y.isFinite else { return }
    let kept = SIMD2(Float(min(max(point.x, 0), Double(image.width))), Float(min(max(point.y, 0), Double(image.height))))
    healSource = .point(kept)
    healSourceRest = kept
    isSettingHealSource = false
  }

  /// A stroke painted through `points` (image pixels) at the brush size, from the source: one
  /// undo step, "Heal". False, and nothing done, with no source set (or no image, or no point):
  /// painting before a source is set does nothing.
  @discardableResult
  func addHealStroke(points: [CGPoint], undoManager: UndoManager?) -> Bool {
    guard let image else { return false }
    let radius = Float(Self.keptHealBrushSize(healBrushSize))
    // Kept within a brush's reach of the image: further out a point touches nothing, and an
    // untrusted value never reaches the stroke's encoding.
    let reach = Double(radius)
    let kept = points.compactMap { point -> SIMD2<Float>? in
      guard point.x.isFinite, point.y.isFinite else { return nil }
      return SIMD2(
        Float(min(max(point.x, -reach), Double(image.width) + reach)), Float(min(max(point.y, -reach), Double(image.height) + reach)))
    }
    var source = healSource
    guard let stroke = Edit.HealSource.stroke(points: kept, radius: radius, source: &source), let last = kept.last else { return false }
    healSource = source
    healSourceRest = last + stroke.offset
    var strokes = retouch.heal
    strokes.strokes.append(stroke)
    setHeal(strokes, actionName: "Heal", undoManager: undoManager)
    return true
  }

  /// Clear Heal: no strokes (D6: Reset is the look's alone), one undo step, "Clear Heal".
  func clearHeal(undoManager: UndoManager?) {
    guard !retouch.heal.isEmpty else { return }
    setHeal(.empty, actionName: "Clear Heal", undoManager: undoManager)
  }

  /// Sets the strokes, one undo step named `actionName` on `undoManager` (the window's, D12), and
  /// heals them into the picture off the main actor (only the new ones when they follow on).
  func setHeal(_ strokes: Edit.HealStrokes, actionName: String = "Heal", undoManager: UndoManager?) {
    guard let image, strokes != retouch.heal else { return }
    let old = retouch.heal
    retouch.heal = strokes
    if let undoManager {
      retouchUndoManager = undoManager
      let source = ObjectIdentifier(image)
      undoManager.registerUndo(withTarget: self) { model in
        guard model.image.map(ObjectIdentifier.init) == source else { return }
        model.setHeal(old, actionName: actionName, undoManager: undoManager)
      }
      undoManager.setActionName(actionName)
    }
    saveRetouchSession()
    healCanvas.update(strokes)
  }

  /// Waits until the strokes are healed into the picture (checks and benches).
  func settleHeal() async {
    await healCanvas.settle()
  }

  /// The step opened records a crop or strokes (`restore`): taking them off is kept across a quit.
  @ObservationIgnored private var recordedRetouch = false

  /// The source's healed pixels, kept from stroke to stroke (`HealCanvas`).
  @ObservationIgnored private let healCanvas = HealCanvas()

  /// The healing caught up: the new healed picture goes up.
  private func healPublished() {
    appliedHeal = healCanvas.applied
    updateWorking()
  }

  /// The zoom Crop was last left at for this image, which coming back to Crop restores.
  @ObservationIgnored private var cropView: (scale: Double?, offset: CGSize)?
  /// The undo manager the retouch's steps went on, so they're dropped when another image opens.
  @ObservationIgnored private weak var retouchUndoManager: UndoManager?
  /// What `workingImage` and `workingOriginal` were made from, so the same retouch doesn't make a
  /// new image (and new cache entries) each time.
  private struct WorkingKey: Equatable {
    var source: ObjectIdentifier
    /// The healed picture (the source with no strokes).
    var healed: ObjectIdentifier
    var crop: Edit.Crop?
  }

  @ObservationIgnored private var workingKey: WorkingKey?
  @ObservationIgnored private var originalKey: WorkingKey?
  /// The source fitted once, for the original's side while it isn't cropped.
  @ObservationIgnored private var sourcePreview: CGImage?

  /// Makes `workingImage` and `workingOriginal` again for the source, retouch and tool, if they
  /// changed: the working image is the healed picture cropped (whole while Crop is the tool), the
  /// original the source cropped the same way, unhealed. An image replaced is let go by the
  /// renderer; the source's own entry stays, as going back into Crop shows it again.
  private func updateWorking() {
    guard let image else {
      workingKey = nil
      originalKey = nil
      workingImage = nil
      workingOriginal = nil
      return
    }
    let crop = tool == .crop ? nil : effectiveCrop
    let healed = healCanvas.image ?? image
    let key = WorkingKey(source: ObjectIdentifier(image), healed: ObjectIdentifier(healed), crop: crop?.renderKey)
    if key != workingKey || workingImage == nil {
      workingKey = key
      let working = EditRetouch.cropped(crop, healed)
      workingOrigin = (crop?.x ?? 0, crop?.y ?? 0)
      if let old = workingImage, old !== working, old !== image { forget(old) }
      workingImage = working
    }
    let originalKey = WorkingKey(source: ObjectIdentifier(image), healed: ObjectIdentifier(image), crop: crop?.renderKey)
    guard originalKey != self.originalKey || workingOriginal == nil else { return }
    self.originalKey = originalKey
    let original = EditRetouch.cropped(crop, image)
    if let old = workingOriginal, old !== original, old !== image, old !== workingImage { forget(old) }
    workingOriginal = original
    if original === image, let sourcePreview {
      originalPreview = sourcePreview
    } else {
      originalPreview = nil
      Task {
        let fitted = await Self.fitted(original)
        if self.workingOriginal === original {
          originalPreview = fitted
          if original === image { sourcePreview = fitted }
        }
      }
    }
  }

  /// Lets the renderer drop what it kept for `image`.
  private func forget(_ image: CGImage) {
    let renderer = renderer
    Task { await renderer.forget(image) }
  }

  /// Keeps the open step's crop and strokes for the next launch (D10), saved or not; when they've
  /// been taken off a step that recorded some, that they're off (`EditRetouchSession.cleared`), so
  /// the record's don't come back. Forgets them when there's nothing either way.
  private func saveRetouchSession() {
    guard SessionState.isEnabled else { return }
    if case .step(let project, let tensorId) = source,
       let kept = EditRetouchSession.keeping(project: project, tensorId: tensorId, retouch: retouch, recorded: recordedRetouch)
    {
      kept.save()
    } else {
      EditRetouchSession.clear()
    }
  }

  // MARK: Look

  /// The look, always snapped (`EditOptions.snapped`), so the same settings make the same job
  /// and the same cache keys. Remembered for the next launch (`rememberedSave`).
  var options: EditOptions {
    get { storedOptions }
    set {
      let snapped = newValue.snapped
      let fromSlider = sliderChanging
      sliderChanging = false
      guard snapped != storedOptions else { return }
      lastChangeIsFinal = !fromSlider
      storedOptions = snapped
      if SessionState.isEnabled { rememberedSave.schedule(snapped) }
    }
  }

  /// What the panes render: the look with each stage that's off as no change
  /// (`EditOptions.rendered`), so turning off a stage that does nothing doesn't render again.
  /// The renderer takes `rendered` itself too, so Save and Export… render the same.
  var renderedOptions: EditOptions { options.rendered }

  /// A stage's checkbox: turns it on or off, its settings kept. Through `options`, so it's a
  /// settled change (a full render) and remembered.
  func setStage(_ stage: EditOptions.Stage, on: Bool) {
    options = options.setting(stage, on: on)
  }

  /// The Look checkbox: the whole look on or off (`EditOptions.lookOff`), the stages' own
  /// checkboxes and every setting left as they are. Through `options`, as `setStage` is.
  func setLook(on: Bool) {
    options.lookOff = !on
  }

  /// Remembering the look: encoded and written to UserDefaults half a second after the last
  /// change, rather than on each of a slider's 16 ms ticks, and at once when a slider is let go,
  /// the app goes to the background or quits (`flushRemembered`), so nothing is lost.
  @ObservationIgnored private let rememberedSave = DebouncedSave<EditOptions>(delay: .milliseconds(500)) { EditModel.remember($0) }

  /// Writes the look now if a change to it is waiting to be remembered.
  func flushRemembered() { rememberedSave.flush() }

  private var storedOptions: EditOptions

  /// How the original is compared with the edit. Remembered. One that shows two panes (or splits
  /// one) leaves a one-pane tool for Move, which applies the crop, as picking that tool goes to
  /// Hold (D5).
  var compareMode: Compare.Mode {
    didSet {
      if SessionState.isEnabled { UserDefaults.standard.set(compareMode.rawValue, forKey: Self.compareModeKey) }
      if compareMode != .hold, tool.needsSinglePane { tool = .move }
    }
  }

  /// The loaded grain profile: from the library, a file, Match Reference, or a saved step's
  /// record. Its grain data goes into `context`.
  private(set) var profile: GrainProfile?
  /// The reference the user chose (`Match.Target.reference`).
  private(set) var reference: Reference?
  /// The source step's original (`Match.Target.original`), measured when the step is opened.
  private(set) var original: Reference?
  /// The loaded LUT, a built-in or one from a file.
  private(set) var lut: Edit.LUTTable?
  /// The LUT last loaded from a file (or kept in the opened step), so the LUT menu can go back to
  /// it after trying a built-in. Remove and Reset let it go.
  private(set) var fileLUT: Edit.LUTTable?
  /// The built-in `lut` is, nil for a file's or none.
  var builtInLUTName: String? { BuiltInLUTs.name(of: lut) }

  /// What the look renders with, rebuilt whenever the profile, reference, original, LUT or
  /// match target change. `contextVersion` counts the rebuilds: the render tasks key on it rather
  /// than hashing the real-noise patches and LUT each time the view updates.
  private(set) var context = EditPipeline.Context.empty
  private(set) var contextVersion = 0

  /// "Ref vs ours" after Match Reference: the reference's grain statistics beside the closest
  /// synthetic grain's.
  private(set) var matchReport: String?
  /// What the screen says in its bottom bar: a problem, or what just happened.
  var note: String?
  /// A saved step whose real noise or LUT data is gone from its project: those settings can't be
  /// rendered, so Real Noise and the LUT are off and disabled with this note.
  private(set) var missingDataNote: String?
  /// Measuring a reference (Choose…, Match Reference).
  private(set) var isMeasuring = false
  /// Exporting a PNG or LUT.
  private(set) var isExporting = false
  /// Add to History is saving the entry.
  private(set) var isAdding = false

  // MARK: Rendering

  /// The preview's zoom: `scale` is screen pixels per image pixel (1 is 100%), `offset` view points.
  let canvas = CanvasState()
  let renderer = EditRenderer()
  let profiles: GrainProfileStore

  /// One of a preview pane's renders: its fitted preview, its zoomed window or the Slider's
  /// preview. Each pane has its own id, so Side by Side's panes are apart.
  struct RenderLane: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
      case fitted, window, slider
    }

    var pane: UUID
    var kind: Kind
  }

  /// The renders under way, for the panes' busy spinners. A pane begins and ends each lane as its
  /// `EditRenderLoop` turns busy and idle, which stays busy from one render straight to the next,
  /// so the spinner doesn't flicker off between them. A pane that goes away ends its lanes
  /// (`endRenders(pane:)`).
  private(set) var pendingRenders: Set<RenderLane> = []

  func beginRender(_ lane: RenderLane) {
    if !pendingRenders.contains(lane) { pendingRenders.insert(lane) }
  }

  func endRender(_ lane: RenderLane) {
    if pendingRenders.contains(lane) { pendingRenders.remove(lane) }
  }

  func endRenders(pane: UUID) {
    if pendingRenders.contains(where: { $0.pane == pane }) { pendingRenders = pendingRenders.filter { $0.pane != pane } }
  }

  /// Inspector sliders being dragged (`EditSlider`): more than one at once with several fingers
  /// on iPad. While any is, the panes' renders let one of an older value finish and go up before
  /// the newest (`EditRenderLoop`); let go, the look is final and a stale render stops for it.
  private(set) var adjustingCount = 0
  var isAdjusting: Bool { adjustingCount > 0 }

  func adjusting(_ editing: Bool) {
    adjustingCount = max(0, adjustingCount + (editing ? 1 : -1))
    if !editing { flushRemembered() }
  }

  /// Whether the last change to the look is final: false for a slider's (dragged, or moved with
  /// the arrow keys, which say nothing when they stop), so the render on its way finishes first;
  /// true for a toggle, picker, typed value or new profile, LUT or reference, which stop a stale
  /// render for themselves. Read when the panes schedule, so not observed.
  @ObservationIgnored private(set) var lastChangeIsFinal = true
  @ObservationIgnored private var sliderChanging = false

  /// Sets the look from a slider (`EditSlider`), marking the change as not final.
  func sliderChange(_ change: () -> Void) {
    sliderChanging = true
    defer { sliderChanging = false }
    change()
  }

  /// A pinch or drag is moving the preview's zoom or position now (`EditPane`'s gestures; the
  /// benches set it as one would).
  var isMovingView = false

  /// Any pane is rendering.
  var isRendering: Bool { !pendingRenders.isEmpty }

  /// `pane` is rendering, in any of its lanes.
  func isRendering(pane: UUID) -> Bool { pendingRenders.contains { $0.pane == pane } }

  init() {
    storedOptions = Self.rememberedOptions()
    let size = SessionState.isEnabled ? UserDefaults.standard.double(forKey: Self.healBrushSizeKey) : 0
    healBrushSize = size > 0 ? Self.keptHealBrushSize(size) : 32
    compareMode = SessionState.isEnabled
      ? UserDefaults.standard.string(forKey: Self.compareModeKey).flatMap(Compare.Mode.init) ?? .hold : .hold
    // A scripted run keeps its profiles out of the user's library.
    profiles = SessionState.isEnabled
      ? GrainProfileStore()
      : GrainProfileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Atelier Grain Profiles (scripted)"))
    if SessionState.isEnabled {
      // The model lives as long as the app, so these are never taken off.
      AppLifecycle.onResignActive { [weak self] in self?.flushRemembered() }
      AppLifecycle.onWillTerminate { [weak self] in self?.flushRemembered() }
    }
    healCanvas.prime = { [weak self] image, pixels in
      // Only a picture the panes will render as it is: a cropped one is a new image anyway.
      guard let self, tool == .crop || effectiveCrop == nil else { return }
      await renderer.prime(image, rgba: pixels)
    }
    healCanvas.published = { [weak self] in self?.healPublished() }
  }

  var hasSource: Bool { image != nil }

  /// The source's name for the screen's title: "Project, step 12" or the file's name.
  var sourceTitle: String {
    switch source {
    case .step(let project, _):
      guard let item else { return project }
      if let reason = item.entryReason { return "\(project), \(reason.title) entry" }
      return "\(project), step \(item.id.logicalTime)"
    case .file(let name): return name
    case nil: return "No Image"
    }
  }

  /// The source is a file or photo, not a step: Save to History needs Add to History first.
  var isFromFile: Bool { if case .file = source { true } else { false } }

  // MARK: - Opening

  /// Opens `item`, a step of the current project (the canvas's, or History's). A step saved from
  /// here opens as its source with its look and what it was rendered with, so its grain isn't
  /// added twice (`reopening(_:in:)`); a piece of its data gone from the project
  /// (`Project.editData(for:)`), the look comes back with only that setting off.
  func open(_ item: HistoryItem) async {
    guard let create, !item.isVideo, item.hasImage else { return }
    let generation = beginOpen()
    defer { endOpen(generation) }
    let project = create.history.project
    note = nil
    missingDataNote = nil
    var sourceItem = item
    var restored: (record: Edit.Record, data: Edit.LoadedData)?
    if let record = item.sidecar.edit {
      if let found = Self.reopening(record, in: create.history.tree) {
        sourceItem = found
        let data = await project.read { $0.editData(for: record) }
        restored = (record, data)
      } else {
        note = "The image this edit was made from is no longer in the project, so the edit itself opens."
      }
    }
    let source = sourceItem
    guard source.hasImage, let picture = await project.read({ $0.image(for: source) })
    else {
      if opens.isCurrent(generation) { note = "The image couldn't be read." }
      return
    }
    // A newer open (another step, a file, the session's restore) came in while this one read.
    guard opens.isCurrent(generation) else { return }
    setSource(.step(project: project.name, tensorId: sourceItem.tensorId), item: sourceItem, image: picture)
    reference = nil
    matchReport = nil
    if let restored { restore(restored.record, data: restored.data) }
    rebuildContext()
    EditSession(project: project.name, tensorId: sourceItem.tensorId).save()
    saveRetouchSession()
    await measureOriginal(of: sourceItem, in: project, generation: generation)
  }

  /// The step an edited step's record says it came from, which Edit opens in its place; nil
  /// when it's gone (or isn't an image any more). A source that is itself an edited step is
  /// followed back to the first step with no record (`editSource(of:in:)`), so the look never
  /// goes on over a look.
  nonisolated static func reopening(_ record: Edit.Record, in tree: ProjectTree) -> HistoryItem? {
    imageStep(record.sourceTensorId, in: tree).map { editSource(of: $0, in: tree) }
  }

  /// What an edit of `item` starts from: `item`, or for an edited step the step its record names,
  /// and so on back to a step with no record, stopping at the last one still in the project (and
  /// at a step already passed, should records ever name each other).
  nonisolated static func editSource(of item: HistoryItem, in tree: ProjectTree) -> HistoryItem {
    editSource(of: item) { imageStep($0, in: tree) }
  }

  /// `editSource(of:in:)` over any lookup of a step by tensor id.
  nonisolated static func editSource(of item: HistoryItem, lookup: (Int64) -> HistoryItem?) -> HistoryItem {
    var current = item
    var passed: Set<Int64> = [item.tensorId]
    while let record = current.sidecar.edit, let next = lookup(record.sourceTensorId), passed.insert(next.tensorId).inserted {
      current = next
    }
    return current
  }

  /// The image step `tensorId` names in `tree`; nil for a video, an empty entry or none.
  private nonisolated static func imageStep(_ tensorId: Int64, in tree: ProjectTree) -> HistoryItem? {
    tree.step(tensorId: tensorId).flatMap { tree.items[$0] }.flatMap { $0.isVideo || !$0.hasImage ? nil : $0 }
  }

  /// Opens an image that isn't a step (a file, a photo, a canvas image from outside the
  /// project): it can be exported, or added to History to save edits after it.
  func open(image: CGImage, name: String) {
    let generation = beginOpen()
    show(image: image, name: name)
    endOpen(generation)
  }

  /// `open(image:name:)` once the open is known to be the latest.
  private func show(image: CGImage, name: String) {
    note = nil
    missingDataNote = nil
    setSource(.file(name: name), item: nil, image: image)
    original = nil
    reference = reference.map { var kept = $0; kept.tensorId = nil; return kept }
    rebuildContext()
    EditSession.clear()
    saveRetouchSession()
  }

  /// Opens an image file (Open Image…, a drop), read off the main actor with security-scoped access.
  func open(url: URL) async {
    let generation = beginOpen()
    defer { endOpen(generation) }
    let image = await Self.decode(url)
    guard opens.isCurrent(generation) else { return }
    guard let image else {
      note = "“\(url.lastPathComponent)” couldn't be read as an image."
      return
    }
    show(image: image, name: url.deletingPathExtension().lastPathComponent)
  }

  /// Opens a photo from the library (Open from Photos…), decoded off the main actor.
  func open(photo data: Data) async {
    await open(data: data, name: "Photo", failure: "The photo couldn't be read.")
  }

  /// Opens what's dropped on the preview: an image file or image data (a photo dragged from
  /// Photos or a browser), as the canvas takes them (`CanvasDrop`). A video isn't for Edit.
  func open(dropped provider: NSItemProvider) async {
    let generation = beginOpen()
    defer { endOpen(generation) }
    let name = provider.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? "Dropped Image"
    let dropped: CanvasDrop?
    do {
      dropped = try await CanvasDrop.load(provider)
    } catch {
      if opens.isCurrent(generation) { note = "The dropped image couldn't be read." }
      return
    }
    guard opens.isCurrent(generation) else { return }
    switch dropped {
    case .image(let image): show(image: image.image, name: name)
    case .video: note = "Edit works on images, not videos."
    case nil: note = "Only an image can be dropped here."
    }
  }

  private func open(data: Data, name: String, failure: String) async {
    let generation = beginOpen()
    defer { endOpen(generation) }
    let image = await Self.decode(data)
    guard opens.isCurrent(generation) else { return }
    guard let image else {
      note = failure
      return
    }
    show(image: image, name: name)
  }

  /// Opens what the Create screen's canvas shows: its step, or the image itself when it isn't one.
  func openCanvasImage() async {
    guard let create, canUseCanvasImage, let image = create.image else { return }
    if let item = create.imageItem {
      await open(item)
    } else {
      open(image: image, name: "Canvas Image")
    }
  }

  /// Whether Use Canvas Image has an image to take: a finished image, not a video.
  var canUseCanvasImage: Bool {
    guard let create else { return false }
    return create.canvasShowsImage && create.imageItem?.isVideo != true
  }

  /// Brings back the step open at the last quit, once its project is the current one. Not once
  /// anything has been asked to open: a slow restore finishing after Open in Edit would replace
  /// the image the user asked for.
  func restoreSession() async {
    guard source == nil, !isLoading, !opens.anyRequested, let saved = EditSession.load(), let create,
          create.history.project.name == saved.project, let item = create.history.item(tensorId: saved.tensorId)
    else { return }
    // Read before opening, which writes the file for what it opens.
    let retouch = EditRetouchSession.load()
    await open(item)
    // The crop and strokes on the screen at the quit, saved or not (D10).
    if let retouch, case .step(let project, let tensorId) = source, retouch.project == project, retouch.tensorId == tensorId {
      let kept = retouch.retouch
      setCrop(kept.crop, undoManager: nil)
      setHeal(kept.heal, undoManager: nil)
    }
  }

  // MARK: Open generations

  /// Every open asked for, counted as it starts (before anything is read), so one that finishes
  /// after a newer one drops its result rather than replacing the newer image.
  private var opens = OpenGenerations()

  private func beginOpen() -> Int {
    isLoading = true
    return opens.begin()
  }

  private func endOpen(_ generation: Int) {
    if opens.isCurrent(generation) { isLoading = false }
  }

  @concurrent private nonisolated static func decode(_ url: URL) async -> CGImage? {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    return ImageLoader.image(at: url)
  }

  @concurrent nonisolated static func decode(_ data: Data) async -> CGImage? {
    ImageLoader.image(from: data)
  }

  @concurrent private nonisolated static func fitted(_ image: CGImage) async -> CGImage {
    ImageLoader.fitted(image, maxSide: 2048)
  }

  /// Puts `image` up as the source, dropping what the renderer kept for the last one. The fitted
  /// copy for the original's side is made off the main actor; the source stands in until then.
  private func setSource(_ source: Source, item: HistoryItem?, image: CGImage) {
    if let old = self.image, old !== image {
      let renderer = renderer
      Task { await renderer.forget(old) }
    }
    if let old = workingImage, old !== image, old !== self.image {
      let renderer = renderer
      Task { await renderer.forget(old) }
    }
    // The last image's crop steps would act on this one.
    retouchUndoManager?.removeAllActions(withTarget: self)
    self.source = source
    self.item = item
    self.image = image
    retouch = .none
    recordedRetouch = false
    healCanvas.reset(source: image)
    appliedHeal = .empty
    healSource = nil
    healSourceRest = nil
    isSettingHealSource = false
    cropView = nil
    sourcePreview = nil
    workingKey = nil
    originalKey = nil
    workingImage = nil
    workingOriginal = nil
    canvas.zoomToFit()
    updateWorking()
  }

  /// A saved step's look and data back on the screen. A setting whose data is gone from the
  /// project is turned off, and only that one (`Edit.Record.options(without:)`).
  private func restore(_ record: Edit.Record, data: Edit.LoadedData) {
    let lost = record.lost(data.missing)
    let look = record.options(without: lost)
    let context = record.context(with: data.blobs)
    missingDataNote = lost.note("This edit's")
    options = look
    // The profile as it was rendered with, under its name: its file may have changed or gone.
    profile = record.profileName.map { name in
      GrainProfile(
        name: name, refWidth: context.refWidth, settings: GrainProfile.Settings(look), curve: context.curve,
        refStats: context.refStats, real: context.realNoise)
    }
    if look.match.target == .reference, context.referenceLab != nil || context.referenceHistogram != nil {
      reference = Reference(
        name: record.referenceName ?? "Saved reference", tensorId: record.referenceTensorId, lab: context.referenceLab,
        histogram: context.referenceHistogram)
    }
    lut = context.lut
    fileLUT = builtInLUTName == nil ? lut : nil
    // The crop it was saved with, kept inside this image: a record is read from a file. The
    // strokes are checked where they're applied (`HealBrush.Brush`).
    if let image { retouch.crop = record.crop?.clamped(imageWidth: image.width, imageHeight: image.height) }
    retouch.heal = record.retouch(with: data.blobs).heal
    recordedRetouch = record.crop != nil || record.heal != nil
    healCanvas.update(retouch.heal)
    updateWorking()
  }

  /// Measures the step's input (the image it was made from) for `Match.Target.original`, shown
  /// as "Step's Input". A step made from no image has none, so that target stays disabled rather
  /// than standing in its parent, which isn't what the step was made from.
  private func measureOriginal(of item: HistoryItem, in project: Project, generation: Int) async {
    original = nil
    rebuildContext()
    guard let create, let input = await create.originalImage(for: item, in: project) else { return }
    let found = (image: input.image, tensorId: input.tensorId)
    guard let measured = try? await EditPipeline.measureReference(found.image, name: "Step's Input", profile: false),
          opens.isCurrent(generation), self.item?.tensorId == item.tensorId
    else { return }
    original = Reference(name: "Step's Input", tensorId: found.tensorId, lab: measured.lab, histogram: measured.histogram, image: found.image)
    rebuildContext()
  }

  /// The step's original, for the Reference menu's item; nil without one.
  var originalImage: CGImage? { original?.image }

  // MARK: - Look

  /// Puts `profile`'s look and grain data on the screen (nil: no profile, the grain data
  /// cleared and the settings kept). The seed stays the screen's (`Settings.applied(to:)`).
  func applyProfile(_ profile: GrainProfile?) {
    self.profile = profile
    if let profile { options = profile.settings.applied(to: options) }
    missingDataNote = nil
    matchReport = nil
    rebuildContext()
  }

  /// Opens a `.grain.json` file anywhere as the profile.
  func openProfile(at url: URL) throws {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    applyProfile(try GrainProfile.load(from: url))
  }

  /// The current look as a profile: the loaded one's grain data with the screen's settings.
  var profileToSave: GrainProfile {
    var saved = profile ?? GrainProfile(name: "Profile")
    saved.settings = GrainProfile.Settings(options)
    saved.settings.seed = nil
    if saved.created == nil { saved.created = GrainProfile.day(Date()) }
    return saved
  }

  /// Adds the current look to the library as `name`, the name asked for in Add to Library,
  /// replacing the library's profile of that name, and makes it the loaded profile.
  @discardableResult
  func addProfileToLibrary(named name: String) throws -> GrainProfile {
    var added = profileToSave
    added.name = name
    try profiles.save(added)
    profile = added
    return added
  }

  /// Renames the loaded profile, the library's (`profileIsInLibrary`), in the library and on the
  /// screen. The look on screen is left as it is.
  func renameProfile(to newName: String) throws {
    guard let profile, profileIsInLibrary else { return }
    self.profile = try profiles.rename(profile.name, to: newName)
  }

  /// Moves the loaded profile's library file to the Trash. The look and its grain data stay on
  /// the screen, as a profile no longer in the library (Add to Library… puts it back).
  func deleteProfileFromLibrary() throws {
    guard let profile, profileIsInLibrary, let listed = profiles.profile(named: profile.name) else { return }
    try profiles.delete(listed)
  }

  /// Whether the loaded profile is the library's of that name, unchanged.
  var profileIsInLibrary: Bool {
    guard let profile else { return false }
    return profiles.profile(named: profile.name) == profile
  }

  /// Sets the reference the matches move toward (`Match.Target.reference`), measured off the
  /// main actor. `tensorId` names it when it's a step of the source's project.
  func setReference(image: CGImage, name: String, tensorId: Int64? = nil) async {
    isMeasuring = true
    defer { isMeasuring = false }
    guard let measured = try? await EditPipeline.measureReference(image, name: name, profile: false) else {
      note = "The reference couldn't be read."
      return
    }
    reference = Reference(name: name, tensorId: tensorId, lab: measured.lab, histogram: measured.histogram, image: image)
    matchReport = nil
    options.match.target = .reference
    rebuildContext()
  }

  /// Clears the reference.
  func clearReference() {
    reference = nil
    matchReport = nil
    rebuildContext()
  }

  /// Whether Match Reference can measure: a reference image at hand.
  var canMatchReference: Bool { reference?.image != nil && !isMeasuring }

  /// Match Reference (grain.py `--match`): measures the reference's grain and makes a profile of
  /// it, whose settings (size, colour size, strength, colour noise, colour 0.6) go on the screen,
  /// with its curve, RGB statistics and real noise in the context. Says how close the grain came.
  func matchReference() async {
    guard let reference, let picture = reference.image else { return }
    isMeasuring = true
    defer { isMeasuring = false }
    let name = reference.name
    guard let measured = try? await EditPipeline.measureReference(picture, name: name, source: name), let made = measured.profile else {
      note = "The reference has no flat, mid-bright area to measure its grain on."
      return
    }
    applyProfile(made)
    matchReport = measured.match.map(Self.matchReport)
  }

  /// grain.py's printed comparison: the reference's grain shape and colour blotches against the
  /// matched synthetic grain's.
  private nonisolated static func matchReport(_ match: Grain.Match) -> String {
    func list(_ values: [Double]) -> String { values.map { String(format: "%.2f", $0) }.joined(separator: " ") }
    return """
    Grain shape: ref \(list(match.reference.yAC)) vs ours \(list(match.ours.luma.yAC))
    Colour blotches: ref \(list(match.reference.cAC)) vs ours \(list(match.ours.colour.cAC))
    """
  }

  /// Loads a `.cube` LUT and turns it on at full strength.
  func loadLUT(from url: URL) throws {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let table = try CubeLUT.read(contentsOf: url)
    lut = table
    fileLUT = table
    options.lut = EditOptions.LUTRef(name: table.name, digest: table.digest, strength: 1)
    missingDataNote = nil
    rebuildContext()
  }

  /// The LUT menu's choice: a built-in by name, the file LUT, or none (nil), taken the way
  /// loading a file is but keeping the strength. Unlike Remove, None keeps the file LUT in the
  /// menu.
  func chooseLUT(_ table: Edit.LUTTable?) {
    lut = table
    options.lut = EditOptions.LUTRef(name: table?.name, digest: table?.digest, strength: options.lut.strength)
    missingDataNote = nil
    rebuildContext()
  }

  /// Chooses the built-in LUT `name`; false for a name that isn't one.
  @discardableResult func chooseBuiltInLUT(_ name: String) -> Bool {
    guard let table = BuiltInLUTs.table(name) else { return false }
    chooseLUT(table)
    return true
  }

  /// Takes the LUT off.
  func removeLUT() {
    lut = nil
    fileLUT = nil
    options.lut = EditOptions.LUTRef()
    rebuildContext()
  }

  /// Reset: grain.py's default look, with no profile, reference or LUT, and the look and every
  /// stage on (`grainDefaults` has none off). The seed is kept.
  func reset() {
    var look = EditOptions.grainDefaults
    look.grain.seed = options.grain.seed
    options = look
    profile = nil
    reference = nil
    lut = nil
    fileLUT = nil
    matchReport = nil
    missingDataNote = nil
    rebuildContext()
  }

  /// A new grain seed (New Grain).
  func newGrain() {
    options.grain.seed = Int.random(in: 1...999_999)
  }

  /// The match target picked (Reference or Original).
  func setMatchTarget(_ target: EditOptions.Match.Target) {
    options.match.target = target
    rebuildContext()
  }

  /// The measurements the match target has, if any.
  var matchTarget: Reference? { options.match.target == .reference ? reference : original }

  private func rebuildContext() {
    var context = EditPipeline.Context.empty
    if let profile { context = context.using(profile) }
    if let target = matchTarget {
      context.referenceLab = target.lab
      context.referenceHistogram = target.histogram
    }
    context.lut = lut
    if context != self.context {
      self.context = context
      contextVersion += 1
      lastChangeIsFinal = true
    }
  }

  // MARK: - Saving and export

  /// Why Save to History can't be pressed, if it can't.
  var saveProblem: String? {
    guard let create, let source else { return "Open an image to edit." }
    guard case .step(let project, _) = source else { return "Add the image to History first." }
    if create.history.project.name != project { return "The image's project “\(project)” isn't open." }
    if let job = pendingJob, create.queue.pendingEdit(job) != nil { return "This edit is already waiting or running." }
    return nil
  }

  /// The job Save to History would queue now.
  var pendingJob: Edit.Job? {
    guard case .step(let project, let tensorId) = source else { return nil }
    let target = matchTarget
    return Edit.Job(
      project: project, sourceTensorId: tensorId, options: options, profileName: profile?.name,
      referenceTensorId: options.match.target == .reference ? target?.tensorId : nil,
      referenceName: options.match.target == .reference ? target?.name : nil, context: context,
      retouch: Edit.Retouch(crop: effectiveCrop, heal: retouch.heal))
  }

  /// Save to History: queues the edit to render at full size and save as a new step after the
  /// source. Returns the job's id (the one already queued when it's the same edit).
  @discardableResult
  func save() throws -> UUID {
    guard let create, let job = pendingJob, let item else { throw EditError.noStep }
    return try create.queueEdit(job, item: item)
  }

  /// Add to History: the opened file goes into the current project as an Imported entry (as an
  /// image opened on the canvas does), becomes the source, and the edit is queued after it.
  ///
  /// Once at a time (`isAdding`: the button is off meanwhile, and a second call throws `busy`).
  /// The project and image are the ones at the start: if another image opens while the entry is
  /// saved, the entry stays in History but isn't adopted and nothing is queued (it throws
  /// `CancellationError`); if the project changes, the entry keeps its own project's name and
  /// the edit isn't queued into the new one.
  @discardableResult
  func addToHistory() async throws -> UUID {
    guard !isAdding else { throw EditError.busy }
    guard let create, case .file = source, let image else { throw EditError.noStep }
    guard var input = create.entryInput(.imported) else { throw EditError.notLoaded }
    isAdding = true
    defer { isAdding = false }
    let history = create.history
    let project = history.project
    input.canvas = .image(image)
    input.canvasImage = image
    input.mask = nil
    input.moodboard = []
    guard let entry = try await history.saveEntry(input, after: history.currentTensorId, makeCurrent: false) else {
      throw EditError.notLoaded
    }
    // Something else opened meanwhile: the entry is the old image's, not the screen's now.
    guard self.image === image, isFromFile else { throw CancellationError() }
    source = .step(project: project.name, tensorId: entry.tensorId)
    item = entry
    EditSession(project: project.name, tensorId: entry.tensorId).save()
    saveRetouchSession()
    guard history.project === project else { throw EditError.projectChanged(project.name) }
    return try save()
  }

  /// The source rendered at full size with the look, as a PNG: with the step's settings and the
  /// edit's record when it's a step (as History's exports carry them, unless Settings turns that
  /// off), plain for a file. The look, its data and the record are all taken at the start, so a
  /// change made while it renders goes in neither the pixels nor the metadata.
  func exportPNG() async throws -> Data {
    guard let image else { throw EditError.noImage }
    isExporting = true
    defer { isExporting = false }
    let options = options, context = context, item = item
    let job = AppSettings.embedsSettings ? pendingJob : nil
    // The crop applied even while Crop is the tool: what Save to History would save.
    let rendered = try await renderer.full(source: try await retouched(image), options: options, context: context)
    var sidecar: HistoryStore.Sidecar?
    if let item, let job {
      sidecar = item.sidecar
      sidecar?.edit = job.record
      sidecar?.width = rendered.width
      sidecar?.height = rendered.height
    }
    guard let sidecar else { return try await Self.png(rendered, properties: nil, json: nil) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    // Made here: Draw Things' metadata reads the settings registry on the main actor.
    let properties = PNGProperties(value: ImageMetadata.properties(for: sidecar))
    return try await Self.png(rendered, properties: properties, json: try encoder.encode(sidecar))
  }

  /// Image properties handed to the encoder; made once and only read after.
  private nonisolated struct PNGProperties: @unchecked Sendable {
    let value: [CFString: Any]
  }

  /// `HistoryStore.pngData`'s PNG, encoded off the main actor: a 16 MP PNG takes a second.
  @concurrent private nonisolated static func png(
    _ image: CGImage, properties: PNGProperties?, json: Data?
  ) async throws -> Data {
    guard let properties, let json else {
      guard let data = ImageTensor.png(image) else { throw ProjectError.badImage }
      return data
    }
    guard let png = ImageTensor.png(image, properties: properties.value) else { throw ProjectError.badImage }
    return PNGText.inserting(keyword: "Atelier", text: String(decoding: json, as: UTF8.self), into: png) ?? png
  }

  /// Export LUT…: steps 3–7 of the look for this image as a 33³ `.cube` file's text.
  func exportLUT(name: String) async throws -> Data {
    guard let image else { throw EditError.noImage }
    isExporting = true
    defer { isExporting = false }
    let table = try await renderer.bakeLUT(source: try await retouched(image), options: options, context: context, name: name)
    return Data(CubeLUT.text(of: table).utf8)
  }

  /// The source with the whole retouch, whatever the tool: the screen's healed picture when it
  /// has every stroke, else healed again from the source.
  private func retouched(_ image: CGImage) async throws -> CGImage {
    let retouch = retouch
    if healCanvas.applied == retouch.heal { return EditRetouch.cropped(retouch.crop, healCanvas.image ?? image) }
    return try await EditRetouch.applied(retouch, to: image)
  }

  /// The file name exports start from.
  var exportName: String {
    switch source {
    case .step(let project, _): "\(project) \(item?.id.logicalTime ?? 0) edit"
    case .file(let name): "\(name) edit"
    case nil: "Edit"
    }
  }

  enum EditError: LocalizedError {
    case noStep, noImage, notLoaded, busy, projectChanged(String)

    var errorDescription: String? {
      switch self {
      case .noStep: "The image isn't a step in History."
      case .noImage: "There's no image open."
      case .notLoaded: "The project hasn't finished loading."
      case .busy: "The image is already being added to History."
      case .projectChanged(let name): "The image was added to “\(name)”, which is no longer open, so the edit wasn't saved after it."
      }
    }
  }

  // MARK: - Remembered

  private nonisolated static let optionsKey = "editOptions"
  private static let compareModeKey = "editCompareMode"
  static let healBrushSizeKey = "editHealBrushSize"

  /// The look last used; grain.py's default look the first time, and in scripted runs.
  nonisolated static func rememberedOptions(_ defaults: UserDefaults = .standard) -> EditOptions {
    guard SessionState.isEnabled, let data = defaults.data(forKey: optionsKey) else { return .grainDefaults }
    return decodeRemembered(data)
  }

  /// Remembered options read back over grain.py's default look, so a setting added since (or
  /// one that doesn't read) starts as the default look has it; snapped as the screen keeps them.
  nonisolated static func decodeRemembered(_ data: Data) -> EditOptions {
    ((try? EditOptions.decoded(from: data, over: .grainDefaults)) ?? .grainDefaults).snapped
  }

  nonisolated static func encodeRemembered(_ options: EditOptions) -> Data? {
    try? JSONEncoder().encode(options)
  }

  private static func remember(_ options: EditOptions) {
    guard SessionState.isEnabled, let data = encodeRemembered(options) else { return }
    UserDefaults.standard.set(data, forKey: optionsKey)
  }
}

/// A save made a while after the last change rather than on every one: `schedule` notes the
/// newest value and (re)starts the wait, `flush` saves a waiting value now. One task waits at a
/// time, going back to sleep while changes keep coming, so a change costs no more than noting it.
final class DebouncedSave<Value> {
  let delay: Duration
  private let save: (Value) -> Void
  private var pending: Value?
  private var deadline: ContinuousClock.Instant?
  private var waiting: Task<Void, Never>?

  init(delay: Duration, save: @escaping (Value) -> Void) {
    self.delay = delay
    self.save = save
  }

  /// Whether a value is waiting to be saved.
  var hasPending: Bool { pending != nil }

  /// `value` to be saved once `delay` has passed with no newer one.
  func schedule(_ value: Value) {
    pending = value
    deadline = .now + delay
    guard waiting == nil else { return }
    waiting = Task { [weak self] in
      while let deadline = self?.deadline, deadline > .now {
        try? await Task.sleep(until: deadline, clock: .continuous)
        if Task.isCancelled { return }
      }
      // Flushed meanwhile (and perhaps a newer wait begun): that one's in charge now.
      guard !Task.isCancelled else { return }
      self?.waiting = nil
      self?.flush()
    }
  }

  /// Saves the waiting value now, if there is one; nothing more is saved until the next change.
  func flush() {
    waiting?.cancel()
    waiting = nil
    deadline = nil
    guard let value = pending else { return }
    pending = nil
    save(value)
  }
}

/// Counts the Edit screen's opens (`EditModel.open`), each numbered as it starts, so only the
/// latest one's result goes up: an older one finishing later is stale.
nonisolated struct OpenGenerations: Equatable, Sendable {
  private(set) var latest = 0

  /// A new open's number; every earlier one is stale from now on.
  mutating func begin() -> Int {
    latest += 1
    return latest
  }

  func isCurrent(_ generation: Int) -> Bool { generation == latest }

  /// Whether anything has been asked to open yet.
  var anyRequested: Bool { latest > 0 }
}
