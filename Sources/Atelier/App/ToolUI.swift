import SwiftUI

// The tool chrome Create and Edit share, so both screens follow the same rules: a segmented tool
// picker and the tool's settings in the status bar, the tool's own controls in a glass bar over the
// bottom of the image, every control always there (disabled when it can't act).

/// A tool in a screen's segmented picker: anything done by dragging on the image.
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
  func toolBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
    overlay(alignment: .bottom) {
      bar().padding(.bottom, 8).padding(.horizontal, 16)
    }
  }
}

/// A brush cursor/outline: the circle of `radius` image pixels at the pointer, drawn at the zoom
/// (`pointsPerPixel`), dark inside light so it shows on any image. Nothing when there's no pointer.
/// It takes no hits, so it never comes between the pointer and the tool's gesture.
struct BrushOutline: View {
  let center: CGPoint?
  let radius: Double
  let pointsPerPixel: Double

  /// The outline's diameter in points.
  var diameter: Double { max(radius * 2 * pointsPerPixel, 0) }

  var body: some View {
    let diameter = diameter
    ZStack {
      Circle().stroke(.white.opacity(0.9), lineWidth: 2)
      Circle().stroke(.black.opacity(0.7), lineWidth: 1)
    }
    .frame(width: diameter, height: diameter)
    .position(center ?? .zero)
    .opacity(center == nil ? 0 : 1)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
