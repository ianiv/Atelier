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
