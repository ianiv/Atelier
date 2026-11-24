import SwiftUI

/// The before/after comparisons shared by the Edit screen and Match Colors…: the Slider mode's
/// picture (`SliderComparison`), and the Edit screen's choice of how to compare.
enum Compare {
  /// How the Edit screen shows the original beside the edit.
  enum Mode: String, CaseIterable, Codable, Sendable {
    /// The edit alone, with the original shown while Hold for Original is held.
    case hold
    /// Next to each other, zoomed and moved together.
    case sideBySide = "side"
    /// One picture, the original to the left of a divider that's dragged across it.
    case slider

    var title: String {
      switch self {
      case .hold: "Hold for Original"
      case .sideBySide: "Side by Side"
      case .slider: "Slider"
      }
    }
  }

  /// A caption under a picture.
  static func label(_ title: String) -> some View {
    Text(title).font(.caption).foregroundStyle(.secondary)
  }

  /// The text in a picture's place while it isn't there.
  static func note(_ text: String?) -> some View {
    Text(text ?? "").font(.caption).foregroundStyle(.secondary)
      .multilineTextAlignment(.center).padding(8)
  }
}

/// The Slider mode's picture: the match, with the original over it to the left of the divider.
/// Both are laid in one rectangle of the edited image's shape, worked out here rather than
/// left to each image's own fit, so they line up pixel for pixel whatever rounding either
/// would do (and an original of another shape is fit inside the same rectangle). The labels
/// sit under the picture's own corners, not the box's, so each is by the side it names.
///
/// A view of its own, holding where the divider is, so that dragging it draws only this again
/// and not the whole sheet or screen with its sliders. The matched picture is the caller's and
/// comes in as it is: nothing here asks for it to be made again. Match Colors… names the two
/// sides Original and Matched; the Edit screen names the right one Edited.
struct SliderComparison: View {
  let matched: CGImage?
  let original: CGImage?
  /// What stands in for the matched picture while there's none.
  let matchedNote: String?
  /// The edited image's size, once the preview has it; the original's shape stands in until then.
  let shape: CGSize?
  /// The right-hand side's name.
  var matchedTitle = "Matched"
  /// The left-hand side's name.
  var originalTitle = "Original"
  /// Where the divider is, as a fraction of the picture's width. Not remembered: the middle
  /// is where a comparison starts.
  @State private var divider = 0.5

  var body: some View {
    GeometryReader { geometry in
      let box = CGSize(width: geometry.size.width, height: max(0, geometry.size.height - Self.labelsHeight))
      let size = Self.fitted(shape ?? original.map { CGSize(width: $0.width, height: $0.height) }, in: box)
      VStack(spacing: 0) {
        ZStack {
          RoundedRectangle(cornerRadius: 6).fill(.quaternary)
          comparedPictures(size: size)
        }
        .frame(width: box.width, height: box.height)
        HStack {
          Compare.label(originalTitle)
          Spacer()
          Compare.label(matchedTitle)
        }
        .frame(width: size.width, height: Self.labelsHeight, alignment: .bottom)
      }
    }
  }

  /// The room under the picture for its labels: a caption's line and the gap above it, as
  /// under the Side by Side pictures.
  private static let labelsHeight: CGFloat = 22

  /// The match and, over it left of the divider, the original, both `size`, with the divider.
  /// The pictures are named for accessibility, since here there's no box around each to name.
  private func comparedPictures(size: CGSize) -> some View {
    let x = size.width * divider
    return ZStack(alignment: .leading) {
      if let matched {
        Image(matched, scale: 1, label: Text(matchedTitle)).resizable().frame(width: size.width, height: size.height)
      } else {
        // In the half the match will show in.
        Compare.note(matchedNote)
          .frame(width: max(0, size.width - x), height: size.height)
          .frame(width: size.width, height: size.height, alignment: .trailing)
      }
      if let original {
        // An original of another shape leaves bands beside or above it. They're filled, and
        // opaquely, inside the same mask as the picture: otherwise the match under them would
        // show on the Original side. The fill is the Side by Side box's, over the sheet's
        // background because that tint alone is see-through.
        ZStack {
          Rectangle().fill(.background)
          Rectangle().fill(.quaternary)
          Image(original, scale: 1, label: Text(originalTitle)).resizable().aspectRatio(contentMode: .fit)
        }
        .frame(width: size.width, height: size.height)
        .mask(alignment: .leading) { Rectangle().frame(width: x) }
      }
      // Drawn inside the picture's edges even with the divider at one of them, where half of
      // each would be clipped away. Only where they're drawn is held in: `x`, which is what's
      // revealed, still goes all the way to both edges.
      dividerLine(height: size.height)
        .offset(x: Self.inset(x - Self.lineWidth / 2, width: Self.lineWidth, in: size.width))
      dividerHandle(height: size.height)
        .offset(x: Self.inset(x - Self.handleSize / 2, width: Self.handleSize, in: size.width))
    }
    .frame(width: size.width, height: size.height)
    .clipShape(.rect(cornerRadius: 6))
    .contentShape(.rect)
    // From the first touch, so a click anywhere on the picture brings the divider there.
    .gesture(
      DragGesture(minimumDistance: 0).onChanged { value in
        guard size.width > 0 else { return }
        divider = min(1, max(0, value.location.x / size.width))
      })
  }

  private static let handleSize: CGFloat = 28
  private static let lineWidth: CGFloat = 2

  /// `leading`, moved as little as keeps something `width` wide inside 0...`total`.
  private static func inset(_ leading: CGFloat, width: CGFloat, in total: CGFloat) -> CGFloat {
    min(max(0, total - width), max(0, leading))
  }

  /// The divider's line. Light with a dark edge, as its handle is, so it shows on any picture.
  private func dividerLine(height: CGFloat) -> some View {
    Rectangle().fill(.white).frame(width: Self.lineWidth, height: height)
      .shadow(color: .black.opacity(0.6), radius: 1)
      .accessibilityHidden(true)
  }

  /// The divider's handle, in a column `handleSize` wide and as tall as the picture, which is
  /// the element that's adjusted.
  private func dividerHandle(height: CGFloat) -> some View {
    Circle().fill(.white)
      .shadow(color: .black.opacity(0.5), radius: 2)
      .overlay {
        Image(systemName: "chevron.left.chevron.right")
          .font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.7))
      }
      .frame(width: Self.handleSize, height: Self.handleSize)
      .frame(width: Self.handleSize, height: height)
      .accessibilityElement()
      .accessibilityLabel("Comparison position")
      .accessibilityValue("\(Int((divider * 100).rounded())) percent")
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: divider = min(1, divider + 0.05)
        case .decrement: divider = max(0, divider - 0.05)
        @unknown default: break
        }
      }
  }

  /// The largest size of `shape`'s proportions inside `bounds`, in whole points so both
  /// pictures land on the same pixels; all of `bounds` when there's no shape yet.
  private static func fitted(_ shape: CGSize?, in bounds: CGSize) -> CGSize {
    guard let shape, shape.width > 0, shape.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    let scale = min(bounds.width / shape.width, bounds.height / shape.height)
    return CGSize(width: max(1, (shape.width * scale).rounded(.down)), height: max(1, (shape.height * scale).rounded(.down)))
  }
}
