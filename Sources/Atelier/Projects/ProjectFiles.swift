import Foundation

/// A project file's sidecars, and discarding a project with them (`HistoryStore.delete`). Kept
/// apart from `HistoryStore` so the rules can be tested on a temp folder without models or the
/// real Trash.
nonisolated enum ProjectFiles {
  /// What SQLite (`-wal`, `-shm`) and `Media` (`-media`) add to the project file's path. Only these
  /// exact names belong to a project: "A.sqlite3-wal" is A's, never "A 2.sqlite3-wal".
  static let sidecarSuffixes = ["-wal", "-shm", Media.suffix]

  /// The sidecars `url` can have, there or not.
  static func sidecars(of url: URL) -> [URL] {
    sidecarSuffixes.map { URL(fileURLWithPath: url.path + $0) }
  }

  /// Discards the project file at `url` and its sidecars with `discard` (to the Trash on the Mac),
  /// returning what it returned for the file. The database goes first: when it can't, nothing
  /// else has, and the project is still whole. Then each sidecar; one that fails is logged, since
  /// the project itself is gone by then. A last sweep removes outright any sidecar that's there
  /// again: a connection let go just before (a `Project`'s deinit checkpoint, a clean-up) or a
  /// video import finishing can bring back a -wal, -shm or media folder at the old path, and
  /// nothing would ever remove it, or a project made later under the name would pick it up.
  static func discard(at url: URL, with discard: (URL) throws -> URL?) throws -> URL? {
    let fileManager = FileManager.default
    let discarded = fileManager.fileExists(atPath: url.path) ? try discard(url) : nil
    for side in sidecars(of: url) where fileManager.fileExists(atPath: side.path) {
      Log.attempt(Log.project, "Deleting a project's \(side.lastPathComponent) file") { _ = try discard(side) }
    }
    sweepSidecars(of: url)
    return discarded
  }

  /// Removes any sidecar of `url` that's there while its project file isn't (a deleted project's,
  /// brought back after it went). Nothing while the file is there: they're its data.
  static func sweepSidecars(of url: URL) {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: url.path) else { return }
    for side in sidecars(of: url) where fileManager.fileExists(atPath: side.path) {
      Log.attempt(Log.project, "Removing a deleted project's \(side.lastPathComponent)") {
        try fileManager.removeItem(at: side)
      }
    }
  }

  /// Removes a project's media folder when it's empty, for an import that stopped after its
  /// project closed (a delete, a rename): it may have made the folder again at the old path. Not
  /// while the project file is there, where another import may be about to copy in.
  static func removeEmptyMediaFolder(ofProject url: URL) {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: url.path) else { return }
    let folder = Media.folder(forProject: url)
    guard let contents = try? fileManager.contentsOfDirectory(atPath: folder.path), contents.isEmpty else { return }
    try? fileManager.removeItem(at: folder)
  }
}
