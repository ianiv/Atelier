import SwiftUI

/// What the Create screen was showing at quit, so a relaunch comes back the same.
/// Scripted runs (Automation) neither read nor write it, so they don't clobber the user's session.
nonisolated struct SessionState: Codable {
  var model: String?
  var prompt = ""
  var negativePrompt = ""
  var seed: UInt32?
  /// Every inspector value, in the history sidecar's dump format.
  var settings: [String: JSONValue]?
  /// The image last on the canvas: a step in a project, and its image tensor (the step's number
  /// can change when a fork or delete renumbers steps; the tensor doesn't).
  var imageProject: String?
  var imageStep: StepID?
  var imageTensorId: Int64?
  /// Where new jobs were set to run (Run on); nil in sessions saved before there was a choice.
  var runTarget: JobTarget?
  /// The trigger words turned on, by LoRA file, for LoRAs whose words were set
  /// (`CreateModel.triggerWordChoices`); nil in sessions saved before there were any, which still decode.
  var triggerWordChoices: [String: [String]]?

  private static let key = "sessionState"
  static var isEnabled: Bool { !Automation.isRequested }

  static func load() -> SessionState? {
    guard isEnabled, let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(SessionState.self, from: data)
  }

  func save() {
    guard Self.isEnabled, let data = try? JSONEncoder().encode(self) else { return }
    UserDefaults.standard.set(data, forKey: Self.key)
  }
}

/// The Edit screen's image at quit, a step of a project by its tensor (which a renumbering
/// doesn't change), so a relaunch opens it again. Kept apart from `SessionState`, which the Create
/// screen writes whole; like it, scripted runs neither read nor write it.
nonisolated struct EditSession: Codable, Equatable {
  var project: String
  var tensorId: Int64

  private static let key = "editSession"

  static func load(_ defaults: UserDefaults = .standard) -> EditSession? {
    guard SessionState.isEnabled, let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(EditSession.self, from: data)
  }

  func save(_ defaults: UserDefaults = .standard) {
    guard SessionState.isEnabled, let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.key)
  }

  /// An image that isn't a step was opened: nothing to bring back.
  static func clear(_ defaults: UserDefaults = .standard) {
    guard SessionState.isEnabled else { return }
    defaults.removeObject(forKey: key)
  }
}

/// The Edit screen's crop and Heal strokes at quit, for the step `EditSession` names (D10): kept
/// whether or not they were saved, so a relaunch shows the image as it was left. A small JSON file
/// in Application Support rather than UserDefaults, as the strokes can run to tens of KB. Scripted
/// runs neither read nor write it.
nonisolated struct EditRetouchSession: Codable, Equatable {
  var project: String
  var tensorId: Int64
  var crop: Edit.Crop?
  /// Nil for none (and in a file written before Heal).
  var heal: Edit.HealStrokes?
  /// The step's saved crop and strokes were taken off on the screen (Reset Crop, Clear Heal) and
  /// not saved: a relaunch keeps them off rather than bringing the record's back.
  var cleared: Bool

  init(project: String, tensorId: Int64, crop: Edit.Crop?, heal: Edit.HealStrokes?) {
    self.project = project
    self.tensorId = tensorId
    self.crop = crop
    self.heal = heal.flatMap { $0.isEmpty ? nil : $0 }
    cleared = crop == nil && self.heal == nil
  }

  /// What to keep for the step at a quit: its crop and strokes when it has any; a `cleared` file
  /// when it has none but the step it was opened from recorded some (`recorded`), so the record's
  /// don't come back; nil (no file) when there's nothing either way.
  static func keeping(project: String, tensorId: Int64, retouch: Edit.Retouch, recorded: Bool) -> EditRetouchSession? {
    guard !retouch.isIdentity || recorded else { return nil }
    return EditRetouchSession(project: project, tensorId: tensorId, crop: retouch.crop, heal: retouch.heal)
  }

  /// The retouch to put back on the step at a relaunch: the file's, which for a `cleared` one is
  /// none.
  var retouch: Edit.Retouch { cleared ? .none : Edit.Retouch(crop: crop, heal: heal ?? .empty) }

  private enum CodingKeys: String, CodingKey { case project, tensorId, crop, heal, cleared }

  /// Strict for the step, lenient for the rest: unreadable strokes (a newer encoding) leave the
  /// crop, and a damaged crop leaves the strokes.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    project = try c.decode(String.self, forKey: .project)
    tensorId = try c.decode(Int64.self, forKey: .tensorId)
    crop = (try? c.decodeIfPresent(Edit.Crop.self, forKey: .crop)) ?? nil
    heal = (try? c.decodeIfPresent(Edit.HealStrokes.self, forKey: .heal)) ?? nil
    // Before `cleared`, a file was only written with a crop.
    cleared = ((try? c.decodeIfPresent(Bool.self, forKey: .cleared)) ?? nil) ?? false
  }

  static var url: URL { URL.applicationSupportDirectory.appending(path: "Atelier/Edit Retouch.json") }

  static func load(from url: URL = url) -> EditRetouchSession? {
    guard SessionState.isEnabled, let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(EditRetouchSession.self, from: data)
  }

  func save(to url: URL = Self.url) {
    guard SessionState.isEnabled, let data = try? JSONEncoder().encode(self) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }

  static func clear(at url: URL = url) {
    guard SessionState.isEnabled else { return }
    try? FileManager.default.removeItem(at: url)
  }
}

/// The one deadline every will-terminate handler that waits for writes shares (the moodboard's
/// files, input entries still to be recorded), so together they stay within the few seconds iOS
/// gives an app that's ending. The first handler to ask starts it; the later ones get what's left.
@MainActor
enum QuitDeadline {
  /// How long all the waits at quit take at most, together.
  static let total: TimeInterval = 4.5
  private static var started: Date?

  static var date: Date {
    if let started { return started }
    let date = Date().addingTimeInterval(total)
    started = date
    return date
  }
}
