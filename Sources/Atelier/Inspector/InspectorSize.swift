import SwiftUI
import _MediaGenerationKit

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
        Image(systemName: "chevron.down").font(.caption2)
      }
    }
    .popover(isPresented: $showing, arrowEdge: .leading) {
      SizePopover(width: size.0, height: size.1) { width, height in
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
  let set: (Int, Int) -> Void

  var body: some View {
    let match = SizePreset.match(width: width, height: height)
    let megapixels = match?.1 ?? closestMegapixels
    VStack(alignment: .leading, spacing: 12) {
      Text("Aspect Ratio").font(.headline)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 4), spacing: 8) {
        ForEach(SizePreset.aspectRatios) { aspect in
          let selected = match?.0 == aspect
          Button {
            let size = SizePreset.size(aspect: aspect, megapixels: megapixels)
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
      }
      Text("Megapixels").font(.headline)
      Picker("Megapixels", selection: Binding(
        get: { match?.1 },
        set: { mp in
          guard let mp else { return }
          let size = SizePreset.size(aspect: match?.0 ?? closestAspect, megapixels: mp)
          set(size.width, size.height)
        })
      ) {
        if match == nil { Text("Custom").tag(Double?.none) }
        ForEach(SizePreset.megapixels, id: \.self) { Text($0.formatted()).tag(Optional($0)) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      HStack {
        dimension("W", value: width) { set($0, height) }
        Button {
          set(height, width)
        } label: {
          Image(systemName: "arrow.left.arrow.right")
        }
        .buttonStyle(.borderless)
        .help("Swap width and height")
        dimension("H", value: height) { set(width, $0) }
      }
      Text("\((Double(width * height) / 1_048_576).formatted(.number.precision(.fractionLength(2)))) megapixels; sizes snap to 64 px.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 320)
  }

  private func dimension(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
    let binding = Binding(get: { value }, set: { set(SizePreset.snap(min(max($0, 64), 4096))) })
    return HStack(spacing: 4) {
      Text(title).foregroundStyle(.secondary)
      TextField(title, value: binding, format: .number.grouping(.never))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 60)
      Stepper(title, value: binding, in: 64...4096, step: 64).labelsHidden()
    }
  }

  private var closestMegapixels: Double {
    let mp = Double(width * height) / 1_048_576
    return SizePreset.megapixels.min { abs($0 - mp) < abs($1 - mp) } ?? 1
  }

  private var closestAspect: SizePreset.AspectRatio {
    let ratio = Double(width) / Double(max(height, 1))
    return SizePreset.aspectRatios.min {
      abs(Double($0.width) / Double($0.height) - ratio)
        < abs(Double($1.width) / Double($1.height) - ratio)
    } ?? SizePreset.aspectRatios[0]
  }
}
