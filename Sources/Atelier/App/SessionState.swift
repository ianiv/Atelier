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

/// The Edit screen's crop at quit, for the step `EditSession` names (D10): kept whether or not
/// it was saved, so a relaunch shows the image as it was left. A small JSON file in Application
/// Support rather than UserDefaults, as it'll hold Heal strokes too. Scripted runs neither read nor
/// write it.
nonisolated struct EditRetouchSession: Codable, Equatable {
  var project: String
  var tensorId: Int64
  var crop: Edit.Crop

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
