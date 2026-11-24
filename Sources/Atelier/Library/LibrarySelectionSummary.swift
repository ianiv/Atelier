@preconcurrency import _MediaGenerationKit
import SwiftUI

/// The inspector for several selected models or LoRAs: how many, their size and folders, and the
/// commands that work on all of them at once. Per-item commands (8-bit copies, a Hugging Face
/// page, a LoRA's name and trigger words) belong to one item's inspector, so they aren't here,
/// as they aren't under "No selection" either. The buttons are always there, disabled when none
/// of the selection fits.
struct LibrarySelectionSummary: View {
  private enum Items {
    case models([MediaGenerationResolvedModel])
    case loras([ModelLibrary.LoRA])
  }

  private let items: Items
  private let includesH3Image: Bool
  private let trash: () -> Void
  private let move: (URL) -> Void
  @Environment(ModelLibrary.self) private var library

  init(
    models: [MediaGenerationResolvedModel], includesH3Image: Bool = false, trash: @escaping () -> Void,
    move: @escaping (URL) -> Void
  ) {
    items = .models(models)
    self.includesH3Image = includesH3Image
    self.trash = trash
    self.move = move
  }

  init(loras: [ModelLibrary.LoRA], trash: @escaping () -> Void, move: @escaping (URL) -> Void) {
    items = .loras(loras)
    includesH3Image = false
    self.trash = trash
    self.move = move
  }

  /// Reveal fits when one is downloaded. Files on iPad opens one folder, so there they must
  /// all be in the same one.
  static func canReveal(_ folders: [URL?]) -> Bool {
    let folders = folders.compactMap(\.self)
    guard !folders.isEmpty else { return false }
    #if os(iOS)
      return Set(folders.map(\.standardizedFileURL)).count == 1
    #else
      return true
    #endif
  }

  var body: some View {
    Form {
      switch items {
      case .models(let models): modelSection(models)
      case .loras(let loras): loraSection(loras)
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private func modelSection(_ models: [MediaGenerationResolvedModel]) -> some View {
    let files = models.map(\.file)
    let summary = ModelLibrary.SelectionSummary.make(
      files: files, sizes: library.sizes, folders: library.folders.mapValues(library.folderName),
      families: Dictionary(models.compactMap { model in model.version.map { (model.file, $0) } }) { first, _ in first })
    let kinds = library.selectionKinds(models)
    let downloaded = models.filter(\.isDownloaded)
    let count = models.count + (includesH3Image ? 1 : 0)
    Section {
      Text("\(count) models selected").font(.headline)
      LabeledContent("Size on disk", value: ModelsView.bytes(summary.bytes))
      Text("Not counting shared text encoders and VAEs.")
        .font(.caption).foregroundStyle(.secondary)
      // The MiniMax H3 Image row counts once its install has finished.
      let downloadedCount = summary.downloaded + (includesH3Image && library.h3ImageInstalled ? 1 : 0)
      if downloadedCount != count {
        LabeledContent("Downloaded", value: "\(downloadedCount) of \(count)")
      }
      folderRows(summary)
      if let family = summary.family { LabeledContent("Family", value: family) }
      ButtonRow {
        Button(Finder.revealTitle) { library.reveal(downloaded.map(\.file)) }
          .disabled(!Self.canReveal(downloaded.map { library.folders[$0.file] }))
        MoveToFolderMenu(
          library: library, files: downloaded.map(\.file), folders: downloaded.map { library.folders[$0.file] },
          enabled: kinds.canMove, choose: move)
        Button("Move to Trash", role: .destructive, action: trash)
          .disabled(!kinds.canTrash)
      }
      ButtonRow {
        Button("Download") {
          for model in models where !model.isDownloaded && !library.isCustom(model) && library.downloads[model.file] == nil {
            library.download(model)
          }
        }
        .disabled(!kinds.canDownload)
        Button("Cancel Download") {
          for model in models where library.downloads[model.file] != nil { library.cancelDownload(model.file) }
        }
        .disabled(!kinds.canCancelDownload)
      }
      MoveProgressRow(files: files)
    }
  }

  @ViewBuilder
  private func loraSection(_ loras: [ModelLibrary.LoRA]) -> some View {
    let files = loras.map(\.file)
    let summary = ModelLibrary.SelectionSummary.make(
      files: files, sizes: Dictionary(loras.compactMap { lora in lora.size.map { (lora.file, $0) } }) { first, _ in first },
      folders: Dictionary(loras.compactMap { lora in lora.folder.map { (lora.file, library.folderName($0)) } }) { first, _ in first },
      families: Dictionary(loras.map { ($0.file, $0.family) }) { first, _ in first })
    let present = loras.filter(\.isDownloaded)
    Section {
      Text("\(loras.count) LoRAs selected").font(.headline)
      LabeledContent("Size on disk", value: ModelsView.bytes(summary.bytes))
      if summary.downloaded < loras.count {
        let missing = loras.count - summary.downloaded
        LabeledContent("Missing", value: ModelLibrary.counted(missing, "file"))
      }
      folderRows(summary)
      if let family = summary.family { LabeledContent("For", value: family) }
      ButtonRow {
        Button(Finder.revealTitle) { library.reveal(present.map(\.file)) }
          .disabled(!Self.canReveal(present.map(\.folder)))
        MoveToFolderMenu(
          library: library, files: present.map(\.file), folders: present.map(\.folder),
          enabled: present.contains(where: library.canMove), choose: move)
        Button("Move to Trash", role: .destructive, action: trash)
          .disabled(loras.allSatisfy { library.moving?.files.contains($0.file) == true })
      }
      MoveProgressRow(files: files)
    }
  }

  @ViewBuilder
  private func folderRows(_ summary: ModelLibrary.SelectionSummary) -> some View {
    if let folder = summary.folder {
      LabeledContent("Folder", value: folder)
      ForEach(summary.folderCounts, id: \.name) { entry in
        LabeledContent(entry.name, value: "\(entry.count)")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
