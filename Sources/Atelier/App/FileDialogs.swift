import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The main window's Open and Save panels: one SwiftUI file importer, one file exporter and one
/// photo picker for the whole window, which every screen asks for a panel. Two file importers in
/// one view hierarchy compete for the same presentation.
@MainActor
@Observable
final class FileDialogs {
  struct Open {
    var types: [UTType]
    var multiple = false
    var directory: URL?
    /// The panel's default button, in place of "Open".
    var confirmation: String?
    var message: String?
    /// The chosen files, not called on cancel. Wrap their use in security-scoped access.
    var completion: @MainActor ([URL]) -> Void
  }

  struct Save {
    var file: ExportedFile
    var name: String
    /// Where it was written, or why it wasn't; not called on cancel.
    var completion: @MainActor (Result<URL, Error>) -> Void = { _ in }
  }

  /// A pick from the photo library. The picker runs outside the app, so it needs no permission
  /// to read the library.
  struct Photos {
    var multiple = false
    /// The picked photos' files as they are in the library, in the order they were picked, and how
    /// many couldn't be loaded; not called on cancel.
    var completion: @MainActor ([Data], _ failed: Int) -> Void
  }

  var photos: Photos? {
    didSet { if let photos { presentedPhotos = photos } }
  }

  var open: Open? {
    didSet { if let open { presentedOpen = open } }
  }

  var save: Save? {
    didSet { if let save { presentedSave = save } }
  }

  /// The last requests, kept for the completion handlers: the panel may clear `open` and `save`
  /// before it reports.
  @ObservationIgnored fileprivate var presentedOpen: Open?
  @ObservationIgnored fileprivate var presentedSave: Save?
  @ObservationIgnored fileprivate var presentedPhotos: Photos?
}

/// A file a Save panel writes: PNG, JSON, an MP4 video, Markdown or HTML, made when the panel confirms.
nonisolated struct ExportedFile: Transferable {
  let type: UTType
  let data: @MainActor () async throws -> Data

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .png) { try await $0.data() }
    DataRepresentation(exportedContentType: .json) { try await $0.data() }
    DataRepresentation(exportedContentType: .mpeg4Movie) { try await $0.data() }
    DataRepresentation(exportedContentType: .markdownText) { try await $0.data() }
    DataRepresentation(exportedContentType: .html) { try await $0.data() }
  }
}

nonisolated extension UTType {
  /// Markdown, as style files are written (docs/styles.md).
  static let markdownText = UTType("net.daringfireball.markdown") ?? .plainText
}

extension View {
  /// Presents the window's Open and Save panels.
  func fileDialogs(_ dialogs: FileDialogs) -> some View {
    modifier(FileDialogsModifier(dialogs: dialogs))
  }
}

private struct FileDialogsModifier: ViewModifier {
  let dialogs: FileDialogs
  @State private var pickedPhotos: [PhotosPickerItem] = []

  func body(content: Content) -> some View {
    let open = dialogs.open
    content
      .fileExporter(
        isPresented: Binding(get: { dialogs.save != nil }, set: { if !$0 { dialogs.save = nil } }),
        item: dialogs.save?.file,
        contentTypes: dialogs.save.map { [$0.file.type] } ?? [],
        defaultFilename: dialogs.save?.name
      ) { result in
        let request = dialogs.presentedSave
        dialogs.save = nil
        request?.completion(result)
      }
      .fileImporter(
        isPresented: Binding(get: { dialogs.open != nil }, set: { if !$0 { dialogs.open = nil } }),
        allowedContentTypes: open?.types ?? [],
        allowsMultipleSelection: open?.multiple ?? false
      ) { result in
        let request = dialogs.presentedOpen
        dialogs.open = nil
        guard let request, case .success(let urls) = result else { return }
        request.completion(urls)
      }
      .fileDialogDefaultDirectory(open?.directory)
      .fileDialogConfirmationLabel(open?.confirmation.map { Text($0) })
      .fileDialogMessage(open?.message.map { Text($0) })
      // `.current` keeps each photo's original file rather than a converted copy, so a PNG saved by
      // Atelier or Draw Things still carries its settings.
      .photosPicker(
        isPresented: Binding(get: { dialogs.photos != nil }, set: { if !$0 { dialogs.photos = nil } }),
        selection: $pickedPhotos,
        maxSelectionCount: dialogs.photos?.multiple == true ? nil : 1,
        selectionBehavior: .ordered,
        matching: .images,
        preferredItemEncoding: .current
      )
      .onChange(of: pickedPhotos) {
        guard !pickedPhotos.isEmpty, let request = dialogs.presentedPhotos else { return }
        let items = pickedPhotos
        pickedPhotos = []
        Task {
          var photos: [Data] = []
          for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) { photos.append(data) }
          }
          request.completion(photos, items.count - photos.count)
        }
      }
  }
}
