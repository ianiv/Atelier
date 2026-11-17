import SwiftUI

/// The Paint tool's controls, over the bottom of the canvas while Paint is the tool (as
/// `AutoMaskBar` is for Select): the colour (the system picker and the colours used last), the
/// paint brush's size, Erase, Clear Paint and Fill Mask. Every control stays; ones that can't act
/// are disabled.
struct PaintBar: View {
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    @Bindable var model = model
    let paints = model.canPaintColor
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        colors(paints)
        Divider().frame(height: 18)
        tools(paints)
      }
      VStack(spacing: 6) {
        HStack(spacing: 8) { colors(paints) }
        HStack(spacing: 8) { tools(paints) }
      }
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .fixedSize()
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
    .help(Self.gestureHelp)
  }

  /// The colour picker and the recent colours.
  @ViewBuilder private func colors(_ paints: Bool) -> some View {
    ColorPicker(
      "Color",
      selection: Binding(get: { model.paintColor.cgColor }, set: { if let color = CanvasPaint.Color($0) { model.paintColor = color } }),
      supportsOpacity: true
    )
    .labelsHidden()
    .help("The color to paint with")
    .disabled(!paints)
    HStack(spacing: 4) {
      // Eight places, so the bar doesn't change size as colours are used.
      ForEach(0..<8, id: \.self) { index in
        let color = model.recentPaintColors.indices.contains(index) ? model.recentPaintColors[index] : nil
        Button {
          if let color { model.paintColor = color }
        } label: {
          Circle()
            .fill(color.map { Color(cgColor: $0.cgColor) } ?? Color.clear)
            .overlay(Circle().strokeBorder(.secondary.opacity(color == model.paintColor ? 1 : 0.4), lineWidth: color == model.paintColor ? 2 : 1))
            .frame(width: 16, height: 16)
            .touchTarget()
        }
        .disabled(!paints || color == nil)
        .help(color.map { "Paint with \($0.hex)" } ?? "Colors you paint with show here")
        .accessibilityLabel(color.map { "Recent color \($0.hex)" } ?? "No recent color")
      }
    }
  }

  /// Size, Erase, Clear Paint and Fill Mask.
  @ViewBuilder private func tools(_ paints: Bool) -> some View {
    @Bindable var model = model
    Menu {
      ForEach(CanvasToolControls.sizes, id: \.self) { size in
        Button("\(Int(size)) px") { model.paintBrushSize = size }
      }
    } label: {
      Text("\(Int(model.paintBrushSize)) px").monospacedDigit().frame(minWidth: 44).touchTarget()
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Paint Brush Size, in frame pixels")
    .disabled(!paints)
    Toggle(isOn: $model.paintErases) {
      Label("Erase", systemImage: "eraser").touchTarget()
    }
    .toggleStyle(.button)
    .help(Self.eraseHelp)
    .disabled(!paints)
    Button("Clear Paint", systemImage: "xmark.circle") {
      model.clearPaint(undoManager: undoManager)
    }
    .help("Clear Paint: takes every color off the image")
    .disabled(!paints || model.canvasPaint == nil)
    Button("Fill Mask", systemImage: "drop.fill") {
      model.fillMask(undoManager: undoManager)
    }
    .help("Fill Mask with Color: paints what the mask covers with the color")
    .disabled(!model.canFillMask)
  }

  private static var eraseHelp: String {
    #if os(iOS)
      "Erase: Apple Pencil takes paint away instead"
    #else
      "Erase: dragging takes paint away instead (or hold Option while painting)"
    #endif
  }

  private static var gestureHelp: String {
    #if os(iOS)
      "Paint colors on the image with Apple Pencil. Fingers move and zoom. Colors go into the next Edit run; they don't change the mask."
    #else
      "Drag to paint colors on the image; Option-drag erases. Hold Space to drag the image. Colors go into the next Edit run; they don't change the mask."
    #endif
  }
}
