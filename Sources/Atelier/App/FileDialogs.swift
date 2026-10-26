import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The main window's Open and Save panels: one SwiftUI file importer and one file exporter for the
/// whole window, which every screen asks for a panel. Two file importers in one view hierarchy
/// compete for the same presentation.
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
}

/// A file a Save panel writes: PNG, JSON or an MP4 video, made when the panel confirms.
struct ExportedFile: Transferable {
  let type: UTType
  let data: () async throws -> Data

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .png) { try await $0.data() }
    DataRepresentation(exportedContentType: .json) { try await $0.data() }
    DataRepresentation(exportedContentType: .mpeg4Movie) { try await $0.data() }
  }
}

extension View {
  /// Presents the window's Open and Save panels.
  func fileDialogs(_ dialogs: FileDialogs) -> some View {
    modifier(FileDialogsModifier(dialogs: dialogs))
  }
}

private struct FileDialogsModifier: ViewModifier {
  let dialogs: FileDialogs

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
  }
}
