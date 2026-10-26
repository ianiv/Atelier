import Foundation

/// Keeps a security-scoped file or folder open while something needs it, such as a file picked on
/// iPad waiting in the import sheet. Free on the Mac, where Atelier isn't sandboxed.
final class ScopedAccess {
  let url: URL
  private let started: Bool

  init(_ url: URL) {
    self.url = url
    started = url.startAccessingSecurityScopedResource()
  }

  deinit {
    if started { url.stopAccessingSecurityScopedResource() }
  }
}

/// Output folders picked on iPad, remembered as bookmarks: an iPad app can write outside its
/// container only to a folder the user picked, and only through a bookmark after a relaunch. The
/// settings keep the folder's path; this maps the path back to the bookmark. The Mac uses the
/// path as it is.
enum FolderBookmarks {
  private static let key = "folderBookmarks"

  /// Remembers a folder the file picker returned.
  static func remember(_ url: URL) {
    #if os(iOS)
      let access = ScopedAccess(url)
      guard let data = try? access.url.bookmarkData() else { return }
      var bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
      bookmarks[url.path] = data
      UserDefaults.standard.set(bookmarks, forKey: key)
    #endif
  }

  private static var held: [String: ScopedAccess] = [:]

  /// Keeps the folder at `path` open until another is kept open in its place, for the models
  /// folder the engine reads from.
  @MainActor static func keepOpen(_ path: String) {
    held = ["models": open(path)]
  }

  /// Forgets a folder's bookmark once a setting stops using it.
  static func forget(_ path: String) {
    var bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    bookmarks[path] = nil
    UserDefaults.standard.set(bookmarks, forKey: key)
  }

  /// Whether the folder at `path` can be reached now (a picked folder on a drive that's been
  /// disconnected, or one that's been deleted, can't).
  static func isReachable(_ path: String) -> Bool {
    let access = open(path)
    var isFolder: ObjCBool = false
    return FileManager.default.fileExists(atPath: access.url.path, isDirectory: &isFolder)
      && isFolder.boolValue
  }

  /// Opens the folder at `path`, through its bookmark when there is one.
  static func open(_ path: String) -> ScopedAccess {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    #if os(iOS)
      var stale = false
      if let data = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data])?[path],
        let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
      {
        if stale { remember(resolved) }
        return ScopedAccess(resolved)
      }
    #endif
    return ScopedAccess(url)
  }
}

#if os(iOS)
import Photos

/// The iPad's photo library, for Save to Photos.
enum PhotoLibrary {
  /// Adds PNGs (and videos, from their files) to the library, asking for permission to add the
  /// first time.
  static func save(_ pngs: [Data], videos: [URL] = []) async throws {
    guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
      throw CocoaError(.fileWriteNoPermission, userInfo: [
        NSLocalizedDescriptionKey:
          "Atelier isn't allowed to add photos. Turn it on in Settings ▸ Apps ▸ Atelier ▸ Photos."
      ])
    }
    try await PHPhotoLibrary.shared().performChanges {
      for png in pngs {
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: nil)
      }
      for video in videos {
        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: video, options: nil)
      }
    }
  }
}
#endif
