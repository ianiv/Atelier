import SwiftUI

/// Match Colors… on the canvas image: Match Colors to Original with its strength and how much of
/// the lightness to match chosen, beside a preview of what they make, then queue it. The result is
/// a new image in History after the edited one, as the one-click item's is.
///
/// The preview is the edited image at a small size, matched with the statistics of the full
/// images (`ColorMatch.Preview`), so it shows what the job will make.
struct ColorMatchSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  /// The step it was opened for, kept here: the canvas can change while the sheet is open.
  let item: HistoryItem
  /// Last used, as fractions from 0 to 1. The one-click menu item doesn't read them.
  @AppStorage("colorMatchStrength") private var strength = 1.0
  @AppStorage("colorMatchLightness") private var lightness = 0.0
  @State private var preview: ColorMatch.Preview?
  /// The preview has been asked for and came back, with or without one.
  @State private var loaded = false
  @State private var matched: CGImage?

  private var options: ColorMatch.Options {
    ColorMatch.Options(strength: strength, luminance: lightness).snapped
  }

  /// Why Match can't be pressed, if it can't.
  private var problem: String? {
    if !loaded { return "Reading the image and its original…" }
    if preview == nil { return "The image or its original couldn't be read." }
    // Another project was opened under the sheet: the match would be queued for the wrong one.
    if create.history.item(tensorId: item.tensorId) == nil { return "That image isn't in the open project any more." }
    if create.pendingColorMatch(for: item, options: options) != nil {
      return "A match with these settings is already waiting or running for this image."
    }
    return nil
  }

  var body: some View {
    let options = self.options
    let problem = self.problem
    VStack(alignment: .leading, spacing: 14) {
      Text("Match Colors").font(.headline)
      HStack(alignment: .top, spacing: 12) {
        picture(preview?.original, title: "Original")
        picture(matched, title: "Matched")
      }
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Strength").gridColumnAlignment(.trailing)
          Slider(value: percentSteps($strength), in: 0...1)
            .accessibilityLabel("Strength")
          percent(options.strength)
        }
        GridRow {
          Text("Lightness")
          Slider(value: percentSteps($lightness), in: 0...1)
            .accessibilityLabel("Lightness")
          percent(options.luminance)
        }
      }
      // Room for two lines always, so the sheet doesn't move when the note changes.
      Text(problem ?? "Strength is how far the colors move to the original's. Lightness is how much of its brightness is matched too.")
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Match") {
          create.matchColors(item, options: options)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(problem != nil)
      }
    }
    .sheetPadding()
    .sheetFrame(width: 560, height: 440)
    // Once: the images don't change under the sheet.
    .task {
      preview = await create.colorMatchPreview(for: item)
      loaded = true
    }
    // Again whenever a slider moves (or the preview arrives), away from the main actor; a newer
    // one cancels this one.
    .task(id: Rendering(options: options, ready: preview != nil)) {
      guard let preview, let image = try? await preview.rendering(options), !Task.isCancelled else { return }
      matched = image
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
      .frame(height: 230)
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
