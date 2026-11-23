@preconcurrency import _MediaGenerationKit
@preconcurrency import Diffusion
import SwiftUI

/// What opens the link sheet: the screen it's opened from (which kind it starts on) and a link
/// dropped on that screen, if any.
struct LinkSheetRequest: Identifiable {
  let id = UUID()
  var kind: HuggingFaceListing.Kind
  var link: String?
}

/// Import from a Hugging Face link: look the link up, pick files (a Diffusers model's denoiser, a
/// checkpoint, a set of split safetensors), see the family before downloading, then download into
/// a staging folder; the usual import sheet opens when it's done. Also lists downloads that
/// stopped, to resume or discard. Every control stays in place and is disabled when it can't act.
struct HuggingFaceImportSheet: View {
  @Environment(ModelLibrary.self) private var library
  @Environment(\.dismiss) private var dismiss
  let request: LinkSheetRequest

  @State private var text = ""
  @State private var kind = HuggingFaceListing.Kind.model
  @State private var lookup: HuggingFaceLookup?
  @State private var lookingUp = false
  @State private var lookupError: String?
  @State private var selection: Set<String> = []
  @State private var variant = ""
  @State private var inspections: [String: LinkInspection] = [:]
  /// The staging folder of the download this sheet started, to show its progress.
  @State private var started: String?

  private static let diffusersID = "diffusers"

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import from Hugging Face").font(.headline)
      Text("Paste a link to a model repo, a folder in it or one of its files. The file is downloaded, then imported as usual: converted into the folder below and listed in its custom.json.")
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      linkRow
      Text(status)
        .font(.caption).foregroundStyle(lookupError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        .lineLimit(3)
      Picker("Import as", selection: $kind) {
        Text("Model").tag(HuggingFaceListing.Kind.model)
        Text("LoRA").tag(HuggingFaceListing.Kind.lora)
      }
      .pickerStyle(.segmented)
      .fixedSize()
      .disabled(isDownloading)
      fileList
      Text(detection)
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(3)
      catalogRow
      HStack {
        AddFolderPicker()
          .disabled(isDownloading)
        Spacer()
        Text(spaceText).font(.caption).foregroundStyle(hasSpace ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
      }
      progressRow
      unfinishedSection
      HStack {
        Spacer()
        Button("Continue in Background") { dismiss() }
          .disabled(!isDownloading)
        Button("Close", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Download") { download() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canDownload)
      }
    }
    .sheetPadding()
    .sheetFrame(width: 620)
    .onAppear {
      kind = request.kind
      // Only a full Hugging Face link is taken from the clipboard and looked up on its own: other
      // copied text, even one shaped like `owner/repo`, never leaves the device unasked.
      if let link = request.link {
        text = link
      } else if let copied = Clipboard.string, HuggingFaceLink.isExplicitLink(copied) {
        text = copied.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if HuggingFaceLink.isExplicitLink(text) { Task { await look() } }
    }
    .task {
      await library.reloadUnfinishedLinkDownloads()
      await library.huggingFace.checkIfNeeded()
    }
    .onChange(of: selection) { inspectSelection() }
    .onChange(of: variant) { inspectSelection() }
    .onChange(of: kind) {
      selection = selection.filter { id in entry(id).map { $0.problem(for: kind) == nil } ?? false }
      inspectSelection()
    }
  }

  // MARK: - Link

  private var linkRow: some View {
    HStack {
      TextField("Link", text: $text, prompt: Text("https://huggingface.co/owner/repo"))
        .labelsHidden()
        .onSubmit { Task { await look() } }
        .disabled(isDownloading)
      Button("Look Up") { Task { await look() } }
        .disabled(lookingUp || isDownloading || HuggingFaceLink.parse(text) == nil)
    }
  }

  private var status: String {
    if lookingUp { return "Looking up…" }
    if let lookupError { return lookupError }
    guard let lookup else {
      return text.isEmpty || HuggingFaceLink.parse(text) != nil ? "Hugging Face models only; datasets and Spaces can't be imported." : HuggingFaceError.notALink.localizedDescription
    }
    var parts = ["\(lookup.link.repo) at \(lookup.info.sha.prefix(7))"]
    if lookup.info.isGated {
      let account = library.huggingFace
      parts.append(
        account.userName.map { "Gated: accept its terms on huggingface.co while signed in as \($0)." }
          ?? "Gated: add a token in Settings ▸ Models and accept its terms on huggingface.co.")
    }
    if lookup.info.isPrivate { parts.append("Private.") }
    return parts.joined(separator: " · ")
  }

  private func look() async {
    guard let link = HuggingFaceLink.parse(text), !lookingUp else { return }
    lookingUp = true
    lookupError = nil
    defer { lookingUp = false }
    do {
      let result = try await library.lookUp(link)
      lookup = result
      inspections = [:]
      variant = result.listing.diffusers?.variants.first?.id ?? ""
      selection = defaultSelection(result)
      let first = selection.first.flatMap(entry)
      if request.kind == .model, HuggingFaceListing.guessesLoRA(repo: link.repo, entry: first), result.listing.diffusers == nil {
        kind = .lora
      } else if request.kind == .lora, result.listing.diffusers?.folder != nil {
        kind = .model
      }
      selection = selection.filter { entry($0)?.problem(for: kind) == nil }
      inspectSelection()
    } catch {
      lookup = nil
      selection = []
      lookupError = error.localizedDescription
    }
  }

  /// The row the link points at: the file or folder it names, else a Diffusers model's denoiser,
  /// else the only importable row.
  private func defaultSelection(_ lookup: HuggingFaceLookup) -> Set<String> {
    let listing = lookup.listing
    if let path = lookup.link.path {
      if let folder = listing.diffusers?.folder, path == folder || path.hasPrefix(folder + "/") { return [Self.diffusersID] }
      if let match = listing.entries.first(where: { $0.files.contains { $0.path == path } }) { return [match.id] }
      let inFolder = listing.entries.filter { $0.modelProblem == nil && $0.files.allSatisfy { $0.path.hasPrefix(path + "/") } }
      if inFolder.count == 1 { return [inFolder[0].id] }
    }
    if listing.diffusers?.folder != nil, listing.diffusers?.variants.first?.entry.modelProblem == nil { return [Self.diffusersID] }
    let importable = listing.entries.filter { $0.modelProblem == nil || $0.loraProblem == nil }
    return importable.count == 1 ? [importable[0].id] : []
  }

  // MARK: - Files

  private var diffusersEntry: HuggingFaceListing.Entry? {
    guard let diffusers = lookup?.listing.diffusers else { return nil }
    return (diffusers.variants.first { $0.id == variant } ?? diffusers.variants.first)?.entry
  }

  private func entry(_ id: String) -> HuggingFaceListing.Entry? {
    id == Self.diffusersID ? diffusersEntry : lookup?.listing.entries.first { $0.id == id }
  }

  private var selectedEntries: [HuggingFaceListing.Entry] {
    var entries: [HuggingFaceListing.Entry] = []
    if selection.contains(Self.diffusersID), let diffusersEntry { entries.append(diffusersEntry) }
    entries += (lookup?.listing.entries ?? []).filter { selection.contains($0.id) }
    return entries
  }

  private var fileList: some View {
    List {
      if let lookup {
        if let diffusers = lookup.listing.diffusers {
          diffusersRow(diffusers)
        }
        ForEach(lookup.listing.entries) { entry in
          row(id: entry.id, title: entry.title, detail: entry.detail, size: entry.size, problem: entry.problem(for: kind))
        }
        if lookup.listing.entries.isEmpty, lookup.listing.diffusers == nil {
          Text("This repo has no checkpoint files.").foregroundStyle(.secondary)
        }
      } else {
        Text("Look up a link to see its files.").foregroundStyle(.secondary)
      }
    }
    .frame(minHeight: 160, idealHeight: 220, maxHeight: 280)
    .disabled(isDownloading)
  }

  @ViewBuilder
  private func diffusersRow(_ diffusers: HuggingFaceListing.Diffusers) -> some View {
    if diffusers.folder == nil || diffusers.variants.isEmpty {
      row(
        id: Self.diffusersID, title: "Diffusers model: \(diffusers.className)", detail: "Diffusers pipeline", size: nil,
        problem: "Only Diffusers models with a transformer/ or unet/ folder can be imported.")
    } else if let entry = diffusersEntry {
      VStack(alignment: .leading, spacing: 4) {
        row(id: Self.diffusersID, title: entry.title, detail: entry.detail, size: entry.size, problem: entry.problem(for: kind))
        Picker("Precision", selection: $variant) {
          ForEach(diffusers.variants) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(diffusers.variants.count < 2)
        .padding(.leading, 24)
      }
    }
  }

  private func row(id: String, title: String, detail: String, size: Int64?, problem: String?) -> some View {
    Toggle(isOn: Binding(
      get: { selection.contains(id) },
      set: { on in if on { selection.insert(id) } else { selection.remove(id) } })
    ) {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(title).lineLimit(1).truncationMode(.middle)
          Spacer()
          if let size { Text(ModelsView.bytes(size)).monospacedDigit().foregroundStyle(.secondary) }
        }
        Text(problem ?? detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .disabled(problem != nil)
  }

  // MARK: - Detection, catalog, space

  private func inspectionKey(_ entry: HuggingFaceListing.Entry) -> String { entry.id }

  /// Inspects each selected model row once, from its header on Hugging Face.
  private func inspectSelection() {
    guard let lookup, kind == .model else { return }
    for entry in selectedEntries where inspections[inspectionKey(entry)] == nil && entry.modelProblem == nil {
      let key = inspectionKey(entry)
      inspections[key] = .checking
      Task {
        let result = await library.inspectBeforeDownload(entry, lookup: lookup)
        if self.lookup == lookup { inspections[key] = result }
      }
    }
  }

  private var detection: String {
    guard kind == .model, !selectedEntries.isEmpty else {
      return kind == .lora ? "The LoRA's family is detected when it's imported." : " "
    }
    return selectedEntries.map { entry in
      let name = selectedEntries.count > 1 ? entry.title + ": " : ""
      switch inspections[inspectionKey(entry)] {
      case .checking?, nil: return name + "Detecting model family…"
      case .detected(let family, _, let companions, _)?:
        return name + "Detected: \(family)" + (companions.isEmpty ? "" : ", plus \(companions.count) text encoder and VAE \(companions.count == 1 ? "file" : "files") to download")
      case .problem(let problem)?: return name + problem
      case .warning(let warning)?: return name + warning
      case .afterDownload?: return name + "The family is detected after the download."
      }
    }.joined(separator: "\n")
  }

  /// A selected row the header check found can't be imported.
  private var hasInspectionProblem: Bool {
    kind == .model && selectedEntries.contains {
      if case .problem? = inspections[inspectionKey($0)] { true } else { false }
    }
  }

  private var catalogMatch: MediaGenerationResolvedModelMatch? {
    lookup.flatMap { library.catalogMatch(for: $0.link.repo) }
  }

  private var catalogRow: some View {
    HStack {
      Text(catalogMatch.map { "The catalog has this model already converted: \($0.model.name)." } ?? "No converted copy of this repo in the catalog.")
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
      Button("Download Converted") {
        if let match = catalogMatch { library.download(match.model) }
      }
      .disabled(catalogMatch.map { $0.model.isDownloaded || library.downloads[$0.model.file] != nil } ?? true)
      .help("Download the catalog's converted copy instead, with its text encoders and VAE")
    }
  }

  private var companionBytes: Int64 {
    selectedEntries.reduce(0) { total, entry in
      if case .detected(_, _, _, let bytes)? = inspections[inspectionKey(entry)] { total + bytes } else { total }
    }
  }

  private var required: Int64 {
    ModelLibrary.requiredSpace(downloadSize: selectedEntries.reduce(0) { $0 + $1.size }, kind: kind, companionBytes: companionBytes)
  }

  private var free: Int64? { ModelLibrary.freeSpace(at: library.addFolder) }

  private var hasSpace: Bool { free.map { $0 >= required } ?? true }

  private var spaceText: String {
    guard !selectedEntries.isEmpty else { return free.map { "\(ModelsView.bytes($0)) free" } ?? "" }
    return "Needs about \(ModelsView.bytes(required))" + (free.map { ", \(ModelsView.bytes($0)) free" } ?? "")
  }

  // MARK: - Download

  private var isDownloading: Bool { started.map { library.linkDownloadTasks[$0] != nil } ?? false }

  private var canDownload: Bool {
    lookup != nil && !selectedEntries.isEmpty && !isDownloading && !lookingUp && hasSpace && !hasInspectionProblem
      && selectedEntries.allSatisfy { $0.problem(for: kind) == nil }
  }

  private func download() {
    guard canDownload, let lookup else { return }
    let before = Set(library.linkDownloadTasks.keys)
    let detected = selectedEntries.compactMap { entry -> ModelVersion? in
      guard case .detected(_, let version?, _, _)? = inspections[inspectionKey(entry)] else { return nil }
      return ModelVersion(rawValue: version)
    }
    library.startLinkDownload(selectedEntries, kind: kind, lookup: lookup, linkText: text, detected: detected)
    started = Set(library.linkDownloadTasks.keys).subtracting(before).first
  }

  private var progressRow: some View {
    let progress = started.flatMap { library.linkDownloads[$0] }
    return HStack {
      if let fraction = progress?.fraction {
        ProgressView(value: fraction).frame(width: 160)
      } else {
        ProgressView(value: 0).frame(width: 160).opacity(progress == nil ? 0.4 : 1)
      }
      Text(progress?.description ?? stoppedText)
        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
      Spacer()
      Button("Cancel Download") {
        if let started { library.cancelLinkDownload(started) }
      }
      .disabled(!isDownloading || progress?.download?.cancelPending == true)
    }
  }

  /// After this sheet's download stops: why, if it failed (the screen's alert can't show over the
  /// sheet), or that it's waiting under Unfinished Downloads.
  private var stoppedText: String {
    guard let started else { return "Not downloading." }
    if let message = library.errorMessage { return message }
    if library.unfinishedLinkDownloads.contains(where: { $0.id == started }) { return "Stopped. Resume it under Unfinished Downloads." }
    return "Done: the import sheet opens with the file."
  }

  // MARK: - Unfinished

  private var unfinishedSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Unfinished Downloads").font(.subheadline.bold())
      if library.unfinishedLinkDownloads.isEmpty {
        Text("None. A download that's cancelled or stops keeps its files here until you resume or discard it.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(library.unfinishedLinkDownloads) { unfinished in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(unfinished.record.title).lineLimit(1).truncationMode(.middle)
                  Text((unfinished.isComplete ? "Downloaded, not imported" : "Partly downloaded") + " · \(ModelsView.bytes(unfinished.bytesOnDisk)) on disk")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(unfinished.isComplete ? "Import" : "Resume") {
                  started = unfinished.id
                  library.resumeLinkDownload(unfinished)
                }
                .disabled(isDownloading)
                Button("Discard", role: .destructive) {
                  Task { await library.discardLinkDownload(unfinished) }
                }
              }
            }
          }
        }
        .frame(maxHeight: 120)
      }
    }
  }
}

/// Running link downloads of one kind, for the Models footer and the LoRAs screen, in the style
/// of a catalog row's download (`ModelStatus`).
struct LinkDownloadsStatus: View {
  let library: ModelLibrary
  let kind: HuggingFaceListing.Kind

  var body: some View {
    let running = library.linkDownloads.filter { $0.value.kind == kind }.sorted { $0.key < $1.key }
    ForEach(running, id: \.key) { key, progress in
      HStack(spacing: 6) {
        if let fraction = progress.fraction {
          ProgressView(value: fraction).controlSize(.small).frame(width: 100)
        } else {
          ProgressView().controlSize(.small)
        }
        Button {
          library.cancelLinkDownload(key)
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .disabled(progress.download?.cancelPending == true)
        .help(progress.download?.cancelPending == true ? "Cancels when the file is finished" : "Cancel download")
        .accessibilityLabel("Cancel download")
      }
      .help("\(progress.title): \(progress.description)")
    }
  }
}
