import SwiftUI

/// The Edit screen's tools, in its bottom bar's picker (`ToolPicker`): what a drag on the image
/// does. Move pans; Crop draws and moves the crop rectangle. Heal joins them later. Not
/// remembered across launches: the screen starts with Move.
nonisolated enum EditTool: String, ScreenTool {
  case move, crop

  var id: Self { self }

  var title: String {
    switch self {
    case .move: "Move"
    case .crop: "Crop"
    }
  }

  var systemImage: String {
    switch self {
    case .move: "hand.raised"
    case .crop: "crop"
    }
  }

  /// Whether the tool works in one pane: the comparisons that show two (Side by Side) or split
  /// one (Slider) go to Hold for Original when it's picked (D5).
  var needsSinglePane: Bool { self != .move }
}

/// The bottom bar's tool picker, as Create's status bar has its own.
struct EditToolPicker: View {
  @Environment(EditModel.self) private var edit

  static let help = "Move drags the image; Crop draws the crop over the whole image (drag a handle to resize, inside to move it, outside to draw a new one). Leaving Crop applies it."

  var body: some View {
    @Bindable var edit = edit
    ToolPicker("Edit Tool", selection: $edit.tool, help: Self.help)
      .disabled(!edit.hasSource)
  }
}
