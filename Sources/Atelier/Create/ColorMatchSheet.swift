import SwiftUI

/// Match Colors… on the canvas image: Match Colors to Original with how far the colors and the
/// light move chosen, and whether to measure only what the edit left alone, beside a preview of
/// what they make; then queue it. The result is a new image in History after the edited one, as
/// the one-click item's is.
///
/// The preview is the edited image at a reduced size, matched with the statistics of the full
/// images (`ColorMatch.Preview`), so it shows what the job will make. The pictures take all the
/// room the controls leave, and the sheet opens large: a color cast is hard to judge small.
struct ColorMatchSheet: View {
  /// How the original and the match are laid out to compare them.
  enum CompareMode: String, CaseIterable {
    /// Next to each other.
    case sideBySide = "side"
    /// One picture, the original to the left of a divider that's dragged across it.
    case slider

    var title: String {
      switch self {
      case .sideBySide: "Side by Side"
      case .slider: "Slider"
      }
    }
  }

  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  /// The step it was opened for, kept here: the canvas can change while the sheet is open.
  let item: HistoryItem
  /// Last used, the amounts as fractions from 0 to 1. The one-click menu item doesn't read them.
  @AppStorage("colorMatchTint") private var tint = 1.0
  @AppStorage("colorMatchSaturation") private var saturation = 1.0
  @AppStorage("colorMatchBrightness") private var brightness = 0.0
  @AppStorage("colorMatchContrast") private var contrast = 0.0
  /// On here, though off for the one-click item: the sheet is where an edit that added or
  /// removed something gets matched, which is what it's for.
  @AppStorage("colorMatchUnchangedOnly") private var unchangedOnly = true
  @AppStorage("colorMatchCompareMode") private var compareMode = CompareMode.sideBySide
  /// The height the controls take when all of them show, which is as tall as their scroll view
  /// may grow: the pictures get the rest.
  @State private var controlsHeight: CGFloat = 280
  @State private var preview: ColorMatch.Preview?
  /// The original as read, shown while the two images are still being measured: only the
  /// Matched side has to wait for that.
  @State private var original: CGImage?
  /// The preview has been asked for and came back, with or without one.
  @State private var loaded = false
  @State private var matched: CGImage?

  private var options: ColorMatch.Options {
    ColorMatch.Options(tint: tint, saturation: saturation, brightness: brightness, contrast: contrast, unchangedOnly: unchangedOnly).snapped
  }

  /// What Match queues: `options`, but measuring the whole image when that's what a match from
  /// the unchanged areas would come to anyway (`measurements` fell back, which the preview
  /// already knows). The two make the same image, so they're the same job, and one of each
  /// can't wait side by side. The toggle itself stays as it was set.
  private var queuedOptions: ColorMatch.Options {
    var options = self.options
    if let measurements = preview?.measurements, measurements.unchanged == nil { options.unchangedOnly = false }
    return options
  }

  /// Why Match can't be pressed, if it can't.
  private var problem: String? {
    if !loaded { return "Reading the image and its original…" }
    if preview == nil { return "The image or its original couldn't be read." }
    // Another project was opened under the sheet: the match would be queued for the wrong one.
    if create.history.item(tensorId: item.tensorId) == nil { return "That image isn't in the open project any more." }
    if create.pendingColorMatch(for: item, options: queuedOptions) != nil {
      return "A match with these settings is already waiting or running for this image."
    }
    return nil
  }

  /// The original has another shape, so there are no unchanged areas to find: the toggle can't
  /// do anything.
  private var shapesDiffer: Bool { preview?.measurements.reason == .shape }

  /// What the colors are measured from, under the toggle: how much of the image, or why all of it.
  private var measuredNote: String {
    guard let measurements = preview?.measurements else { return " " }
    func percent(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }
    switch measurements.reason {
    case .shape:
      return "The original has a different shape, so the whole image is measured."
    case .tooLittleUnchanged where unchangedOnly:
      // Most of it was edited, or the whole picture shifted: the one line reads for both.
      return "Too little of the image is unchanged, so the whole image is measured."
    default:
      if unchangedOnly, let counted = measurements.unchanged?.counted { return "Measured from \(percent(counted))% of the image." }
      return "Measured from the whole image."
    }
  }

  var body: some View {
    let options = self.options
    let problem = self.problem
    VStack(alignment: .leading, spacing: 14) {
      Text("Match Colors").font(.headline)
      Picker("Comparison", selection: $compareMode) {
        ForEach(CompareMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .frame(maxWidth: .infinity)
      pictures
        .frame(maxWidth: .infinity, minHeight: Self.minPicturesHeight, maxHeight: .infinity)
      // No taller than what's in it, and ahead of the pictures for room, so they shrink (to
      // `minPicturesHeight`) before it does; then it scrolls (a short iPad window), with the
      // pictures and the buttons staying put.
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            heading("Color")
            slider("Tint", $tint, shown: options.tint)
            slider("Saturation", $saturation, shown: options.saturation)
            heading("Light").padding(.top, 4)
            slider("Brightness", $brightness, shown: options.brightness)
            slider("Contrast", $contrast, shown: options.contrast)
          }
          VStack(alignment: .leading, spacing: 4) {
            Toggle("Measure unchanged areas only", isOn: $unchangedOnly)
              .disabled(shapesDiffer)
            // Room for it always, so nothing moves when it arrives or changes.
            Text(measuredNote)
              .font(.caption).foregroundStyle(.secondary)
              .lineLimit(1, reservesSpace: true)
          }
          // Room for two lines always, so the sheet doesn't move when the note changes.
          Text(problem ?? "Tint and Brightness move the average to the original's; Saturation and Contrast move the range around it.")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(2, reservesSpace: true)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Capped, and centred under the pictures: sliders as wide as a large sheet are no
        // finer to set, only further to drag. A narrower sheet's fill it.
        .frame(maxWidth: Self.maxControlsWidth, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: controlsHeight)
      .layoutPriority(1)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Match") {
          create.matchColors(item, options: queuedOptions)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(problem != nil)
      }
    }
    .sheetPadding()
    .resizableSheetFrame(minWidth: 640, minHeight: 560, idealSize: CGSize(width: 1000, height: 800))
    // Once: the images don't change under the sheet.
    .task {
      preview = await create.colorMatchPreview(for: item) { original = $0 }
      loaded = true
    }
    // Again whenever a setting changes (or the preview arrives), away from the main actor; a
    // newer one cancels this one.
    .task(id: Rendering(options: options, ready: preview != nil)) {
      guard let preview, let image = try? await preview.rendering(options), !Task.isCancelled else { return }
      matched = image
    }
  }

  /// The name of a group of sliders, across the grid.
  private func heading(_ title: String) -> some View {
    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      .accessibilityAddTraits(.isHeader)
  }

  /// One amount's row: its name, its slider and its value.
  private func slider(_ title: String, _ amount: Binding<Double>, shown: Double) -> some View {
    GridRow {
      Text(title).gridColumnAlignment(.trailing)
      Slider(value: percentSteps(amount), in: 0...1)
        .accessibilityLabel(title)
      percent(shown)
    }
  }

  /// What the matched picture is drawn from: a change to either draws it again.
  private struct Rendering: Hashable {
    var options: ColorMatch.Options
    var ready: Bool
  }

  /// The most width the controls (the sliders, the toggle and the notes) take, however wide the
  /// sheet is.
  private static let maxControlsWidth: CGFloat = 460

  /// The least height the pictures (with their labels) keep when the sheet is short.
  private static let minPicturesHeight: CGFloat = 150

  /// The original as shown: at the preview's size once that's made, as read until then.
  private var shownOriginal: CGImage? { preview?.original ?? original }

  /// What stands in for the matched picture while there's none; nil when it's only being drawn.
  private var matchedNote: String? {
    if matched != nil { return nil }
    if !loaded { return "Reading the image and its original…" }
    return preview == nil ? "The image or its original couldn't be read." : nil
  }

  /// The two pictures, arranged as `compareMode` says, each arrangement with a row of labels
  /// under it so the pictures are the same height in both.
  @ViewBuilder private var pictures: some View {
    switch compareMode {
    case .sideBySide:
      HStack(alignment: .top, spacing: 12) {
        picture(shownOriginal, note: nil, title: "Original")
        picture(matched, note: matchedNote, title: "Matched")
      }
    case .slider:
      SliderComparison(
        matched: matched, original: shownOriginal, matchedNote: matchedNote,
        shape: preview.map { CGSize(width: $0.width, height: $0.height) })
    }
  }

  /// Static, as `note` is, so the Slider mode's view can use them too.
  private static func label(_ title: String) -> some View {
    Text(title).font(.caption).foregroundStyle(.secondary)
  }

  /// The text in a picture's place while it isn't there.
  private static func note(_ text: String?) -> some View {
    Text(text ?? "").font(.caption).foregroundStyle(.secondary)
      .multilineTextAlignment(.center).padding(8)
  }

  /// One of the two pictures in a box that takes the room it's given, which is there before the
  /// picture is, so nothing moves when it arrives.
  private func picture(_ image: CGImage?, note text: String?, title: String) -> some View {
    VStack(spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
        if let image {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            .clipShape(.rect(cornerRadius: 6))
        } else {
          Self.note(text)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement()
      .accessibilityLabel(title)
      Self.label(title)
    }
  }

  /// The Slider mode's picture: the match, with the original over it to the left of the divider.
  /// Both are laid in one rectangle of the edited image's shape, worked out here rather than
  /// left to each image's own fit, so they line up pixel for pixel whatever rounding either
  /// would do (and an original of another shape is fit inside the same rectangle). The labels
  /// sit under the picture's own corners, not the box's, so each is by the side it names.
  ///
  /// A view of its own, holding where the divider is, so that dragging it draws only this again
  /// and not the whole sheet with its sliders. The matched picture is the sheet's and comes in
  /// as it is: nothing here asks for it to be made again.
  private struct SliderComparison: View {
    let matched: CGImage?
    let original: CGImage?
    /// What stands in for the matched picture while there's none.
    let matchedNote: String?
    /// The edited image's size, once the preview has it; the original's shape stands in until then.
    let shape: CGSize?
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
            ColorMatchSheet.label("Original")
            Spacer()
            ColorMatchSheet.label("Matched")
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
          Image(matched, scale: 1, label: Text("Matched")).resizable().frame(width: size.width, height: size.height)
        } else {
          // In the half the match will show in.
          ColorMatchSheet.note(matchedNote)
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
            Image(original, scale: 1, label: Text("Original")).resizable().aspectRatio(contentMode: .fit)
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

  /// `amount` set in whole percents. The slider's own `step` would do it, but draws a tick mark
  /// for each of the hundred.
  private func percentSteps(_ amount: Binding<Double>) -> Binding<Double> {
    Binding(get: { amount.wrappedValue }, set: { amount.wrappedValue = ColorMatch.snapped($0) })
  }

  /// "100%", in a column wide enough for it, so the sliders don't change length.
  private func percent(_ amount: Double) -> some View {
    Text("\(Int((amount * 100).rounded()))%")
      .monospacedDigit()
      .frame(width: 44, alignment: .trailing)
  }
}
