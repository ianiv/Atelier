import SwiftUI

/// The mask controls, over the bottom of the canvas while Brush or Eraser draws on the Mask layer
/// (on iPad, with any tool but Select, as the Pencil paints the layer whatever the tool), as
/// `PaintBar` is for the Color layer: Invert, Clear Mask, Mask Colored Areas, and Copy and Paste
/// Mask. Every control stays; ones that can't act are disabled.
struct MaskBar: View {
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    let paints = model.canPaintMask
    let edits = model.canEditMask
    HStack(spacing: 8) {
      Button("Invert", systemImage: "circle.lefthalf.filled") {
        model.invertMask(undoManager: undoManager)
      }
      .help("Invert Mask")
      // Inverting nothing paints everything, which needs a target that takes masks.
      .disabled(!edits || (model.canvasMask == nil && !paints))
      Button("Clear Mask", systemImage: "xmark.circle") {
        model.clearMask(undoManager: undoManager)
      }
      .help("Clear Mask")
      .disabled(!edits || model.canvasMask == nil)
      Button("Mask Colored Areas", systemImage: "paintbrush") {
        model.maskColoredAreas(undoManager: undoManager)
      }
      .help("Mask Colored Areas: adds wherever colors are painted to the mask")
      .disabled(!model.canMaskColoredAreas)
      Menu("Mask") {
        MaskCopyItems(model: model, undoManager: undoManager)
      }
      .menuIndicator(.visible)
      .fixedSize()
      .help("Copy the mask, or paste one copied from another image")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .fixedSize()
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
  }
}
