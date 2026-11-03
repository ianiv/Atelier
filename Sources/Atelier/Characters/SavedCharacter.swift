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

  init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, notes, knobs, texts, nouns, editedDescription, styleID, tagValues
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

/// A render of a character. Previews aren't saved anywhere: they go when the app quits, or sooner
/// when Save to Character or Send to Create keeps one.
struct CharacterPreview: Identifiable {
  let id = UUID()
  let image: CGImage
  let info: CharacterImageInfo
}

/// The characters, in `Characters.json` in Application Support, each with one saved image in
/// `CharacterImages`: like a style's thumbnail, a square JPEG for the library with the full image
/// and how it was made beside it.
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
  /// The preview shown large, by character; none shows the saved image.
  var shownPreview: [UUID: UUID] = [:]
  /// Saved images read so far (`.some(nil)` is one with none).
  private(set) var thumbnails: [UUID: CGImage?] = [:]
  private(set) var savedImages: [UUID: CGImage] = [:]
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
    if let data = try? Data(contentsOf: file) {
      characters = (try? JSONDecoder().decode([SavedCharacter].self, from: data)) ?? []
    }
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
    var name = "New SavedCharacter"
    var number = 2
    while taken.contains(name) {
      name = "New SavedCharacter \(number)"
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

  /// The copy keeps the saved image, as files of its own.
  func duplicate(_ id: UUID) {
    guard let original = character(id: id) else { return }
    var copy = original
    copy.id = UUID()
    copy.name += " copy"
    characters.insert(copy, at: (characters.firstIndex { $0.id == id } ?? characters.count - 1) + 1)
    try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    for (from, to) in zip(imageFiles(id), imageFiles(copy.id)) {
      try? FileManager.default.copyItem(at: from, to: to)
    }
    selection = copy.id
    scheduleWrite()
  }

  func delete(_ id: UUID) {
    if renderRun?.character == id { stopRendering() }
    characters.removeAll { $0.id == id }
    for file in imageFiles(id) { try? FileManager.default.removeItem(at: file) }
    previews[id] = nil
    shownPreview[id] = nil
    thumbnails[id] = nil
    savedImages[id] = nil
    savedInfo[id] = nil
    if selection == id { selection = nil }
    scheduleWrite()
  }

  private func scheduleWrite() {
    pendingWrite?.cancel()
    pendingWrite = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.write()
    }
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

  /// Reads the saved image's square the first time it's shown.
  func loadThumbnail(_ id: UUID) async {
    guard thumbnails[id] == nil else { return }
    let url = imageFiles(id)[0]
    let image = await Task.detached { ImageLoader.image(at: url) }.value
    thumbnails[id] = .some(image)
  }

  /// Reads the saved image full size and how it was made, the first time it's shown large.
  func loadSaved(_ id: UUID) async {
    guard savedImages[id] == nil else { return }
    let files = imageFiles(id)
    let (image, info) = await Task.detached { () -> (CGImage?, CharacterImageInfo?) in
      let image = ImageLoader.image(at: files[1]) ?? ImageLoader.image(at: files[0])
      let info = (try? Data(contentsOf: files[2])).flatMap { try? JSONDecoder().decode(CharacterImageInfo.self, from: $0) }
      return (image, info)
    }.value
    if let image { savedImages[id] = image }
    if let info { savedInfo[id] = info }
  }

  func thumbnail(_ id: UUID) -> CGImage? { thumbnails[id] ?? nil }

  /// Makes this image the character's saved image, replacing the one before.
  func setSavedImage(_ image: CGImage, info: CharacterImageInfo?, for id: UUID) {
    do {
      try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
      let files = imageFiles(id)
      for file in files { try? FileManager.default.removeItem(at: file) }
      guard let square = StyleStore.square(image, side: StyleStore.thumbnailSize),
            let jpeg = ImageTensor.jpeg(square, quality: 0.85), let png = ImageTensor.png(image)
      else { throw CocoaError(.fileWriteUnknown) }
      try Data(jpeg).write(to: files[0], options: .atomic)
      try png.write(to: files[1], options: .atomic)
      if let info { try JSONEncoder().encode(info).write(to: files[2], options: .atomic) }
      thumbnails[id] = .some(square)
      savedImages[id] = image
      savedInfo[id] = info
    } catch {
      renderError = "Couldn't save the image: \(error.localizedDescription)"
    }
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

  /// Renders the character in each style (nil is No Style), one after another in the queue, with
  /// the model, settings and seed on Create: one seed, so the styles compare like for like and
  /// moving one knob shows only that knob's effect. Create's negative prompt, canvas and moodboard
  /// aren't used. The images aren't saved to the project, and become previews.
  func render(_ character: SavedCharacter, in styles: [Style?], create: CreateModel) {
    guard renderRun == nil, !styles.isEmpty, renderBlocker(create, for: character) == nil,
          let model = create.selectedModel, let settings = create.settings
    else { return }
    let subject = description(of: character).trimmed
    let seed = create.seed
    var used = settings
    used.seed = seed
    let dump = JSONValue.fields(of: used)
    let reference = knobs.referenceStyle
    renderError = nil
    renderRun = (character.id, 0, styles.count, 0, styles[0]?.name ?? reference.name)
    renderTask = Task { [weak self] in
      for style in styles {
        guard let self, !Task.isCancelled else { break }
        let used = style ?? reference
        renderRun?.current = used.name
        var values = character.tagValues
        values[Style.subject] = subject
        let prompts = used.apply(values, negativePrompt: "")
        let request = GenerationEngine.Request(
          model: model, prompt: prompts.prompt, negativePrompt: prompts.negativePrompt, seed: seed,
          configuration: settings)
        do {
          let image = try await create.generateCharacterPreview(request, label: "\(character.name) in \(used.name)")
          let info = CharacterImageInfo(
            source: ThumbnailSource(
              prompt: prompts.prompt, negativePrompt: prompts.negativePrompt, model: model, seed: seed, settings: dump),
            styleID: style?.id, styleName: used.name, tagValues: character.tagValues, subject: subject)
          let preview = CharacterPreview(image: image, info: info)
          previews[character.id, default: []].insert(preview, at: 0)
          shownPreview[character.id] = preview.id
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

  /// A characters file: a JSON list of characters, each with its saved image and how it was made.
  struct FileFormat: Codable {
    struct Entry: Codable {
      var character: SavedCharacter
      var image: Data?
      var info: CharacterImageInfo?
    }

    var format = "atelier-characters"
    var version = 1
    var characters: [Entry]
  }

  /// The characters as a file, with their saved images.
  func exported(_ ids: [UUID]) -> Data {
    let entries = ids.compactMap { id -> FileFormat.Entry? in
      guard let character = character(id: id) else { return nil }
      let files = imageFiles(id)
      let image = try? Data(contentsOf: files[1])
      let info = (try? Data(contentsOf: files[2])).flatMap { try? JSONDecoder().decode(CharacterImageInfo.self, from: $0) }
      return FileFormat.Entry(character: character, image: image, info: info)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(FileFormat(characters: entries))) ?? Data()
  }

  /// Adds the characters in a file. One with the same name as a character here replaces it, keeping
  /// its id. Returns how many came in, or nil when it isn't a characters file.
  func importCharacters(_ data: Data) -> (added: Int, replaced: Int)? {
    guard let file = try? JSONDecoder().decode(FileFormat.self, from: data), file.format == "atelier-characters" else {
      return nil
    }
    var added = 0
    var replaced = 0
    for entry in file.characters {
      var character = entry.character
      if let existing = characters.firstIndex(where: { $0.name.caseInsensitiveCompare(character.name) == .orderedSame }) {
        character.id = characters[existing].id
        characters[existing] = character
        replaced += 1
      } else {
        character.id = UUID()
        characters.append(character)
        added += 1
      }
      if let data = entry.image, let image = ImageLoader.image(from: data) {
        setSavedImage(image, info: entry.info, for: character.id)
      }
    }
    scheduleWrite()
    return (added, replaced)
  }
}
