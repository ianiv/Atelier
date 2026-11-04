import Foundation

/// Scratch files, all under the temporary folder's "Atelier" folder, one subfolder per use, so
/// they can be swept without knowing each file. Only these subfolders are swept, never "Atelier"
/// itself: other features keep folders of their own there.
nonisolated enum TemporaryFiles {
  enum Area: String, CaseIterable {
    /// Video exports on their way to the file the user picked.
    case exports = "Exports"
    /// Files dragged out of History.
    case drags = "Drags"
    case quickLook = "QuickLook"
    /// What agents generate when they don't say where to save it.
    case agent = "Agent"
  }

  /// A drag's receiver reads the file when the drag ends; well after that, nothing needs it.
  private static let dragLifetime: TimeInterval = 60 * 60

  static var root: URL {
    FileManager.default.temporaryDirectory.appending(path: "Atelier", directoryHint: .isDirectory)
  }

  /// The area's folder, made if needed.
  static func folder(_ area: Area) -> URL {
    let folder = root.appending(path: area.rawValue, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// A new folder in the area, for a file that keeps its own name.
  static func newFolder(in area: Area) -> URL {
    let folder = folder(area).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// A new file's address in the area.
  static func newFile(in area: Area, extension fileExtension: String) -> URL {
    folder(area).appending(path: UUID().uuidString).appendingPathExtension(fileExtension)
  }

  /// A new folder for a dragged file. Clears out earlier drags, so a long session's don't pile up.
  static func newDragFolder() -> URL {
    sweep([.drags], olderThan: dragLifetime)
    return newFolder(in: .drags)
  }

  /// Empties the areas' folders, or with `olderThan`, removes what hasn't changed for that long.
  static func sweep(_ areas: [Area], in root: URL = root, olderThan age: TimeInterval? = nil) {
    let fileManager = FileManager.default
    for area in areas {
      let folder = root.appending(path: area.rawValue, directoryHint: .isDirectory)
      let items = (try? fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for item in items {
        if let age {
          let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
          guard let modified, Date().timeIntervalSince(modified) > age else { continue }
        }
        try? fileManager.removeItem(at: item)
      }
    }
  }

  /// What the last run left behind: every area, and the engine folders of runs that ended.
  @concurrent static func cleanAtLaunch() async {
    sweep(Area.allCases)
    let temporary = FileManager.default.temporaryDirectory
    // Where Quick Look files went before they moved to their area.
    try? FileManager.default.removeItem(at: temporary.appending(path: "Atelier Quick Look"))
    removeEngineFolders(in: temporary, olderThan: 60 * 60)
  }

  /// What nothing needs once the app is gone. Dragged files stay until the next launch, as the
  /// app they went to may still be reading them, and agents' files too: they may read them later.
  static func cleanAtQuit() {
    sweep([.exports, .quickLook])
    if let engineFolder = GenerationEngine.temporaryDirectory {
      try? FileManager.default.removeItem(at: engineFolder)
    }
  }

  /// MGK makes a folder in the temporary folder for each run of the app, named with a UUID and
  /// holding only an empty settings database, and never removes it
  /// (`MediaGenerationExecutionUtilities.createTemporaryDirectory`). Only folders that match all
  /// of that are removed, and not recent ones, which another copy of the app may be using.
  static func removeEngineFolders(in temporary: URL, olderThan age: TimeInterval) {
    let fileManager = FileManager.default
    let databaseFiles: Set = ["config.sqlite3", "config.sqlite3-wal", "config.sqlite3-shm"]
    let items = (try? fileManager.contentsOfDirectory(
      at: temporary, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for item in items where UUID(uuidString: item.lastPathComponent) != nil {
      guard let files = try? fileManager.contentsOfDirectory(atPath: item.path),
            files.contains("config.sqlite3"), Set(files).isSubset(of: databaseFiles),
            let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            Date().timeIntervalSince(modified) > age
      else { continue }
      try? fileManager.removeItem(at: item)
    }
  }
}
