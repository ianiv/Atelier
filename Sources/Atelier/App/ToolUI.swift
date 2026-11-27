import SwiftUI

// The tool chrome Create and Edit share, so both screens follow the same rules: a segmented tool
// picker and the tool's settings in the status bar, the tool's own controls in a glass bar over the
// bottom of the image, every control always there (disabled when it can't act).

/// A tool in a screen's segmented picker: anything done by dragging on the image.
/// `nonisolated`, as its tools must be: the default MainActor isolation would otherwise block their
/// Hashable/CaseIterable conformances.
nonisolated protocol ScreenTool: Hashable, Identifiable, CaseIterable where AllCases: RandomAccessCollection {
  var title: String { get }
  var systemImage: String { get }
}

/// The screen's segmented tool picker (icon-only, `.fixedSize()`), for the status bar.
/// Segments a tool can't use now are disabled one by one (`isEnabled`), so the picker never changes
/// shape; the whole picker is disabled with `.disabled` from outside.
struct ToolPicker<Tool: ScreenTool>: View {
  let title: String
  @Binding var selection: Tool
  let tools: [Tool]
  let help: String
  let isEnabled: (Tool) -> Bool

  init(_ title: String, selection: Binding<Tool>, tools: [Tool] = Array(Tool.allCases), help: String, isEnabled: @escaping (Tool) -> Bool = { _ in true }) {
    self.title = title
    _selection = selection
    self.tools = tools
    self.help = help
    self.isEnabled = isEnabled
  }

  var body: some View {
    Picker(title, selection: $selection) {
      ForEach(tools) { tool in
        Label(tool.title, systemImage: tool.systemImage)
          .tag(tool)
          // `selectionDisabled` is what greys one segment of a segmented picker; `.disabled` on
          // the item doesn't reach it.
          .selectionDisabled(!isEnabled(tool))
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .labelStyle(.iconOnly)
    .fixedSize()
    .help(help)
  }
}

/// A tool's own bar over the bottom of the image: the glass panel, small borderless controls,
/// callout font; one row when it fits, else `second` on a row of its own (an iPad in portrait, a
/// narrow window). `footer` goes under the rows at the panel's width, not fixed-size, so a long
/// message wraps instead of widening the bar.
///
/// The `second:` group decides the split by its type (anything but `EmptyView`), not by what it
/// shows, so pass one only when it always has controls; it also keeps to the rule that controls
/// don't appear and disappear.
struct ToolBarPanel<First: View, Second: View, Footer: View>: View {
  let help: String?
  let first: First
  let second: Second
  let footer: Footer
  /// Whether there's a second group: without one the bar is a single row and nothing to fit.
  let splits: Bool

  init(help: String? = nil, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second, @ViewBuilder footer: () -> Footer) {
    self.help = help
    self.first = first()
    self.second = second()
    self.footer = footer()
    splits = Second.self != EmptyView.self
  }

  var body: some View {
    VStack(spacing: 4) {
      rows
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
      footer
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
    .modifier(OptionalHelp(text: help))
  }

  @ViewBuilder private var rows: some View {
    if splits {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          first
          Divider().frame(height: 18)
          second
        }
        VStack(spacing: 6) {
          HStack(spacing: 8) { first }
          HStack(spacing: 8) { second }
        }
      }
    } else {
      HStack(spacing: 8) { first }
    }
  }
}

extension ToolBarPanel where Footer == EmptyView {
  init(help: String? = nil, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
    self.init(help: help, first: first, second: second, footer: { EmptyView() })
  }
}

extension ToolBarPanel where Second == EmptyView, Footer == EmptyView {
  init(help: String? = nil, @ViewBuilder _ row: () -> First) {
    self.init(help: help, first: row, second: { EmptyView() }, footer: { EmptyView() })
  }
}

/// `.help` only when there's text: an empty tooltip would still be attached on every platform.
private struct OptionalHelp: ViewModifier {
  let text: String?

  func body(content: Content) -> some View {
    if let text { content.help(text) } else { content }
  }
}

/// A brush size, for the status bar: a menu of `sizes` showing "64 px", with a chevron so the plain
/// text reads as a control.
struct BrushSizeMenu: View {
  static let sizes: [Double] = [8, 16, 32, 64, 128, 256]

  let title: String
  @Binding var size: Double
  let sizes: [Double]
  let help: String

  init(_ title: String, size: Binding<Double>, sizes: [Double] = BrushSizeMenu.sizes, help: String) {
    self.title = title
    _size = size
    self.sizes = sizes
    self.help = help
  }

  var body: some View {
    Menu {
      ForEach(sizes, id: \.self) { choice in
        Button("\(Int(choice)) px") { size = choice }
      }
    } label: {
      Text("\(Int(size)) px").monospacedDigit().frame(minWidth: 44).touchTarget()
    }
    .menuIndicator(.visible)
    .fixedSize()
    .help(help)
    .accessibilityLabel(title)
    .accessibilityValue("\(Int(size)) px")
  }
}

extension View {
  /// Puts a tool's bar over the bottom of the image (8 pt up, 16 pt in), outside the image's
  /// gestures, so a click on the bar never reaches the tool.
  func toolBarOverlay<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
    overlay(alignment: .bottom) {
      bar().padding(.bottom, 8).padding(.horizontal, 16)
    }
  }
}

/// A brush cursor/outline: the circle of `radius` image pixels at the pointer, drawn at the zoom
/// (`pointsPerPixel`), dark inside light so it shows on any image. Nothing when there's no pointer.
/// It takes no hits, so it never comes between the pointer and the tool's gesture.
///
/// It stands in for the pointer over a brush's image (the screen hides the system one with
/// `brushPointerHidden`), so it shows the brush's real footprint: dashed when the stroke erases,
/// with a faint dashed `innerRadius` where a soft edge begins (Heal's feather), and a small cross
/// when the circle would be too small to see, so the pointer never vanishes.
struct BrushOutline: View {
  let center: CGPoint?
  let radius: Double
  let pointsPerPixel: Double
  /// Where the brush's soft edge begins, in image pixels; nil for a hard brush.
  var innerRadius: Double?
  /// The stroke erases (Eraser, or Option with Brush): the ring is dashed.
  var erases = false

  /// Below this many points across, the ring gives way to a cross: a 4 pt circle reads as a dot
  /// and hides what's under the pointer.
  static let minimumDiameter: Double = 6

  /// A brush sized in frame pixels (Create's, which covers the same part of the frame at any
  /// zoom): its outline at `pointsPerFramePixel`, the canvas's points per frame pixel.
  init(center: CGPoint?, frameBrushSize size: Double, pointsPerFramePixel points: Double, erases: Bool = false) {
    self.init(center: center, radius: size / 2, pointsPerPixel: points, erases: erases)
  }

  init(center: CGPoint?, radius: Double, pointsPerPixel: Double, innerRadius: Double? = nil, erases: Bool = false) {
    self.center = center
    self.radius = radius
    self.pointsPerPixel = pointsPerPixel
    self.innerRadius = innerRadius
    self.erases = erases
  }

  /// A feathered brush's inner radius: full strength up to `radius × (1 − feather)`, as
  /// `HealBrush.mask` paints it.
  static func innerRadius(radius: Double, feather: Double) -> Double {
    max(radius * (1 - min(max(feather, 0), 1)), 0)
  }

  /// The outline's diameter in points.
  var diameter: Double { max(radius * 2 * pointsPerPixel, 0) }

  /// The soft edge's inner ring in points; nil with no feather or when it'd crowd the outline.
  var innerDiameter: Double? {
    guard let innerRadius, !isTiny else { return nil }
    let inner = max(innerRadius * 2 * pointsPerPixel, 0)
    return inner >= Self.minimumDiameter && inner < diameter - 2 ? inner : nil
  }

  /// Too small for a ring to show: a cross is drawn instead.
  var isTiny: Bool { diameter < Self.minimumDiameter }

  var body: some View {
    ZStack {
      if isTiny {
        TinyBrushMark()
      } else {
        let dash: [CGFloat] = erases ? [4, 3] : []
        let diameter = diameter
        ZStack {
          Circle().stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: dash))
          Circle().stroke(.black.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: dash))
        }
        .frame(width: diameter, height: diameter)
        if let inner = innerDiameter {
          ZStack {
            Circle().stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [2, 3]))
            Circle().stroke(.black.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
          }
          .frame(width: inner, height: inner)
        }
      }
    }
    .position(center ?? .zero)
    .opacity(center == nil ? 0 : 1)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// A tiny brush's mark: a small cross, white under black as the ring is, at the brush's centre.
private struct TinyBrushMark: View {
  var body: some View {
    let cross = Path { path in
      path.move(to: CGPoint(x: 5.5, y: 0))
      path.addLine(to: CGPoint(x: 5.5, y: 11))
      path.move(to: CGPoint(x: 0, y: 5.5))
      path.addLine(to: CGPoint(x: 11, y: 5.5))
    }
    ZStack {
      cross.stroke(.white.opacity(0.9), lineWidth: 3)
      cross.stroke(.black.opacity(0.8), lineWidth: 1)
    }
    .frame(width: 11, height: 11)
  }
}

/// Where the pointer is over a brush's image, written by the screen's hover and drag and read only
/// by the cursor view (as `HealDrag.hover` is in Edit): every pointer move then redraws the
/// cursor, not the screen.
@MainActor
@Observable
final class BrushPointer {
  var location: CGPoint?
}
