import CoreGraphics
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Share for images and clips: on the Mac a Share submenu of the system's services (or, outside a
/// menu, a button opening the service picker); on iPad the share sheet. It takes the same lazy
/// `PNGExport`s drags do, so nothing is encoded, and no clip's MP4 written, until a share target
/// asks for the file; each is marked shared so its file goes in the Shares area, which keeps it
/// long enough for a slow target (`TemporaryFiles.shareLifetime`).
struct ShareItem: View {
  var exports: [PNGExport]
  var title = "Share"

  var body: some View {
    // A name only: a preview image would mean reading every image when the menu is built.
    ShareLink(items: exports.map(\.shared), preview: { SharePreview($0.name) }) {
      Text(title)
    }
    .disabled(exports.isEmpty)
  }
}

/// Share for a file already written somewhere the user picked (a finished video export), offered
/// while it's still there.
struct ShareFileItem: View {
  var url: URL

  var body: some View {
    #if os(macOS)
      // Not sandboxed: the target reads the file where it is.
      ShareLink(item: url, preview: SharePreview(url.deletingPathExtension().lastPathComponent)) {
        Text("Share")
      }
      .disabled(!SharedFile.exists(url))
    #else
      ShareLink(item: SharedFile(url: url), preview: SharePreview(url.deletingPathExtension().lastPathComponent)) {
        Text("Share")
      }
      .disabled(!SharedFile.exists(url))
    #endif
  }
}

/// A file the user saved to a place they picked, to share. On iPad that place is reachable only
/// through its security scope, which a share target doesn't get, so on iPad the export is copied
/// into the Shares area while the scope is open: a clone when it's on the same volume, a full
/// copy otherwise. The Mac shares the file where it is.
nonisolated struct SharedFile: Transferable {
  var url: URL

  static var transferRepresentation: some TransferRepresentation {
    // Video exports are always MP4 (`TimelineExportJob`).
    FileRepresentation(exportedContentType: .mpeg4Movie) { file in
      let access = file.url.startAccessingSecurityScopedResource()
      defer { if access { file.url.stopAccessingSecurityScopedResource() } }
      let copy = TemporaryFiles.newShareFolder().appendingPathComponent(file.url.lastPathComponent)
      try FileManager.default.copyItem(at: file.url, to: copy)
      return SentTransferredFile(copy)
    }
    .suggestedFileName { $0.url.lastPathComponent }
  }

  /// Whether the file is still there, looked at inside its security scope.
  static func exists(_ url: URL) -> Bool {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    return FileManager.default.fileExists(atPath: url.path)
  }
}

nonisolated extension PNGExport {
  /// The same export, its file going in the Shares area.
  var shared: PNGExport {
    var export = self
    export.isShared = true
    return export
  }

  /// An image that's no History step (opened, pasted or dropped on the canvas): a plain PNG, as
  /// Save Image writes one, with no settings to carry.
  static func image(_ image: CGImage, name: String) -> PNGExport {
    PNGExport(id: 0, name: name) {
      guard let png = ImageTensor.png(image) else { throw ProjectError.badImage }
      return png
    }
  }
}

extension HistoryStore {
  /// The canvas image to share, as Save Image saves it: a History step's image carries its
  /// settings, under its export name; anything else is a plain PNG named after the project. Only
  /// the image: a clip's frame shares as that frame, not as the clip.
  func canvasShare(image: CGImage, item: HistoryItem?) -> PNGExport {
    guard let item else { return .image(image, name: project.name) }
    return PNGExport(id: item.tensorId, name: fileName(for: item)) { [self] in try await pngData(item) }
  }
}
