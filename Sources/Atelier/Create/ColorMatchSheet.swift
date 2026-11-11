import SwiftUI

/// Match Colors… on the canvas image: Match Colors to Original with how far the colors and the
/// light move chosen, and whether to measure only what the edit left alone, beside a preview of
/// what they make; then queue it. The result is a new image in History after the edited one, as
/// the one-click item's is.
///
/// The preview is the edited image at a small size, matched with the statistics of the full
/// images (`ColorMatch.Preview`), so it shows what the job will make.
struct ColorMatchSheet: View {
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
    case .mostlyChanged(let fraction) where unchangedOnly:
      return "Only \(percent(fraction))% of the image is unchanged, so the whole image is measured."
    case .changedTogether where unchangedOnly:
      return "Most of the image changed, so the whole image is measured."
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
      HStack(alignment: .top, spacing: 12) {
        picture(preview?.original ?? original, title: "Original")
        picture(matched, title: "Matched")
      }
      // Scrolls when the window is too short for all of it (a small iPad window); the pictures
      // and the buttons stay put.
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
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
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
    .sheetFrame(width: 560, height: 550)
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

  /// One of the two pictures in a box of a fixed height, which is there before the picture is, so
  /// nothing moves when it arrives.
  private func picture(_ image: CGImage?, title: String) -> some View {
    VStack(spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
        if let image {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            .clipShape(.rect(cornerRadius: 6))
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 190)
      .accessibilityElement()
      .accessibilityLabel(title)
      Text(title).font(.caption).foregroundStyle(.secondary)
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
