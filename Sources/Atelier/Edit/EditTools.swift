import SwiftUI

/// The Edit screen's tools, in its bottom bar's picker (`ToolPicker`): what a drag on the image
/// does. Move pans; Crop draws and moves the crop rectangle; Heal paints over marks with pixels
/// from a source the user sets. Not remembered across launches: the screen starts with Move.
nonisolated enum EditTool: String, ScreenTool {
  case move, crop, heal

  var id: Self { self }

  var title: String {
    switch self {
    case .move: "Move"
    case .crop: "Crop"
    case .heal: "Heal"
    }
  }

  var systemImage: String {
    switch self {
    case .move: "hand.raised"
    case .crop: "crop"
    case .heal: "bandage"
    }
  }

  /// Whether the tool works in one pane: the comparisons that show two (Side by Side) or split
  /// one (Slider) go to Hold for Original when it's picked (D5).
  var needsSinglePane: Bool { self != .move }
}

/// The bottom bar's tool picker, as Create's status bar has its own.
struct EditToolPicker: View {
  @Environment(EditModel.self) private var edit

  static let help = "Move drags the image; Crop draws the crop over the whole image (drag a handle to resize, inside to move it, outside to draw a new one), and leaving Crop applies it; Heal paints over a mark with pixels from a source you set."

  var body: some View {
    @Bindable var edit = edit
    ToolPicker("Edit Tool", selection: $edit.tool, help: Self.help)
      .disabled(!edit.hasSource)
  }
}

/// The Edit status bar's heal brush size (D7): a radius in the image's own pixels, so the outline
/// grows and shrinks with the zoom. Always there; it acts while Heal is the tool.
struct HealBrushSizeMenu: View {
  @Environment(EditModel.self) private var edit

  var body: some View {
    @Bindable var edit = edit
    BrushSizeMenu(
      "Heal Brush Size", size: $edit.healBrushSize, sizes: EditModel.healBrushSizes,
      help: "The heal brush's radius, in the image's pixels")
      .disabled(!edit.hasSource || edit.tool != .heal)
  }
}
