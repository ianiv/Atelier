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
/// `matchReference()`, `loadLUT(from:)`, `save()`, `addToHistory()`, `exportPNG()`, `exportLUT(name:)`.
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
  /// A fitted copy of the source for the original's side of a comparison, made once per source.
  private(set) var originalPreview: CGImage?
  /// Reading a step or file.
  private(set) var isLoading = false

  // MARK: Look

  /// The look, always snapped (`EditOptions.snapped`), so the same settings make the same job
  /// and the same cache keys. Remembered for the next launch.
  var options: EditOptions {
    get { storedOptions }
    set {
      let snapped = newValue.snapped
      guard snapped != storedOptions else { return }
      storedOptions = snapped
      Self.remember(snapped)
    }
  }

  private var storedOptions: EditOptions

  /// How the original is compared with the edit. Remembered.
  var compareMode: Compare.Mode {
    didSet { if SessionState.isEnabled { UserDefaults.standard.set(compareMode.rawValue, forKey: Self.compareModeKey) } }
  }

  /// The loaded grain profile: from the library, a file, Match Reference, or a saved step's
  /// record. Its grain data goes into `context`.
  private(set) var profile: GrainProfile?
  /// The reference the user chose (`Match.Target.reference`).
  private(set) var reference: Reference?
  /// The source step's original (`Match.Target.original`), measured when the step is opened.
  private(set) var original: Reference?
  /// The loaded LUT.
  private(set) var lut: Edit.LUTTable?

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

  // MARK: Rendering

  /// The preview's zoom: `scale` is screen pixels per image pixel (1 is 100%), `offset` view points.
  let canvas = CanvasState()
  let renderer = EditRenderer()
  let profiles: GrainProfileStore

  init() {
    storedOptions = Self.rememberedOptions()
    compareMode = SessionState.isEnabled
      ? UserDefaults.standard.string(forKey: Self.compareModeKey).flatMap(Compare.Mode.init) ?? .hold : .hold
    // A scripted run keeps its profiles out of the user's library.
    profiles = SessionState.isEnabled
      ? GrainProfileStore()
      : GrainProfileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Atelier Grain Profiles (scripted)"))
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
  /// added twice (`reopening(_:in:)`); its data gone from the project (`missingEditData`), the
  /// look comes back with Real Noise and the LUT off.
  func open(_ item: HistoryItem) async {
    guard let create, !item.isVideo, item.hasImage else { return }
    let project = create.history.project
    isLoading = true
    defer { isLoading = false }
    note = nil
    missingDataNote = nil
    var sourceItem = item
    var restored: (record: Edit.Record, context: EditPipeline.Context?)?
    if let record = item.sidecar.edit {
      if let found = Self.reopening(record, in: create.history.tree) {
        sourceItem = found
        let context = await project.read { try? $0.editContext(for: record) }
        restored = (record, context)
      } else {
        note = "The image this edit was made from is no longer in the project, so the edit itself opens."
      }
    }
    guard let tensorId = sourceItem.imageTensorId,
          let picture = await project.read({ $0.image(tensorId: tensorId) })
    else {
      note = "The image couldn't be read."
      return
    }
    setSource(.step(project: project.name, tensorId: sourceItem.tensorId), item: sourceItem, image: picture)
    reference = nil
    matchReport = nil
    if let restored { restore(restored.record, context: restored.context) }
    rebuildContext()
    EditSession(project: project.name, tensorId: sourceItem.tensorId).save()
    await measureOriginal(of: sourceItem, in: project)
  }

  /// The step an edited step's record says it came from, which Edit opens in its place; nil
  /// when it's gone (or isn't an image any more).
  nonisolated static func reopening(_ record: Edit.Record, in tree: ProjectTree) -> HistoryItem? {
    tree.step(tensorId: record.sourceTensorId).flatMap { tree.items[$0] }.flatMap { $0.isVideo || !$0.hasImage ? nil : $0 }
  }

  /// Opens an image that isn't a step (a file, a photo, a canvas image from outside the
  /// project): it can be exported, or added to History to save edits after it.
  func open(image: CGImage, name: String) {
    note = nil
    missingDataNote = nil
    setSource(.file(name: name), item: nil, image: image)
    original = nil
    reference = reference.map { var kept = $0; kept.tensorId = nil; return kept }
    rebuildContext()
    EditSession.clear()
  }

  /// Opens an image file (Open Image…, a drop), reading it with security-scoped access.
  func open(url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    guard let image = ImageLoader.image(at: url) else {
      note = "“\(url.lastPathComponent)” couldn't be read as an image."
      return
    }
    open(image: image, name: url.deletingPathExtension().lastPathComponent)
  }

  /// Opens a photo from the library (Open from Photos…).
  func open(photo data: Data) {
    guard let image = ImageLoader.image(from: data) else {
      note = "The photo couldn't be read."
      return
    }
    open(image: image, name: "Photo")
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

  /// Brings back the step open at the last quit, once its project is the current one.
  func restoreSession() async {
    guard source == nil, let saved = EditSession.load(), let create, create.history.project.name == saved.project,
          let item = create.history.item(tensorId: saved.tensorId)
    else { return }
    await open(item)
  }

  /// Puts `image` up as the source, dropping what the renderer kept for the last one.
  private func setSource(_ source: Source, item: HistoryItem?, image: CGImage) {
    if let old = self.image, old !== image {
      let renderer = renderer
      Task { await renderer.forget(old) }
    }
    self.source = source
    self.item = item
    self.image = image
    originalPreview = ImageLoader.fitted(image, maxSide: 2048)
    canvas.zoomToFit()
  }

  /// A saved step's look and data back on the screen. Without its data (`context` nil) the
  /// settings that need it are turned off.
  private func restore(_ record: Edit.Record, context saved: EditPipeline.Context?) {
    var look = record.options
    let context = saved ?? record.context(with: Edit.Blobs())
    if saved == nil {
      missingDataNote = "This edit's real noise or LUT data is missing from the project, so Real Noise and the LUT are off."
      look.grain.real = 0
      look.lut = EditOptions.LUTRef()
    }
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
  }

  /// Measures the step's original (the image it was made from, else its parent's) for
  /// `Match.Target.original`.
  private func measureOriginal(of item: HistoryItem, in project: Project) async {
    original = nil
    rebuildContext()
    guard let create else { return }
    var found: (image: CGImage, tensorId: Int64?)?
    if let original = await create.originalImage(for: item, in: project) {
      found = (original.image, original.tensorId)
    } else if let parent = create.history.parent(of: item), let tensorId = parent.imageTensorId,
              let image = await project.read({ $0.image(tensorId: tensorId) })
    {
      found = (image, tensorId)
    }
    guard let found,
          let measured = try? await EditPipeline.measureReference(found.image, name: "Original", profile: false),
          self.item?.tensorId == item.tensorId
    else { return }
    original = Reference(name: "Original", tensorId: found.tensorId, lab: measured.lab, histogram: measured.histogram, image: found.image)
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

  /// Adds the current look to the library (numbered when the name's taken) and makes it the
  /// loaded profile.
  @discardableResult
  func addProfileToLibrary() throws -> GrainProfile {
    let added = try profiles.add(profileToSave)
    profile = added
    return added
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
    options.lut = EditOptions.LUTRef(name: table.name, digest: table.digest, strength: 1)
    missingDataNote = nil
    rebuildContext()
  }

  /// Takes the LUT off.
  func removeLUT() {
    lut = nil
    options.lut = EditOptions.LUTRef()
    rebuildContext()
  }

  /// Reset: grain.py's default look, with no profile, reference or LUT. The seed is kept.
  func reset() {
    var look = EditOptions.grainDefaults
    look.grain.seed = options.grain.seed
    options = look
    profile = nil
    reference = nil
    lut = nil
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
      referenceName: options.match.target == .reference ? target?.name : nil, context: context)
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
  @discardableResult
  func addToHistory() async throws -> UUID {
    guard let create, case .file = source, let image else { throw EditError.noStep }
    guard var input = create.entryInput(.imported) else { throw EditError.notLoaded }
    input.canvas = .image(image)
    input.canvasImage = image
    input.mask = nil
    input.moodboard = []
    guard let entry = try await create.history.saveEntry(input, after: create.history.currentTensorId, makeCurrent: false) else {
      throw EditError.notLoaded
    }
    source = .step(project: create.history.project.name, tensorId: entry.tensorId)
    item = entry
    EditSession(project: create.history.project.name, tensorId: entry.tensorId).save()
    return try save()
  }

  /// The source rendered at full size with the look, as a PNG: with the step's settings and the
  /// edit's record when it's a step (as History's exports carry them, unless Settings turns that
  /// off), plain for a file.
  func exportPNG() async throws -> Data {
    guard let image else { throw EditError.noImage }
    isExporting = true
    defer { isExporting = false }
    let rendered = try await renderer.full(source: image, options: options, context: context)
    var sidecar: HistoryStore.Sidecar?
    if AppSettings.embedsSettings, let item, let job = pendingJob {
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
    let table = try await renderer.bakeLUT(source: image, options: options, context: context, name: name)
    return Data(CubeLUT.text(of: table).utf8)
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
    case noStep, noImage, notLoaded

    var errorDescription: String? {
      switch self {
      case .noStep: "The image isn't a step in History."
      case .noImage: "There's no image open."
      case .notLoaded: "The project hasn't finished loading."
      }
    }
  }

  // MARK: - Remembered

  private nonisolated static let optionsKey = "editOptions"
  private static let compareModeKey = "editCompareMode"

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
