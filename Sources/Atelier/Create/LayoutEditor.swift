import SwiftUI

/// The boxes of the open layout, drawn over the canvas frame. Dragging on an empty spot draws a
/// box; a box drags to move, and the picked one has corner handles to resize it. Drags outside
/// the frame still pan the image underneath.
struct LayoutCanvas: View {
  @Environment(CreateModel.self) private var model
  /// The frame's size in points.
  let size: CGSize
  /// The box being drawn, in the unit square.
  @State private var drawing: CGRect?
  /// The box being moved or resized, and its rect when that began.
  @State private var editing: (id: UUID, rect: CGRect)?

  var body: some View {
    if let layout = model.layout {
      ZStack(alignment: .topLeading) {
        Color.black.opacity(model.image == nil ? 0 : 0.25)
          .contentShape(.rect)
          .gesture(drawGesture)
          .onTapGesture { model.selectedLayoutItem = nil }
        ForEach(Array(layout.items.enumerated()), id: \.element.id) { index, item in
          box(item, index: index)
        }
        if let drawing {
          Rectangle()
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .frame(width: drawing.width * size.width, height: drawing.height * size.height)
            .offset(x: drawing.minX * size.width, y: drawing.minY * size.height)
            .allowsHitTesting(false)
        }
        if layout.items.isEmpty, drawing == nil {
          Label("Drag to draw a box", systemImage: "rectangle.dashed")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: .capsule)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        }
      }
      .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
  }

  private func box(_ item: LayoutPrompt.Item, index: Int) -> some View {
    let color = LayoutPanel.color(index)
    let selected = model.selectedLayoutItem == item.id
    let rect = item.rect
    return Rectangle()
      .fill(color.opacity(selected ? 0.22 : 0.12))
      .strokeBorder(color, lineWidth: selected ? 2.5 : 1.5)
      .overlay(alignment: .topLeading) {
        Text(verbatim: LayoutPanel.title(item, index: index))
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(color, in: .rect(bottomTrailingRadius: 4))
          .frame(maxWidth: rect.width * size.width, alignment: .leading)
          .allowsHitTesting(false)
      }
      .contentShape(.rect)
      .frame(width: rect.width * size.width, height: rect.height * size.height)
      .gesture(moveGesture(item))
      .onTapGesture { select(item) }
      .contextMenu {
        Button("Delete Box", systemImage: "trash", role: .destructive) { delete(item.id) }
      }
      .overlay {
        if selected { handles(item) }
      }
      .offset(x: rect.minX * size.width, y: rect.minY * size.height)
  }

  /// Corner handles that resize `item` with the opposite corner fixed.
  private func handles(_ item: LayoutPrompt.Item) -> some View {
    let width = item.rect.width * size.width
    let height = item.rect.height * size.height
    return ForEach(0..<4, id: \.self) { corner in
      let right = corner % 2 == 1
      let bottom = corner >= 2
      Circle()
        .fill(.white)
        .stroke(Color.accentColor, lineWidth: 1.5)
        .frame(width: 10, height: 10)
        .padding(6)
        .contentShape(.rect)
        .position(x: right ? width : 0, y: bottom ? height : 0)
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              let start = startEditing(item)
              let fixed = CGPoint(x: right ? start.minX : start.maxX, y: bottom ? start.minY : start.maxY)
              let moved = Self.clamp(
                CGPoint(
                  x: (right ? start.maxX : start.minX) + value.translation.width / size.width,
                  y: (bottom ? start.maxY : start.minY) + value.translation.height / size.height))
              update(item.id) { $0.rect = Self.rect(fixed, moved, minimum: 0.02) }
            }
            .onEnded { _ in editing = nil })
    }
  }

  private var drawGesture: some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { value in
        drawing = Self.rect(unit(value.startLocation), unit(value.location), minimum: 0)
      }
      .onEnded { _ in
        defer { drawing = nil }
        guard let drawing, drawing.width > 0.02, drawing.height > 0.02, var layout = model.layout,
              let format = model.layoutFormat
        else { return }
        let kind = format.kinds[0]
        let item = LayoutPrompt.Item(name: layout.newName(for: kind), kind: kind, rect: drawing)
        layout.items.append(item)
        model.layout = layout
        select(item)
      }
  }

  private func moveGesture(_ item: LayoutPrompt.Item) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        let start = startEditing(item)
        if model.selectedLayoutItem != item.id { select(item) }
        var rect = start.offsetBy(
          dx: value.translation.width / size.width, dy: value.translation.height / size.height)
        // Keep the whole box inside the frame.
        rect.origin.x = min(max(rect.minX, 0), 1 - rect.width)
        rect.origin.y = min(max(rect.minY, 0), 1 - rect.height)
        update(item.id) { $0.rect = rect }
      }
      .onEnded { _ in editing = nil }
  }

  /// The rect `item` had when the current drag began.
  private func startEditing(_ item: LayoutPrompt.Item) -> CGRect {
    if let editing, editing.id == item.id { return editing.rect }
    editing = (item.id, item.rect)
    return item.rect
  }

  private func select(_ item: LayoutPrompt.Item) {
    model.selectedLayoutItem = item.id
  }

  private func update(_ id: UUID, _ change: (inout LayoutPrompt.Item) -> Void) {
    guard let index = model.layout?.items.firstIndex(where: { $0.id == id }) else { return }
    change(&model.layout!.items[index])
  }

  private func delete(_ id: UUID) {
    model.layout?.items.removeAll { $0.id == id }
    if model.selectedLayoutItem == id { model.selectedLayoutItem = nil }
  }

  private func unit(_ point: CGPoint) -> CGPoint {
    Self.clamp(CGPoint(x: point.x / size.width, y: point.y / size.height))
  }

  private static func clamp(_ point: CGPoint) -> CGPoint {
    CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
  }

  /// The rect spanning two corners, at least `minimum` on each side.
  private static func rect(_ a: CGPoint, _ b: CGPoint, minimum: Double) -> CGRect {
    var rect = CGRect(
      x: min(a.x, b.x), y: min(a.y, b.y), width: max(abs(a.x - b.x), minimum),
      height: max(abs(a.y - b.y), minimum))
    rect.origin.x = min(rect.minX, 1 - rect.width)
    rect.origin.y = min(rect.minY, 1 - rect.height)
    return rect
  }
}

/// The open layout's caption and boxes, beside the canvas.
struct LayoutPanel: View {
  @Environment(CreateModel.self) private var model

  private static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red]

  static func color(_ index: Int) -> Color { colors[index % colors.count] }

  /// The box's label on the canvas: its number and id, or what it holds.
  static func title(_ item: LayoutPrompt.Item, index: Int) -> String {
    let words = item.kind == .text && !item.text.isEmpty ? "“\(item.text)”" : item.description
    return "\(index + 1)  " + (words.isEmpty ? item.name : words)
  }

  var body: some View {
    if let format = model.layoutFormat, model.layout != nil {
      let layout = Binding(get: { model.layout ?? LayoutPrompt() }, set: { model.layout = $0 })
      VStack(spacing: 0) {
        HStack {
          Text("Layout").font(.headline)
          Spacer()
          Button("Add Box", systemImage: "plus") { model.addLayoutItem() }
            .labelStyle(.iconOnly)
            .help("Add a box in the middle of the frame. You can also drag on an empty spot of the canvas.")
          Button("Done") { model.closeLayout() }
            .help("Close the layout. The prompt keeps it; open Layout again to change the boxes.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
              Text("Caption").font(.subheadline.weight(.semibold))
              TextField("The whole image: medium, setting, light…", text: layout.caption, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.roundedBorder)
              if format.citesIDs {
                Text("Cite a box where it belongs in the caption, such as <object_1>.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            if format.hasBackground {
              VStack(alignment: .leading, spacing: 6) {
                Text("Background").font(.subheadline.weight(.semibold))
                TextField("What's behind everything", text: layout.background, axis: .vertical)
                  .lineLimit(1...5)
                  .textFieldStyle(.roundedBorder)
              }
            }
            VStack(alignment: .leading, spacing: 8) {
              Text("Boxes").font(.subheadline.weight(.semibold))
              if layout.wrappedValue.items.isEmpty {
                Text("Drag on the canvas to draw a box, or click +. Then say what goes in it.")
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
              ForEach(Array(layout.items.enumerated()), id: \.element.id) { index, item in
                LayoutItemRow(item: item, index: index, format: format, caption: layout.caption)
              }
            }
          }
          .padding(14)
        }
      }
      .frame(width: 300)
      .background(.background)
    }
  }
}

/// One box in the layout list.
private struct LayoutItemRow: View {
  @Environment(CreateModel.self) private var model
  @Binding var item: LayoutPrompt.Item
  let index: Int
  let format: LayoutPrompt.Format
  @Binding var caption: String

  var body: some View {
    let selected = model.selectedLayoutItem == item.id
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(verbatim: "\(index + 1)")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white)
          .frame(width: 20, height: 20)
          .background(LayoutPanel.color(index), in: .rect(cornerRadius: 4))
        Picker("Kind", selection: $item.kind) {
          ForEach(format.kinds, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        Spacer()
        if format.citesIDs {
          Button("Cite in Caption", systemImage: "text.insert") {
            caption += (caption.isEmpty || caption.hasSuffix(" ") ? "" : " ") + "<\(item.name)>"
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Add <\(item.name)> to the end of the caption")
        }
        Button("Delete Box", systemImage: "trash") {
          model.layout?.items.removeAll { $0.id == item.id }
          if selected { model.selectedLayoutItem = nil }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Delete this box")
      }
      if format.citesIDs {
        TextField("ID", text: $item.name)
          .textFieldStyle(.roundedBorder)
          .font(.callout.monospaced())
          .help("The id the caption cites this box by, as <id>")
      }
      if item.kind == .text {
        TextField("The exact words", text: $item.text, axis: .vertical)
          .lineLimit(1...4)
          .textFieldStyle(.roundedBorder)
      }
      TextField(
        item.kind == .text ? "Lettering: typeface, color, surface" : "What's in this box",
        text: $item.description, axis: .vertical
      )
      .lineLimit(1...6)
      .textFieldStyle(.roundedBorder)
    }
    .padding(8)
    .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.separator)
    )
    .contentShape(.rect)
    .onTapGesture { model.selectedLayoutItem = item.id }
  }
}
