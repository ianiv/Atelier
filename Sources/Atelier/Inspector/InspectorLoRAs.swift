import SwiftUI
import _MediaGenerationKit

struct LoRAEditor: View {
  let descriptor: SettingDescriptor
  @Environment(CreateModel.self) private var model
  @Environment(ModelLibrary.self) private var library
  @Environment(\.undoManager) private var undoManager
  @State private var picking = false

  private struct Item: Hashable {
    var file: String
    var weight: Double
    var mode: JSONValue
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
      model.models.first { $0.file == file }?.version
    }
    return ModelLibrary.loraFamilies(forModel: model.selectedModelInfo?.version, refiner: refiner)
  }

  private func write(_ items: [Item], undo: Bool = true) {
    let value = JSONValue.array(items.map {
      .object(["file": .string($0.file), "weight": .number($0.weight), "mode": $0.mode])
    })
    model.set(descriptor, to: value, undoManager: undo ? undoManager : nil)
  }

  var body: some View {
    let items = items
    let compatible = compatibleFamilies
    VStack(alignment: .leading, spacing: 6) {
      if items.isEmpty {
        Text("No LoRAs").foregroundStyle(.secondary)
      }
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(name(item.file)).lineLimit(1).truncationMode(.middle)
              .help(item.file)
            if let lora = library.loras.first(where: { $0.file == item.file }),
              !compatible.contains(lora.family)
            {
              Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                .help("Made for \(lora.family), so it's skipped with this model.")
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
          }
          HStack(spacing: 6) {
            Slider(
              value: Binding(
                get: { item.weight },
                set: { weight in
                  var items = items
                  items[index].weight = (weight * 100).rounded() / 100
                  write(items)
                }), in: -1.5...2.5
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
        }
      }
      Button("Add LoRA…", systemImage: "plus") { picking = true }
        .buttonStyle(.borderless)
        .popover(isPresented: $picking, arrowEdge: .leading) {
          LoRAPicker(
            catalog: library.loras.filter(\.isDownloaded), compatible: compatible,
            modelFamily: model.selectedModelInfo?.version
          ) { lora in
            write(items + [Item(file: lora.file, weight: 1, mode: .string("all"))])
            picking = false
          }
        }
    }
    .onAppear { library.reloadLoRAs() }
  }

  private func name(_ file: String) -> String {
    library.loras.first { $0.file == file }?.name ?? file
  }
}

/// Searchable list of downloaded LoRAs made for the selected model's family.
struct LoRAPicker: View {
  let catalog: [ModelLibrary.LoRA]
  let compatible: Set<String>
  let modelFamily: String?
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
      if catalog.isEmpty {
        Text("No LoRAs yet. Import them in the LoRAs section.")
          .foregroundStyle(.secondary).padding()
      } else if fitting.isEmpty && !showAll {
        Text("No LoRAs for \(modelFamily ?? "this model")\(query.isEmpty ? "" : " match").")
          .foregroundStyle(.secondary).padding()
      }
      List {
        ForEach(fitting) { lora in row(lora, enabled: true) }
        if showAll && !others.isEmpty {
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
        if !showAll && !others.isEmpty {
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
        Text(lora.name)
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
