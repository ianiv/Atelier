import SwiftUI

/// The Crop tool's bar, over the bottom of the image: the Aspect menu, Orientation, the crop's
/// size in pixels and Reset Crop. Every control is always there, disabled when it can't act.
struct CropBar: View {
  @Environment(EditModel.self) private var edit
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    let crop = edit.retouch.crop
    let size = edit.outputSize
    ToolBarPanel {
      Menu {
        Picker("Aspect", selection: Binding(get: { crop?.aspect }, set: { edit.setCropAspect($0, undoManager: undoManager) })) {
          Text("Free").tag(Edit.CropAspect?.none)
          Divider()
          ForEach(Edit.CropAspect.allCases, id: \.self) { aspect in
            Text(aspect.title).tag(Edit.CropAspect?.some(aspect))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } label: {
        Text(crop?.aspect.map { $0.label(swapped: crop?.swapped ?? false) } ?? "Free")
      }
      .menuIndicator(.visible)
      .fixedSize()
      .help("The crop's aspect ratio: Free, the image's own, or a fixed ratio")
      .accessibilityLabel("Aspect")
      Button("Orientation", systemImage: "rotate.right") { edit.swapCropOrientation(undoManager: undoManager) }
        .labelStyle(.iconOnly)
        .help("Turn the crop's ratio on its side (4:5 to 5:4)")
        .disabled(!edit.canSwapCropOrientation)
      // A readout, not a control.
      Text(size.map { "\($0.width) × \($0.height)" } ?? "–")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityLabel("Crop size")
      Button("Reset Crop") { edit.resetCrop(undoManager: undoManager) }
        .help("Take the crop off: the whole image again")
        .disabled(crop == nil)
    }
  }
}
