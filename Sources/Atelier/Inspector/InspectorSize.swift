@preconcurrency import _MediaGenerationKit
import SwiftUI

struct SizeButton: View {
  let descriptor: SettingDescriptor
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager
  @State private var showing = false
  /// The aspect lock is a preference of this device, not a setting: presets, projects and other
  /// devices never carry it.
  @AppStorage("sizeAspectLocked") private var aspectLocked = false
  /// The locked ratio, kept here so it outlives the popover; see `SizePopover.lockedRatio`.
  @State private var lockedRatio: Double?

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
        current: { model.settings.map { ($0.width, $0.height) } ?? size },
        locked: $aspectLocked, lockedRatio: $lockedRatio
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
  /// Whether changing one side changes the other to keep `lockedRatio`.
  @Binding var locked: Bool
  /// Width / height while locked. Stored rather than worked out from the size each time, since
  /// each side is snapped to 64 and a ratio taken from snapped sides would drift commit by commit.
  ///
  /// It's checked against the size only when the popover appears: a size changed from outside
  /// while the popover is open (an agent, a model switch) keeps the old ratio until it's reopened.
  @Binding var lockedRatio: Double?
  /// Sets both sides at once, so a locked change is one undo step.
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
          // The locked ratio, not the nearest preset's, within the model's longest side.
          let size = if locked, let ratio {
            SizePreset.locked(ratio: ratio, megapixels: mp, maxSide: maxSide)
          } else {
            SizePreset.size(aspect: match?.0 ?? closestAspect, megapixels: mp, maxSide: maxSide)
          }
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
          dimension("W", value: width, current: { current().width }, set: setWidth)
          swapButton
          dimension("H", value: height, current: { current().height }, set: setHeight)
          lockButton
        }
      #else
        HStack {
          VStack(alignment: .trailing) {
            dimension("W", value: width, current: { current().width }, set: setWidth)
            dimension("H", value: height, current: { current().height }, set: setHeight)
          }
          // Lock beneath swap, level with the H row.
          VStack {
            swapButton
            lockButton
          }
        }
      #endif
      Text("\((Double(width * height) / 1_048_576).formatted(.number.precision(.fractionLength(2)))) megapixels; sizes snap to 64 px.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 320)
    // The popover's size is the content's ideal size, never a squeezed one.
    .fixedSize()
    .onAppear {
      // Keep the stored ratio only if it still describes the size; a size changed while the
      // popover was closed is locked at its own ratio.
      guard locked else { return }
      if let lockedRatio,
         SizePreset.fits(width: width, height: height, ratio: lockedRatio, megapixels: self.megapixels, maxSide: maxSide)
      { return }
      // Nil when the size has no usable ratio; the lock then acts unlocked until one is set.
      lockedRatio = SizePreset.lockRatio(width: width, height: height, megapixels: self.megapixels, maxSide: maxSide)
    }
  }

  /// The ratio a locked change keeps, or nil when there's none to keep (a zero side), in which
  /// case a locked change acts as an unlocked one.
  private var ratio: Double? {
    SizePreset.validRatio(lockedRatio)
      ?? SizePreset.lockRatio(width: width, height: height, megapixels: megapixels, maxSide: maxSide)
  }

  /// Sets a typed width, and the height too while locked; returns the width actually set, which
  /// the lock can hold below the typed one so the height stays within the model's limits.
  private func setWidth(_ width: Int) -> Int {
    let size: (width: Int, height: Int) = if locked, let ratio {
      SizePreset.locked(width: width, ratio: ratio, maxSide: maxSide)
    } else {
      (width, current().height)
    }
    apply(size)
    return size.width
  }

  private func setHeight(_ height: Int) -> Int {
    let size: (width: Int, height: Int) = if locked, let ratio {
      SizePreset.locked(height: height, ratio: ratio, maxSide: maxSide)
    } else {
      (current().width, height)
    }
    apply(size)
    return size.height
  }

  /// Sets the size unless it's already that, keeping a no-op out of undo.
  private func apply(_ size: (width: Int, height: Int)) {
    if size != current() { set(size.width, size.height) }
  }

  private func aspectButton(_ aspect: SizePreset.AspectRatio, selected: Bool, megapixels: Double)
    -> some View
  {
    Button {
      let size = SizePreset.size(aspect: aspect, megapixels: megapixels, maxSide: maxSide)
      set(size.width, size.height)
      if locked { lockedRatio = aspect.ratio }
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
      let ratio = ratio
      set(height, width)
      if locked { lockedRatio = ratio.map { 1 / $0 } }
    } label: {
      Image(systemName: "arrow.left.arrow.right")
    }
    .buttonStyle(.borderless)
    .help("Swap width and height")
    .accessibilityLabel("Swap width and height")
  }

  private var lockButton: some View {
    Button {
      locked.toggle()
      lockedRatio = locked
        ? SizePreset.lockRatio(width: width, height: height, megapixels: megapixels, maxSide: maxSide) : nil
    } label: {
      // The open lock is wider; reserving its width keeps the row from shifting on toggle.
      ZStack {
        Image(systemName: "lock.open").hidden()
        if locked {
          Image(systemName: "lock")
        } else {
          Image(systemName: "lock.open").foregroundStyle(.secondary)
        }
      }
    }
    .buttonStyle(.borderless)
    .help(locked ? "Unlock Aspect Ratio" : "Lock Aspect Ratio")
    .accessibilityLabel(locked ? "Unlock Aspect Ratio" : "Lock Aspect Ratio")
    .accessibilityAddTraits(locked ? .isSelected : [])
  }

  private func dimension(
    _ title: String, value: Int, current: @escaping () -> Int, set: @escaping (Int) -> Int
  ) -> some View {
    SizeDimensionField(title: title, value: value, maxSide: maxSide, current: current, set: set)
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
/// Only a draft that differs from the size commits. The aspect buttons, Megapixels and Swap change
/// the size without taking focus, and an untouched focused draft follows them, so it never writes
/// the old size back over the preset on Return or blur, and closing the popover rewrites nothing
/// nobody typed. A typed draft is compared with the live size, not the text it last showed: typed
/// back to that text after a preset changed the size, it's still a size to set.
private struct SizeDimensionField: View {
  let title: String
  let value: Int
  let maxSide: Int
  /// This side as it is now. Closing the popover with a typed draft commits twice (focus loss,
  /// then disappearing), both from the last render, so the second compares with `value` from
  /// before the first commit; compared with the live side instead, it finds nothing to set.
  let current: () -> Int
  /// Sets this side and returns what it became, which the aspect lock can make differ from the
  /// value given. The draft shows that: Return keeps focus, so the value-change sync wouldn't.
  let set: (Int) -> Int
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
            show(snapped != value ? set(snapped) : snapped)
          }
        ), in: 64...maxSide, step: 64
      ).labelsHidden()
    }
  }

  /// Snaps the typed size to a multiple of 64 within range and shows it; text that isn't a
  /// number reverts. Setting only when the size changes keeps a no-op commit out of undo.
  private func commit() {
    let value = current()
    let text = draft.trimmingCharacters(in: .whitespaces)
    guard text != String(value) else {
      show(value)
      return
    }
    if let typed = Int(text) {
      let snapped = SizePreset.snap(min(max(typed, 64), maxSide))
      show(snapped != value ? set(snapped) : snapped)
    } else {
      show(value)
    }
  }

  /// Whether the draft was typed in since it last showed the size; only the value-change sync uses
  /// this, to keep what's being typed. A commit compares with the live size instead.
  private var edited: Bool { draft != synced }

  private func show(_ size: Int) {
    draft = String(size)
    synced = draft
  }
}
