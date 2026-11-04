import CoreGraphics
import Foundation
import Observation

/// A knob's state on a character. A non-empty `custom` replaces the knob's phrase, and the slider
/// or picker stays in place, disabled.
struct KnobSetting: Codable, Hashable {
  /// The option's label, or a text knob's text; nil is unset and writes nothing.
  var value: String?
  var custom = ""
  var locked = false
}

/// A saved, named character (docs/characters.md). Its name is never sent to the model: models tend
/// to draw names as text.
struct SavedCharacter: Codable, Identifiable, Hashable {
  var id = UUID()
  var name: String
  var notes = ""
  /// By knob id; a knob with no entry is unset.
  var knobs: [String: KnobSetting] = [:]
  /// Each section's free text, by section id.
  var texts: [String: String] = [:]
  /// Each noun switch's choice, by section id.
  var nouns: [String: String] = [:]
  /// Edit as Text: the description as typed, which no longer follows the knobs. Undo brings them back.
  var editedDescription: String?
  /// The style picked to render in; nil is No Style.
  var styleID: UUID?
  /// What a style's tags other than `SUBJECT` take, by tag.
  var tagValues: [String: String] = [:]
  /// Saved images, in the order saved, by the name of their files (`CharacterStore`).
  var images: [UUID] = []
  /// The saved image that stands for the character; the first when nil.
  var mainImage: UUID?
  /// The sheet picked for Render Sheet (`CharacterKnobSet.Sheet.id`), its size in megapixels and
  /// the Custom sheet's text.
  var sheet: String?
  var sheetMegapixels = 1
  var customSheet = ""

  init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, notes, knobs, texts, nouns, editedDescription, styleID, tagValues
    case images, mainImage, sheet, sheetMegapixels, customSheet
  }

  /// Everything but the name is optional, so files stay readable as characters grow.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decode(String.self, forKey: .name)
    notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    knobs = try container.decodeIfPresent([String: KnobSetting].self, forKey: .knobs) ?? [:]
    texts = try container.decodeIfPresent([String: String].self, forKey: .texts) ?? [:]
    nouns = try container.decodeIfPresent([String: String].self, forKey: .nouns) ?? [:]
    editedDescription = try container.decodeIfPresent(String.self, forKey: .editedDescription)
    styleID = try container.decodeIfPresent(UUID.self, forKey: .styleID)
    tagValues = try container.decodeIfPresent([String: String].self, forKey: .tagValues) ?? [:]
    images = try container.decodeIfPresent([UUID].self, forKey: .images) ?? []
    mainImage = try container.decodeIfPresent(UUID.self, forKey: .mainImage)
    sheet = try container.decodeIfPresent(String.self, forKey: .sheet)
    sheetMegapixels = try container.decodeIfPresent(Int.self, forKey: .sheetMegapixels) ?? 1
    customSheet = try container.decodeIfPresent(String.self, forKey: .customSheet) ?? ""
  }

  /// The saved image that stands for the character.
  var mainImageID: UUID? {
    mainImage.flatMap { images.contains($0) ? $0 : nil } ?? images.first
  }

  func setting(_ knob: String) -> KnobSetting { knobs[knob] ?? KnobSetting() }

  /// A text knob's text.
  func written(_ knob: CharacterKnobSet.Knob) -> String {
    setting(knob.id).value?.trimmed ?? ""
  }

  /// The kind's word, for a caption: nil with no text-role kind knob or nothing typed.
  func kind(in knobs: CharacterKnobSet) -> String {
    knobs.sections.flatMap(\.knobs).first { $0.role == .kind }.map(written) ?? ""
  }
}

/// How a saved image or a preview was made: enough to save it to a project and load it on Create.
struct CharacterImageInfo: Codable {
  /// The prompts sent, the model, seed and every setting.
  var source: ThumbnailSource
  /// The style it was rendered in; nil for No Style.
  var styleID: UUID?
  var styleName: String
  var tagValues: [String: String]
  /// The description that filled `{{SUBJECT}}`.
  var subject: String
}

/// A render of a character, not saved anywhere lasting: its full image is a file in `PreviewFiles`'
/// folder, with only a small thumbnail in memory, so a long session can't fill memory.
struct CharacterPreview: Identifiable {
  let id: UUID
  let thumbnail: CGImage
  let info: CharacterImageInfo
  let file: URL
}

/// Where previews' full images live: `<temp>/Atelier/CharacterPreviews/<launch id>/`. Normal quits
/// delete this launch's folder, and each launch deletes what a crash left behind. It touches
/// nothing outside `CharacterPreviews`: other files live loose in `<temp>/Atelier`.
enum PreviewFiles {
  private static let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("Atelier/CharacterPreviews", isDirectory: true)
  private static let launchID = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
  static let folder = root.appendingPathComponent(launchID, isDirectory: true)

  /// Runs once, whichever store comes first.
  static let sweptAtLaunch: Void = sweepLeftovers()

  static func removeThisLaunch() {
    try? FileManager.default.removeItem(at: folder)
  }

  /// Deletes other launches' folders, unless that app is still running: a development build and
  /// the installed app can run side by side.
  static func sweepLeftovers() {
    let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    for leftover in folders where leftover.lastPathComponent != launchID && !isRunning(leftover.lastPathComponent) {
      try? FileManager.default.removeItem(at: leftover)
    }
  }

  private static func isRunning(_ folderName: String) -> Bool {
    #if os(macOS)
      guard let pid = folderName.split(separator: "-").first.flatMap({ Int32($0) }) else { return false }
      return kill(pid, 0) == 0 || errno == EPERM
    #else
      // One copy at a time on iPad, in a temp folder of its own.
      return false
    #endif
  }
}

/// The characters, in `Characters.json` in Application Support, each with its saved images in
/// `CharacterImages`: like a style's thumbnail, a square JPEG for the library with the full image
/// and how it was made beside it, named by the image's id. A character from when there was only
/// one saved image has it under the character's id, which simply becomes that image's id.
@MainActor
@Observable
final class CharacterStore {
  private(set) var characters: [SavedCharacter] = []
  let knobs: CharacterKnobSet

  // The screen, as you left it.
  var screenSearch = ""
  var screenGrid = UserDefaults.standard.bool(forKey: "charactersGrid") {
    didSet { remember(screenGrid, "charactersGrid") }
  }
  var selection = UserDefaults.standard.string(forKey: "charactersSelection").flatMap(UUID.init(uuidString:)) {
    didSet { remember(selection?.uuidString, "charactersSelection") }
  }

  /// Each character's previews this session, newest first.
  private(set) var previews: [UUID: [CharacterPreview]] = [:]
  /// The preview or saved image shown large, by character; none shows the main image.
  var shownImage: [UUID: UUID] = [:]
  /// Previews already saved to their character, so one isn't saved twice.
  private(set) var savedPreviews: Set<UUID> = []
  /// Saved images read so far, by image id (`.some(nil)` is one with no file).
  private(set) var thumbnails: [UUID: CGImage?] = [:]
  /// A few saved images full size, the most recently shown last in `savedImageOrder`.
  private(set) var savedImages: [UUID: CGImage] = [:]
  @ObservationIgnored private var savedImageOrder: [UUID] = []
  /// The preview shown large, read back from its file.
  private(set) var shownPreviewImage: (preview: UUID, image: CGImage)?
  private(set) var savedInfo: [UUID: CharacterImageInfo] = [:]

  /// The renders running: how many are done (and failed) of how many, and the style running.
  private(set) var renderRun: (character: UUID, done: Int, total: Int, failed: Int, current: String)?
  @ObservationIgnored private var renderTask: Task<Void, Never>?
  /// Why the last render or Send to Create failed.
  var renderError: String?

  /// Off for scripted runs: they use a scratch folder and leave UserDefaults alone.
  @ObservationIgnored let persists: Bool
  @ObservationIgnored private let directory: URL
  @ObservationIgnored private var pendingWrite: Task<Void, Never>?

  private var file: URL { directory.appendingPathComponent("Characters.json") }
  private var imagesDirectory: URL { directory.appendingPathComponent("CharacterImages", isDirectory: true) }

  /// With `directory`, reads and writes there rather than Application Support.
  init(persists: Bool = true, directory: URL? = nil) {
    self.persists = persists
    knobs = CharacterKnobSet.load()
    self.directory = directory ?? (
      persists
        ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Atelier", isDirectory: true)
        : FileManager.default.temporaryDirectory.appendingPathComponent("AtelierCharacters-\(UUID().uuidString)", isDirectory: true))
    _ = PreviewFiles.sweptAtLaunch
    var listRead = false
    if let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode([SavedCharacter].self, from: data) {
      characters = read
      listRead = true
    }
    // The single saved image of an earlier version goes on the list, its files staying put.
    var migrated = false
    for index in characters.indices where characters[index].images.isEmpty {
      let id = characters[index].id
      if FileManager.default.fileExists(atPath: imageFiles(id)[0].path) {
        characters[index].images = [id]
        characters[index].mainImage = id
        migrated = true
      }
    }
    if migrated { scheduleWrite() }
    // Only with a list to compare against: an unreadable file mustn't cost anyone their images.
    if listRead { sweepOrphanedImages() }
    AppLifecycle.onWillTerminate { [weak self] in
      self?.flush()
      PreviewFiles.removeThisLaunch()
    }
    // iPad may end the app in the background without saying so. Previews stay for when you come
    // back; the system or the next launch clears them.
    AppLifecycle.onResignActive { [weak self] in self?.flush() }
    if !persists { selection = nil }
  }

  private func remember(_ value: Any?, _ key: String) {
    if persists { UserDefaults.standard.set(value, forKey: key) }
  }

  func character(id: UUID?) -> SavedCharacter? {
    id.flatMap { id in characters.first { $0.id == id } }
  }

  // MARK: - Editing

  @discardableResult
  func newCharacter() -> SavedCharacter {
    let taken = Set(characters.map(\.name))
    var name = "New Character"
    var number = 2
    while taken.contains(name) {
      name = "New Character \(number)"
      number += 1
    }
    let character = SavedCharacter(name: name)
    characters.append(character)
    selection = character.id
    scheduleWrite()
    return character
  }

  /// Changes a character; saved a moment later, so a slider's drag writes the file once.
  func edit(_ id: UUID, _ change: (inout SavedCharacter) -> Void) {
    guard let index = characters.firstIndex(where: { $0.id == id }) else { return }
    change(&characters[index])
    scheduleWrite()
  }

  func replace(_ character: SavedCharacter) {
    edit(character.id) { $0 = character }
  }

  /// The copy keeps the saved images, as files of its own.
  func duplicate(_ id: UUID) {
    guard let original = character(id: id) else { return }
    var copy = original
    copy.id = UUID()
    copy.name += " copy"
    var copied: [UUID: UUID] = [:]
    for image in original.images { copied[image] = UUID() }
    copy.images = original.images.compactMap { copied[$0] }
    copy.mainImage = original.mainImage.flatMap { copied[$0] }
    characters.insert(copy, at: (characters.firstIndex { $0.id == id } ?? characters.count - 1) + 1)
    try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    for (image, new) in copied {
      for (from, to) in zip(imageFiles(image), imageFiles(new)) {
        try? FileManager.default.copyItem(at: from, to: to)
      }
    }
    selection = copy.id
    writeNow()
  }

  func delete(_ id: UUID) {
    if renderRun?.character == id { stopRendering() }
    let images = character(id: id)?.images ?? []
    clearPreviews(of: id)
    characters.removeAll { $0.id == id }
    shownImage[id] = nil
    if selection == id { selection = nil }
    // The list first: a crash between the two leaves files the next launch sweeps, not a character
    // with missing images.
    writeNow()
    for image in images { forgetImage(image) }
  }

  private func scheduleWrite() {
    pendingWrite?.cancel()
    pendingWrite = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.write()
      self?.pendingWrite = nil
    }
  }

  /// Saves now, for changes that go with files on disk, so the list and the files stay in step.
  private func writeNow() {
    pendingWrite?.cancel()
    pendingWrite = nil
    write()
  }

  /// Writes anything still waiting to be saved.
  func flush() {
    guard pendingWrite != nil else { return }
    pendingWrite?.cancel()
    pendingWrite = nil
    write()
  }

  private func write() {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(characters).write(to: file, options: .atomic)
    } catch {
      print("Couldn't save characters: \(error)")
    }
  }

  /// The description a render sends: the knobs' sentences, or the text from Edit as Text.
  func description(of character: SavedCharacter) -> String {
    character.editedDescription ?? knobs.description(of: character)
  }

  // MARK: - The saved image

  private func imageFiles(_ id: UUID) -> [URL] {
    [".jpg", "-full.png", ".json"].map { imagesDirectory.appendingPathComponent(id.uuidString + $0) }
  }

  /// Deletes files in `CharacterImages` that no character refers to, left by a crash at the wrong
  /// moment. Recent ones stay: another running copy of the app may have just written them.
  private func sweepOrphanedImages() {
    let used = Set(characters.flatMap(\.images))
    let files = (try? FileManager.default.contentsOfDirectory(
      at: imagesDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for file in files {
      guard let id = UUID(uuidString: String(file.lastPathComponent.prefix(36))), !used.contains(id),
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            Date().timeIntervalSince(modified) > 3_600
      else { continue }
      try? FileManager.default.removeItem(at: file)
    }
  }

  /// Removes an image's files and what's been read of it.
  private func forgetImage(_ image: UUID) {
    for file in imageFiles(image) { try? FileManager.default.removeItem(at: file) }
    thumbnails[image] = nil
    savedImages[image] = nil
    savedImageOrder.removeAll { $0 == image }
    savedInfo[image] = nil
  }

  /// Reads a saved image's square the first time it's shown.
  func loadThumbnail(_ image: UUID) async {
    guard thumbnails[image] == nil else { return }
    let url = imageFiles(image)[0]
    let read = await Task.detached { ImageLoader.image(at: url) }.value
    thumbnails[image] = .some(read)
  }

  /// How many saved images stay in memory full size.
  private static let savedImagesKept = 8

  /// Reads a saved image full size and how it was made, to show it large.
  func loadSaved(_ id: UUID) async {
    guard savedImages[id] == nil else {
      savedImageOrder.removeAll { $0 == id }
      savedImageOrder.append(id)
      return
    }
    await loadInfo(id)
    let files = imageFiles(id)
    let image = await Task.detached { ImageLoader.image(at: files[1]) ?? ImageLoader.image(at: files[0]) }.value
    guard let image else { return }
    savedImages[id] = image
    savedImageOrder.removeAll { $0 == id }
    savedImageOrder.append(id)
    while savedImageOrder.count > Self.savedImagesKept {
      savedImages[savedImageOrder.removeFirst()] = nil
    }
  }

  /// Reads how a saved image was made, for its tile's caption, without its pixels.
  func loadInfo(_ id: UUID) async {
    guard savedInfo[id] == nil else { return }
    let file = imageFiles(id)[2]
    let info = await Task.detached {
      (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CharacterImageInfo.self, from: $0) }
    }.value
    if let info { savedInfo[id] = info }
  }

  func thumbnail(_ image: UUID) -> CGImage? { thumbnails[image] ?? nil }

  /// Adds an image to the character's saved images; the first one is its main image. Returns the
  /// new image's id, or nil when it couldn't be written.
  @discardableResult
  func addSavedImage(_ image: CGImage, info: CharacterImageInfo?, to character: UUID) -> UUID? {
    let id = UUID()
    do {
      try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
      let files = imageFiles(id)
      guard let square = StyleStore.square(image, side: StyleStore.thumbnailSize),
            let jpeg = ImageTensor.jpeg(square, quality: 0.85), let png = ImageTensor.png(image)
      else { throw CocoaError(.fileWriteUnknown) }
      try Data(jpeg).write(to: files[0], options: .atomic)
      try png.write(to: files[1], options: .atomic)
      if let info { try JSONEncoder().encode(info).write(to: files[2], options: .atomic) }
      thumbnails[id] = .some(square)
      savedInfo[id] = info
      edit(character) { $0.images.append(id) }
      writeNow()
      return id
    } catch {
      forgetImage(id)
      renderError = "Couldn't save the image: \(error.localizedDescription)"
      return nil
    }
  }

  /// Save to Character: adds the preview to the saved images, once.
  func save(_ preview: CharacterPreview, to character: UUID) async {
    guard savedPreviews.insert(preview.id).inserted else { return }
    guard let image = await fullImage(of: preview), addSavedImage(image, info: preview.info, to: character) != nil else {
      savedPreviews.remove(preview.id)
      return
    }
  }

  // MARK: - Previews

  /// Keeps a render as a preview: its full image in the temp folder, a small thumbnail in memory.
  /// Returns nil, with `renderError` saying why, when the file can't be written.
  @discardableResult
  func keepPreview(_ image: CGImage, info: CharacterImageInfo, of character: UUID) async -> CharacterPreview? {
    let id = UUID()
    let file = PreviewFiles.folder.appendingPathComponent(id.uuidString + ".png")
    let written = await Task.detached { () -> Bool in
      guard let png = ImageTensor.png(image) else { return false }
      do {
        try FileManager.default.createDirectory(at: PreviewFiles.folder, withIntermediateDirectories: true)
        try png.write(to: file, options: .atomic)
        return true
      } catch {
        return false
      }
    }.value
    guard written, let thumbnail = StyleStore.square(image, side: Self.previewThumbnailSide) else {
      renderError = "Couldn't keep the preview: is the disk full?"
      return nil
    }
    let preview = CharacterPreview(id: id, thumbnail: thumbnail, info: info, file: file)
    previews[character, default: []].insert(preview, at: 0)
    shownPreviewImage = (id, image)
    shownImage[character] = id
    return preview
  }

  /// Sharp in the strip at 2x.
  private static let previewThumbnailSide = 192

  /// A preview's full image, from memory when it's the one shown.
  func fullImage(of preview: CharacterPreview) async -> CGImage? {
    if let shown = shownPreviewImage, shown.preview == preview.id { return shown.image }
    let file = preview.file
    return await Task.detached { ImageLoader.image(at: file) }.value
  }

  /// Reads the preview about to be shown large; only that one stays in memory.
  func showFull(_ preview: CharacterPreview) async {
    guard let image = await fullImage(of: preview), !Task.isCancelled else { return }
    shownPreviewImage = (preview.id, image)
  }

  func removePreview(_ preview: UUID, of character: UUID) {
    guard let found = previews[character]?.first(where: { $0.id == preview }) else { return }
    previews[character]?.removeAll { $0.id == preview }
    forgetPreview(found)
    if shownImage[character] == preview { shownImage[character] = nil }
  }

  func clearPreviews(of character: UUID) {
    for preview in previews[character] ?? [] {
      forgetPreview(preview)
      if shownImage[character] == preview.id { shownImage[character] = nil }
    }
    previews[character] = nil
  }

  private func forgetPreview(_ preview: CharacterPreview) {
    try? FileManager.default.removeItem(at: preview.file)
    savedPreviews.remove(preview.id)
    if shownPreviewImage?.preview == preview.id { shownPreviewImage = nil }
  }

  func makeMain(_ image: UUID, of character: UUID) {
    edit(character) { $0.mainImage = image }
  }

  /// Removes a saved image. If it was the main image, the first one left takes over.
  func removeSavedImage(_ image: UUID, from character: UUID) {
    edit(character) {
      $0.images.removeAll { $0 == image }
      if $0.mainImage == image { $0.mainImage = nil }
    }
    if shownImage[character] == image { shownImage[character] = nil }
    // The list first, as in `delete`.
    writeNow()
    forgetImage(image)
  }

  // MARK: - Rendering

  /// Why the character can't be rendered now, or nil when it can.
  func renderBlocker(_ create: CreateModel, for character: SavedCharacter) -> String? {
    if create.selectedModel == nil || create.settings == nil || create.isLoadingModel {
      return "Pick a model on Create first."
    }
    if create.videoModel != nil { return "Pick an image model on Create: renders are images." }
    if description(of: character).trimmed.isEmpty { return "Set a knob first: the description is empty." }
    return nil
  }

  /// Why the character's sheet can't be rendered now, or nil when it can.
  func sheetBlocker(_ create: CreateModel, for character: SavedCharacter) -> String? {
    if let blocker = renderBlocker(create, for: character) { return blocker }
    guard let sheet = knobs.sheet(of: character) else { return "No sheets in the knob file." }
    if sheet.takesText == true, character.customSheet.trimmed.isEmpty { return "Say what the custom sheet shows first." }
    return nil
  }

  /// One render in a run: its style, what fills the style's subject, the look for No Style, what
  /// to call it, and a size in place of Create's.
  private struct RenderItem {
    var style: Style?
    var subject: String
    var reference: Style
    var label: String
    var size: (width: Int, height: Int)?
  }

  /// Renders the character in each style (nil is No Style), one after another in the queue, with
  /// the model, settings and seed on Create: one seed, so the styles compare like for like and
  /// moving one knob shows only that knob's effect. Create's negative prompt, canvas and moodboard
  /// aren't used. The images aren't saved to the project, and become previews.
  func render(_ character: SavedCharacter, in styles: [Style?], create: CreateModel) {
    guard renderBlocker(create, for: character) == nil else { return }
    let subject = description(of: character).trimmed
    let reference = knobs.referenceStyle
    run(
      styles.map { RenderItem(style: $0, subject: subject, reference: reference, label: ($0 ?? reference).name) },
      of: character, create: create)
  }

  /// Render Sheet: one image showing the character several ways, in the style, at the sheet's own
  /// size; everything else comes from Create as for any render. Create's size isn't changed.
  func renderSheet(_ character: SavedCharacter, in style: Style?, create: CreateModel) {
    guard sheetBlocker(create, for: character) == nil, let sheet = knobs.sheet(of: character) else { return }
    let subject = sheet.subject(description: description(of: character).trimmed, custom: character.customSheet)
    let reference = knobs.referenceSheetStyle
    run(
      [RenderItem(
        style: style, subject: subject, reference: reference, label: "\(sheet.title) · \((style ?? reference).name)",
        size: sheet.size(megapixels: character.sheetMegapixels))],
      of: character, create: create)
  }

  private func run(_ items: [RenderItem], of character: SavedCharacter, create: CreateModel) {
    guard renderRun == nil, let first = items.first, let model = create.selectedModel, let settings = create.settings else { return }
    let seed = create.seed
    renderError = nil
    renderRun = (character.id, 0, items.count, 0, first.label)
    renderTask = Task { [weak self] in
      for item in items {
        guard let self, !Task.isCancelled else { break }
        renderRun?.current = item.label
        var configuration = settings
        if let size = item.size {
          configuration.width = size.width
          configuration.height = size.height
        }
        var used = configuration
        used.seed = seed
        var values = character.tagValues
        values[Style.subject] = item.subject
        let prompts = (item.style ?? item.reference).apply(values, negativePrompt: "")
        let request = GenerationEngine.Request(
          model: model, prompt: prompts.prompt, negativePrompt: prompts.negativePrompt, seed: seed,
          configuration: configuration)
        do {
          let image = try await create.generateCharacterPreview(request, label: "\(character.name): \(item.label)")
          let info = CharacterImageInfo(
            source: ThumbnailSource(
              prompt: prompts.prompt, negativePrompt: prompts.negativePrompt, model: model, seed: seed,
              settings: JSONValue.fields(of: used)),
            styleID: item.style?.id, styleName: item.label, tagValues: character.tagValues, subject: item.subject)
          await keepPreview(image, info: info, of: character.id)
        } catch is CancellationError {
          break
        } catch {
          renderError = error.localizedDescription
          renderRun?.failed += 1
        }
        renderRun?.done += 1
      }
      self?.renderRun = nil
      self?.renderTask = nil
    }
  }

  /// Stops rendering; the running one is cancelled, the ones made are kept.
  func stopRendering() {
    renderTask?.cancel()
  }

  /// Adds the image to the current project (so it shows in History) and loads it on Create with
  /// the model, settings, seed, style and tag boxes it was made with.
  func sendToCreate(
    _ image: CGImage, info: CharacterImageInfo, create: CreateModel, navigation: Navigation, undoManager: UndoManager?
  ) async {
    do {
      try await create.openCharacterRender(image, info: info, undoManager: undoManager)
      navigation.section = .create
    } catch {
      renderError = "Couldn't add the image to the project: \(error.localizedDescription)"
    }
  }

  // MARK: - Files

  /// A characters file: a JSON list of characters, each with its saved images and how each was
  /// made. A file from when there was one saved image has `image` and `info` instead of `images`.
  struct FileFormat: Codable {
    struct SavedImage: Codable {
      var image: Data
      var info: CharacterImageInfo?
    }

    struct Entry: Codable {
      var character: SavedCharacter
      var images: [SavedImage]?
      /// Which of `images` is the main image.
      var main: Int?
      var image: Data?
      var info: CharacterImageInfo?
    }

    var format = "atelier-characters"
    var version = 2
    var characters: [Entry]
  }

  /// The characters as a file, with their saved images.
  func exported(_ ids: [UUID]) -> Data {
    let entries = ids.compactMap { id -> FileFormat.Entry? in
      guard var character = character(id: id) else { return nil }
      var images: [FileFormat.SavedImage] = []
      var main: Int?
      for image in character.images {
        let files = imageFiles(image)
        guard let data = (try? Data(contentsOf: files[1])) ?? (try? Data(contentsOf: files[0])) else { continue }
        if image == character.mainImageID { main = images.count }
        let info = (try? Data(contentsOf: files[2])).flatMap { try? JSONDecoder().decode(CharacterImageInfo.self, from: $0) }
        images.append(FileFormat.SavedImage(image: data, info: info))
      }
      character.images = []
      character.mainImage = nil
      return FileFormat.Entry(character: character, images: images, main: main)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(FileFormat(characters: entries))) ?? Data()
  }

  /// Adds the characters in a file. One with the same name as a character here replaces it, saved
  /// images included, keeping its id. Returns how many came in, or nil when it isn't a characters
  /// file.
  func importCharacters(_ data: Data) -> (added: Int, replaced: Int)? {
    guard let file = try? JSONDecoder().decode(FileFormat.self, from: data), file.format == "atelier-characters" else {
      return nil
    }
    var added = 0
    var replaced = 0
    for entry in file.characters {
      var character = entry.character
      character.images = []
      character.mainImage = nil
      if let existing = characters.firstIndex(where: { $0.name.caseInsensitiveCompare(character.name) == .orderedSame }) {
        for image in characters[existing].images { forgetImage(image) }
        character.id = characters[existing].id
        characters[existing] = character
        replaced += 1
      } else {
        character.id = UUID()
        characters.append(character)
        added += 1
      }
      let images = entry.images ?? entry.image.map { [FileFormat.SavedImage(image: $0, info: entry.info)] } ?? []
      for (index, saved) in images.enumerated() {
        guard let image = ImageLoader.image(from: saved.image),
              let id = addSavedImage(image, info: saved.info, to: character.id)
        else { continue }
        if index == entry.main { makeMain(id, of: character.id) }
      }
    }
    writeNow()
    return (added, replaced)
  }
}
