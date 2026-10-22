import AppKit
import SwiftUI

/// What the Create screen was showing at quit, so a relaunch comes back the same.
/// Scripted runs (Automation) neither read nor write it, so they don't clobber the user's session.
struct SessionState: Codable {
  var model: String?
  var prompt = ""
  var negativePrompt = ""
  var seed: UInt32?
  /// Every inspector value, in the history sidecar's dump format.
  var settings: [String: JSONValue]?
  /// The image last on the canvas (a saved history file).
  var imagePath: String?

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

/// Gives the hosting window a stable frame autosave name. SwiftUI's own name is built from the
/// view's modifier types, so it changes whenever a modifier is added and the frame is forgotten.
struct WindowFrameAutosave: NSViewRepresentable {
  let name: String

  func makeNSView(context: Context) -> NSView { AutosaveView(name: name) }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class AutosaveView: NSView {
    let name: String
    init(name: String) {
      self.name = name
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, window.frameAutosaveName != name, SessionState.isEnabled else { return }
      // Set after SwiftUI sizes the window, or its default size wins over the saved frame.
      DispatchQueue.main.async { [name] in
        window.setFrameUsingName(name)
        window.setFrameAutosaveName(name)
      }
    }
  }
}
