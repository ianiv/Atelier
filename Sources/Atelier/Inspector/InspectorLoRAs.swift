@preconcurrency import _MediaGenerationKit
import SwiftUI

struct LoRAEditor: View {
  let descriptor: SettingDescriptor
  @Environment(CreateModel.self) private var model
  @Environment(ModelLibrary.self) private var library
  @Environment(\.undoManager) private var undoManager
  @State private var picking = false
  /// Index of the entry whose LoRA is being changed; its picker popover is open.
  @State private var replacing: Int?

  nonisolated struct Item: Hashable {
    var file: String
    var weight: Double
    var mode: JSONValue
  }

  /// The list after swapping the LoRA at `index` for `newFile`. The entry keeps its place and mode.
  /// Its weight moves to the new LoRA's default only if it still sits at the old LoRA's default
  /// (the user never changed it); a weight the user chose carries over. Picking the same file, or
  /// an index that isn't there, leaves the list as it was.
  nonisolated static func replacing(
    _ items: [Item], at index: Int, with newFile: String, newDefault: Double, oldDefault: Double
  ) -> [Item] {
    guard items.indices.contains(index), items[index].file != newFile else { return items }
    var items = items
    // Weights are stored rounded to 0.01 by the slider, so compare with that tolerance.
    if abs(items[index].weight - oldDefault) < 0.005 { items[index].weight = newDefault }
    items[index].file = newFile
    return items
  }

  /// The setting's value for a list of entries; what `write` stores.
  nonisolated static func json(_ items: [Item]) -> JSONValue {
    .array(items.map {
      .object(["file": .string($0.file), "weight": .number($0.weight), "mode": $0.mode])
    })
  }

  /// What the replace picker offers: LoRAs other entries already use are hidden, the entry's own
  /// stays (the picker marks it). Add LoRA… doesn't filter, since it still allows duplicates.
  nonisolated static func filteredForReplacing<T>(
    _ catalog: [T], file: (T) -> String, items: [Item], at index: Int
  ) -> [T] {
    let others = Set(items.enumerated().filter { $0.offset != index }.map(\.element.file))
    return catalog.filter { !others.contains(file($0)) }
  }

  private var items: [Item] {
    guard case .array(let entries)? = model.value(descriptor) else { return [] }
    return entries.compactMap { entry in
      guard case .object(let fields) = entry, case .string(let file)? = fields["file"] else {
        return nil
      }
      return Item(
        file: file, weight: fields["weight"]?.doubleValue ?? 1,
        mode: fields["mode"] ?? .string("all"))
    }
  }

  /// LoRA families the engine applies with the selected model (and refiner); it skips others.
  private var compatibleFamilies: Set<String> {
    let refiner = model.settings?.refinerModel.flatMap { file in
      model.availableModels.first { $0.file == file }?.version
    }
    return ModelLibrary.loraFamilies(forModel: model.selectedModelInfo?.version, refiner: refiner)
  }

  private func write(_ items: [Item], undo: Bool = true) {
    model.set(descriptor, to: Self.json(items), undoManager: undo ? undoManager : nil)
  }

  var body: some View {
    let items = items
    let compatible = compatibleFamilies
    let triggerSources = model.screenTriggerWordSources
    let prompt = model.styledPrompts.prompt
    VStack(alignment: .leading, spacing: 6) {
      if items.isEmpty {
        Text("No LoRAs").foregroundStyle(.secondary)
      }
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        let range = weightRange(item)
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Button {
              replacing = index
            } label: {
              // The chevron is the pop-up menu indicator: it says the name opens a list. It sits
              // outside the Text so the name's middle truncation never cuts it off.
              HStack(spacing: 4) {
                Text(name(item.file)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                  .font(.caption2).foregroundStyle(.secondary)
                  .accessibilityHidden(true)
              }
              .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .help("Change LoRA (\(item.file))")
            .accessibilityLabel("Change LoRA: \(name(item.file))")
            .popover(
              isPresented: Binding(
                get: { replacing == index },
                set: { if !$0, replacing == index { replacing = nil } }),
              arrowEdge: inspectorPopoverEdge
            ) {
              let downloaded = model.availableLoRAs(in: library).filter(\.isDownloaded)
              let offered = Self.filteredForReplacing(downloaded, file: \.file, items: items, at: index)
              LoRAPicker(
                catalog: offered,
                compatible: compatible, modelFamily: model.selectedModelInfo?.version,
                current: item.file, allUsed: offered.isEmpty && !downloaded.isEmpty
              ) { lora in
                // A server's catalog may not list the file; this Mac's library might.
                let old = model.availableLoRAs(in: library).first { $0.file == item.file }?.defaultWeight
                  ?? library.loras.first { $0.file == item.file }?.defaultWeight ?? 1
                write(Self.replacing(
                  items, at: index, with: lora.file, newDefault: lora.defaultWeight, oldDefault: old))
                replacing = nil
              }
            }
            if let lora = model.availableLoRAs(in: library).first(where: { $0.file == item.file }),
               !compatible.contains(lora.family)
            {
              Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                .help("Made for \(lora.family), so it's skipped with this model.")
                .accessibilityLabel("Made for \(lora.family), so it's skipped with this model.")
            }
            Spacer()
            Button {
              var items = items
              items.remove(at: index)
              write(items)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this LoRA")
            .accessibilityLabel("Remove this LoRA")
          }
          HStack(spacing: 6) {
            Slider(
              value: Binding(
                get: { item.weight },
                set: { weight in
                  var items = items
                  items[index].weight = (weight * 100).rounded() / 100
                  write(items)
                }), in: range
            ) { editing in
              if editing {
                model.beginCoalescedEdit(descriptor, undoManager: undoManager)
              } else {
                model.endCoalescedEdit()
              }
            }
            TextField(
              "", value: Binding(
                get: { item.weight },
                set: { weight in
                  var items = items
                  items[index].weight = weight
                  write(items)
                }), format: .number.precision(.fractionLength(0...2))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
          }
          if let source = triggerSources.first(where: { $0.file == item.file }) {
            TriggerWordChips(source: source, prompt: prompt)
          }
        }
      }
      Button("Add LoRA…", systemImage: "plus") { picking = true }
        .buttonStyle(.borderless)
        .debugPresents("loraPicker", $picking)
        .popover(isPresented: $picking, arrowEdge: inspectorPopoverEdge) {
          LoRAPicker(
            catalog: model.availableLoRAs(in: library).filter(\.isDownloaded), compatible: compatible,
            modelFamily: model.selectedModelInfo?.version
          ) { lora in
            write(items + [Item(file: lora.file, weight: lora.defaultWeight, mode: .string("all"))])
            picking = false
          }
        }
    }
    .onChange(of: items) { replacing = nil }
    .task { await library.reloadLoRAsIfRegistriesChanged() }
  }

  /// The slider range custom_lora.json gives the LoRA, widened to take a weight typed or loaded
  /// outside it, so the slider doesn't pin it to an end.
  private func weightRange(_ item: Item) -> ClosedRange<Double> {
    let range = model.availableLoRAs(in: library).first { $0.file == item.file }?.weightRange
      ?? ModelLibrary.Weight.defaultRange
    guard item.weight.isFinite else { return range }
    return min(range.lowerBound, item.weight)...max(range.upperBound, item.weight)
  }

  private func name(_ file: String) -> String {
    model.availableLoRAs(in: library).first { $0.file == file }?.name ?? file
  }
}

/// A LoRA's trigger words under its row, each a toggle: the ones on go in front of the prompt a run
/// sends (`CreateModel.generationPrompts`). Disabled where they wouldn't be added: a JSON prompt,
/// which text in front would break, or a LoRA the engine skips with this model (its row says so).
struct TriggerWordChips: View {
  let source: TriggerWords.Source
  /// The styled prompt, before any words go in.
  let prompt: String
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    let json = TriggerWords.isJSON(prompt, format: model.layoutFormat)
    VStack(alignment: .leading, spacing: 2) {
      ChipFlow(spacing: 4) {
        ForEach(source.words, id: \.self) { word in
          let on = model.isTriggerWordOn(word, of: source.file)
          Toggle(
            isOn: Binding(
              get: { on },
              set: { model.setTriggerWord(word, of: source.file, on: $0, undoManager: undoManager) })
          ) {
            // The checkmark or plus says it's a switch, and which way it's set, beyond the tint.
            Label(word, systemImage: on ? "checkmark" : "plus")
          }
          .toggleStyle(.button)
          .labelStyle(.titleAndIcon)
          .controlSize(.small)
          .help(help(word, on: on))
          .accessibilityLabel("Trigger word \(word)")
        }
      }
      .disabled(json || !source.applies)
      if json {
        Text("Not added to a JSON prompt; put them in the caption.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func help(_ word: String, on: Bool) -> String {
    if !on { return "Off: “\(word)” isn't added to the prompt. Click to add it." }
    if TriggerWords.contains(prompt, word: word) { return "On, but the prompt already has “\(word)”, so it isn't added again." }
    return "On: “\(word)” goes in front of the prompt. Click to leave it out."
  }
}

/// Lays chips out in rows, wrapping to the width it's given.
struct ChipFlow: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
    let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
    var y = bounds.minY
    for row in rows(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var row = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if !row.indices.isEmpty, row.width + spacing + size.width > width {
        rows.append(row)
        row = Row()
      }
      row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
      row.height = max(row.height, size.height)
      row.indices.append(index)
    }
    if !row.indices.isEmpty { rows.append(row) }
    return rows
  }
}

/// Searchable list of downloaded LoRAs made for the selected model's family.
struct LoRAPicker: View {
  let catalog: [ModelLibrary.LoRA]
  let compatible: Set<String>
  let modelFamily: String?
  /// File of the LoRA being replaced, marked with a checkmark; nil when adding.
  var current: String?
  /// Every downloaded LoRA is already used by another entry (replace picker only).
  var allUsed = false
  let pick: (ModelLibrary.LoRA) -> Void
  @State private var query = ""
  @AppStorage("loraPickerShowAll") private var showAll = false

  var body: some View {
    let matching = query.isEmpty
      ? catalog
      : catalog.filter {
        $0.name.localizedCaseInsensitiveContains(query)
          || $0.file.localizedCaseInsensitiveContains(query)
          || $0.prefix.localizedCaseInsensitiveContains(query)
      }
    let fitting = matching.filter { compatible.contains($0.family) }
    let others = matching.filter { !compatible.contains($0.family) }
    VStack(spacing: 0) {
      SearchField(text: $query, prompt: "Search LoRAs").padding(8)
      Divider()
      if allUsed {
        Text("All downloaded LoRAs are already in the list.")
          .foregroundStyle(.secondary).padding()
      } else if catalog.isEmpty {
        Text("No LoRAs yet. Import them in the LoRAs section.")
          .foregroundStyle(.secondary).padding()
      } else if fitting.isEmpty, !showAll {
        Text("No LoRAs for \(modelFamily ?? "this model")\(query.isEmpty ? "" : " match").")
          .foregroundStyle(.secondary).padding()
      }
      List {
        ForEach(fitting) { lora in row(lora, enabled: true) }
        if showAll, !others.isEmpty {
          Section("For other models (skipped with this one)") {
            ForEach(others) { lora in row(lora, enabled: false) }
          }
        }
      }
      .listStyle(.plain)
      Divider()
      HStack {
        Toggle("Show LoRAs for other models", isOn: $showAll)
          .controlSize(.small)
        Spacer()
        if !showAll, !others.isEmpty {
          Text("\(others.count) hidden").font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(8)
    }
    .frame(width: 360, height: 400)
  }

  private func row(_ lora: ModelLibrary.LoRA, enabled: Bool) -> some View {
    Button {
      pick(lora)
    } label: {
      VStack(alignment: .leading) {
        HStack {
          Text(lora.name)
          Spacer()
          if lora.file == current { Image(systemName: "checkmark").accessibilityLabel("Current LoRA") }
        }
        Text(enabled ? lora.prefix.isEmpty ? lora.file : "Trigger: \(lora.prefix)" : lora.family)
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}
