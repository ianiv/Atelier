@preconcurrency import _MediaGenerationKit
import SwiftUI

struct SizeButton: View {
  let descriptor: SettingDescriptor
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager
  @State private var showing = false

  var body: some View {
    let size = model.settings.map { ($0.width, $0.height) } ?? (0, 0)
    Button {
      showing.toggle()
    } label: {
      HStack(spacing: 4) {
        Text(verbatim: "\(size.0) × \(size.1)").monospacedDigit()
        Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
      }
    }
    .debugPresents("sizePopover", $showing)
    .popover(isPresented: $showing, arrowEdge: inspectorPopoverEdge) {
      SizePopover(
        width: size.0, height: size.1, megapixels: SizePreset.megapixels(for: model.traits),
        maxSide: SizePreset.maxSide(for: model.traits),
        current: { model.settings.map { ($0.width, $0.height) } ?? size }
      ) { width, height in
        model.set(
          descriptor,
          to: .object(["width": .number(Double(width)), "height": .number(Double(height))]),
          undoManager: undoManager)
      }
    }
  }
}

struct SizePopover: View {
  let width: Int
  let height: Int
  /// The megapixel choices and the longest side the model takes.
  var megapixels: [Double] = SizePreset.megapixels
  var maxSide = SizePreset.maxSide
  /// The size as it is now, not as it was when this view last rendered: a field committing as the
  /// popover closes runs a closure from the last render, and pairing its side with a captured other
  /// side could undo the other field's commit made a moment before.
  let current: () -> (width: Int, height: Int)
  let set: (Int, Int) -> Void

  var body: some View {
    let match = SizePreset.match(width: width, height: height, megapixels: self.megapixels, maxSide: maxSide)
    let megapixels = match?.1 ?? closestMegapixels
    VStack(alignment: .leading, spacing: 12) {
      Text("Aspect Ratio").font(.headline)
      // An eager Grid, not a LazyVGrid: the popover takes its size from the first layout, and a
      // lazy grid could report it before all its rows existed, leaving the popover the wrong size.
      Grid(horizontalSpacing: 8, verticalSpacing: 8) {
        ForEach(Array(stride(from: 0, to: SizePreset.aspectRatios.count, by: 4)), id: \.self) { start in
          GridRow {
            ForEach(SizePreset.aspectRatios[start..<min(start + 4, SizePreset.aspectRatios.count)]) { aspect in
              aspectButton(aspect, selected: match?.0 == aspect, megapixels: megapixels)
            }
          }
        }
      }
      Text("Megapixels").font(.headline)
      Picker("Megapixels", selection: Binding(
        get: { match?.1 },
        set: { mp in
          guard let mp else { return }
          let size = SizePreset.size(aspect: match?.0 ?? closestAspect, megapixels: mp, maxSide: maxSide)
          set(size.width, size.height)
        })
      ) {
        // No "Custom" segment for other sizes: the Mac gives every segment the widest label's
        // width, and "Custom" made the picker wider than the popover. None is selected instead.
        ForEach(self.megapixels, id: \.self) { Text($0.formatted()).tag(Optional($0)) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      // One row on the Mac; iPad's wider steppers need a line each. Chosen per platform rather
      // than by ViewThatFits, whose measuring could size the popover for the other layout.
      #if os(macOS)
        HStack {
          dimension("W", value: width) { set($0, current().height) }
          swapButton
          dimension("H", value: height) { set(current().width, $0) }
        }
      #else
        HStack {
          VStack(alignment: .trailing) {
            dimension("W", value: width) { set($0, current().height) }
            dimension("H", value: height) { set(current().width, $0) }
          }
          swapButton
        }
      #endif
      Text("\((Double(width * height) / 1_048_576).formatted(.number.precision(.fractionLength(2)))) megapixels; sizes snap to 64 px.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 320)
    // The popover's size is the content's ideal size, never a squeezed one.
    .fixedSize()
  }

  private func aspectButton(_ aspect: SizePreset.AspectRatio, selected: Bool, megapixels: Double)
    -> some View
  {
    Button {
      let size = SizePreset.size(aspect: aspect, megapixels: megapixels, maxSide: maxSide)
      set(size.width, size.height)
    } label: {
      VStack(spacing: 4) {
        let scale = 28 / Double(max(aspect.width, aspect.height))
        RoundedRectangle(cornerRadius: 2)
          .strokeBorder(selected ? Color.accentColor : .secondary, lineWidth: selected ? 2 : 1)
          .frame(width: Double(aspect.width) * scale, height: Double(aspect.height) * scale)
          .frame(height: 30)
        Text(aspect.label).font(.caption).monospacedDigit()
      }
      .frame(width: 64, height: 52)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
  }

  private var swapButton: some View {
    Button {
      set(height, width)
    } label: {
      Image(systemName: "arrow.left.arrow.right")
    }
    .buttonStyle(.borderless)
    .help("Swap width and height")
    .accessibilityLabel("Swap width and height")
  }

  private func dimension(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
    SizeDimensionField(title: title, value: value, maxSide: maxSide, set: set)
  }

  private var closestMegapixels: Double {
    let mp = Double(width * height) / 1_048_576
    return megapixels.min { abs($0 - mp) < abs($1 - mp) } ?? 1
  }

  private var closestAspect: SizePreset.AspectRatio {
    let ratio = Double(width) / Double(max(height, 1))
    return SizePreset.aspectRatios.min {
      abs(Double($0.width) / Double($0.height) - ratio)
        < abs(Double($1.width) / Double($1.height) - ratio)
    } ?? SizePreset.aspectRatios[0]
  }
}

/// One side of the size, typed or stepped, snapped to a multiple of 64.
///
/// Typing edits a text draft that snaps only on Return, when the field loses focus, or when the
/// popover closes (so a value typed on iPad isn't lost): a value-formatted field commits on every
/// keystroke, so snapping there turned the "1" of "1024" into 64 before the rest could be typed,
/// and made an undo entry per keystroke. Same approach as `FramesControl`.
///
/// Only an edited draft commits. The aspect buttons, Megapixels and Swap change the size without
/// taking focus, so a focused but untouched draft would otherwise write the old size back over the
/// preset on Return or blur, and closing the popover would rewrite sizes nobody typed.
private struct SizeDimensionField: View {
  let title: String
  let value: Int
  let maxSide: Int
  let set: (Int) -> Void
  @State private var draft = ""
  /// The text the draft was last set to from `value`; a draft that differs was typed.
  @State private var synced = ""
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 4) {
      Text(title).foregroundStyle(.secondary)
      TextField(title, text: $draft)
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 60)
        .focused($focused)
        .onSubmit(commit)
        .onChange(of: focused) { _, isFocused in
          if !isFocused { commit() }
        }
        .onChange(of: value, initial: true) { _, newValue in
          // While focused, keep only what the user is typing; an untouched draft follows the size.
          if !focused || !edited { show(newValue) }
        }
        .onDisappear(perform: commit)
      Stepper(
        title,
        value: Binding(
          get: { value },
          set: {
            let snapped = SizePreset.snap(min(max($0, 64), maxSide))
            if snapped != value { set(snapped) }
            show(snapped)
          }
        ), in: 64...maxSide, step: 64
      ).labelsHidden()
    }
  }

  /// Snaps the typed size to a multiple of 64 within range and shows it; text that isn't a
  /// number reverts. Setting only when the size changes keeps a no-op commit out of undo.
  private func commit() {
    guard edited else { return }
    if let typed = Int(draft.trimmingCharacters(in: .whitespaces)) {
      let snapped = SizePreset.snap(min(max(typed, 64), maxSide))
      if snapped != value { set(snapped) }
      show(snapped)
    } else {
      show(value)
    }
  }

  private var edited: Bool { draft != synced }

  private func show(_ size: Int) {
    draft = String(size)
    synced = draft
  }
}
