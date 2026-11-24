@testable import Atelier
import Foundation
import Testing

/// Deleting a project's files (`ProjectFiles`, what `HistoryStore.delete` trashes): the file and
/// exactly its own -wal, -shm and media folder, never another project's whose name it starts.
@Suite(.tags(.smoke))
struct ProjectFilesTests {
  /// `discard` moving into a folder of the test's own, standing in for the Trash.
  private func moving(into trash: URL) -> (URL) throws -> URL? {
    { file in
      let target = trash.appending(path: file.lastPathComponent)
      try FileManager.default.moveItem(at: file, to: target)
      return target
    }
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  @Test func discardTakesTheFileAndExactlyItsSidecars() throws {
    try withTestFolder { folder in
      let projects = folder.appending(path: "Projects", directoryHint: .isDirectory)
      let trash = folder.appending(path: "Trash", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let url = projects.appending(path: "A.sqlite3")
      let own = ["A.sqlite3", "A.sqlite3-wal", "A.sqlite3-shm", "A.sqlite3-media/\(UUID().uuidString).mov"]
      // Names that start with A's, and one A's name is the start of.
      let others = [
        "A 2.sqlite3", "A 2.sqlite3-wal", "A 2.sqlite3-shm", "A 2.sqlite3-media/\(UUID().uuidString).mov",
        "A.sqlite3-media-old/x.mov", "A.sqlite3-walx", "AB.sqlite3-media/y.mov",
      ]
      for name in own + others { touch(projects.appending(path: name)) }

      let discarded = try ProjectFiles.discard(at: url, with: moving(into: trash))

      #expect(discarded == trash.appending(path: "A.sqlite3"))
      for suffix in ["", "-wal", "-shm", "-media"] {
        #expect(!exists(URL(fileURLWithPath: url.path + suffix)), "A.sqlite3\(suffix) left in Projects")
        #expect(exists(trash.appending(path: "A.sqlite3\(suffix)")), "A.sqlite3\(suffix) not in the Trash")
      }
      // The media folder went whole, its video with it.
      #expect(exists(trash.appending(path: own[3])))
      for name in others { #expect(exists(projects.appending(path: name)), "\(name) was taken") }
    }
  }

  @Test func aDatabaseThatCantGoLeavesEverything() throws {
    try withTestFolder { folder in
      let url = folder.appending(path: "A.sqlite3")
      for suffix in ["", "-wal", "-shm", "-media/v.mov"] { touch(URL(fileURLWithPath: url.path + suffix)) }
      struct Refused: Error {}
      #expect(throws: Refused.self) { try ProjectFiles.discard(at: url) { _ in throw Refused() } }
      for suffix in ["", "-wal", "-shm", "-media"] { #expect(exists(URL(fileURLWithPath: url.path + suffix))) }
    }
  }

  /// The Mac's Trash refusing a sidecar mustn't erase it: a media folder holds videos, a -wal
  /// writes not yet in the file.
  @Test func aSidecarThatCantGoStays() throws {
    try withTestFolder { folder in
      let trash = folder.appending(path: "Trash", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let url = folder.appending(path: "A.sqlite3")
      for suffix in ["", "-wal", "-shm", "-media/v.mov"] { touch(URL(fileURLWithPath: url.path + suffix)) }
      let move = moving(into: trash)
      struct Refused: Error {}
      // The database and its -shm move; the -wal and media folder can't.
      let refuse = { (file: URL) throws -> URL? in
        guard file.path.hasSuffix("-wal") || file.path.hasSuffix("-media") else { return try move(file) }
        throw Refused()
      }
      _ = try ProjectFiles.discard(at: url, with: refuse)
      ProjectFiles.sweepSidecars(of: url, with: refuse)
      #expect(!exists(url))
      #expect(!exists(URL(fileURLWithPath: url.path + "-shm")))
      #expect(exists(URL(fileURLWithPath: url.path + "-wal")))
      #expect(exists(URL(fileURLWithPath: url.path + "-media/v.mov")))
    }
  }

  @Test func sweepLeavesAProjectThatsThere() throws {
    try withTestFolder { folder in
      let trash = folder.appending(path: "Trash", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let url = folder.appending(path: "A.sqlite3")
      for suffix in ["", "-wal", "-shm"] { touch(URL(fileURLWithPath: url.path + suffix)) }
      ProjectFiles.sweepSidecars(of: url, with: moving(into: trash))
      for suffix in ["-wal", "-shm"] { #expect(exists(URL(fileURLWithPath: url.path + suffix))) }
      // Gone: what came back after it goes too, to the Trash.
      try FileManager.default.removeItem(at: url)
      touch(URL(fileURLWithPath: url.path + "-media/v.mov"))
      ProjectFiles.sweepSidecars(of: url, with: moving(into: trash))
      for suffix in ["-wal", "-shm", "-media"] {
        #expect(!exists(URL(fileURLWithPath: url.path + suffix)))
        #expect(exists(trash.appending(path: "A.sqlite3\(suffix)")))
      }
    }
  }

  @Test func emptyMediaFolderOfADeletedProjectGoes() throws {
    try withTestFolder { folder in
      let url = folder.appending(path: "A.sqlite3")
      let media = Media.folder(forProject: url)
      // While the project is there, an empty folder may be an import's about to copy in.
      touch(url)
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
      ProjectFiles.removeEmptyMediaFolder(ofProject: url)
      #expect(exists(media))
      try FileManager.default.removeItem(at: url)
      // Not one with a file in it.
      touch(media.appending(path: "v.mov"))
      ProjectFiles.removeEmptyMediaFolder(ofProject: url)
      #expect(exists(media))
      try FileManager.default.removeItem(at: media.appending(path: "v.mov"))
      ProjectFiles.removeEmptyMediaFolder(ofProject: url)
      #expect(!exists(media))
    }
  }
}
