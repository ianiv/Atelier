@testable import Atelier
import Foundation
import Testing

struct TemporaryFilesTests {
  @Test func aSweepEmptiesTheAreasAndNothingElse() {
    withTestFolder { root in
      for area in TemporaryFiles.Area.allCases { touch(root.appending(path: "\(area.rawValue)/file")) }
      touch(root.appending(path: "CharacterPreviews/preview.png"))
      TemporaryFiles.sweep(TemporaryFiles.Area.allCases, in: root)
      for area in TemporaryFiles.Area.allCases {
        #expect(names(root.appending(path: area.rawValue)).isEmpty, "\(area)")
      }
      #expect(names(root.appending(path: "CharacterPreviews")) == ["preview.png"])
    }
  }

  @Test func aSweepOfOneAreaLeavesTheOthers() {
    withTestFolder { root in
      touch(root.appending(path: "Exports/file"))
      touch(root.appending(path: "Agent/file"))
      TemporaryFiles.sweep([.exports], in: root)
      #expect(names(root.appending(path: "Exports")).isEmpty)
      #expect(names(root.appending(path: "Agent")) == ["file"])
    }
  }

  @Test func anAgedSweepRemovesOnlyOldFiles() {
    withTestFolder { root in
      touch(root.appending(path: "Drags/old"), age: 7200)
      touch(root.appending(path: "Drags/new"))
      TemporaryFiles.sweep([.drags], in: root, olderThan: 3600)
      #expect(names(root.appending(path: "Drags")) == ["new"])
    }
  }

  @Test func sweepingAMissingAreaIsFine() {
    withTestFolder { root in TemporaryFiles.sweep(TemporaryFiles.Area.allCases, in: root) }
  }

  @Test func onlyOldEngineFoldersGo() throws {
    try withTestFolder { temporary in
      func folder(_ name: String, files: [String], age: TimeInterval) throws {
        let url = temporary.appending(path: name)
        for file in files { touch(url.appending(path: file)) }
        if age > 0 {
          try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
      }
      let old = UUID().uuidString, oldWithLog = UUID().uuidString, recent = UUID().uuidString
      let otherApp = UUID().uuidString, empty = UUID().uuidString
      try folder(old, files: ["config.sqlite3"], age: 7200)
      try folder(oldWithLog, files: ["config.sqlite3", "config.sqlite3-wal", "config.sqlite3-shm"], age: 7200)
      try folder(recent, files: ["config.sqlite3"], age: 0)
      try folder(otherApp, files: ["config.sqlite3", "data.bin"], age: 7200)
      try folder("NotAUUID", files: ["config.sqlite3"], age: 7200)
      try FileManager.default.createDirectory(
        at: temporary.appending(path: empty), withIntermediateDirectories: true)
      TemporaryFiles.removeEngineFolders(in: temporary, olderThan: 3600)
      #expect(names(temporary) == [recent, otherApp, "NotAUUID", empty])
    }
  }
}

struct ClipCacheTests {
  @Test func pruningKeepsTheCurrentCodecOfExistingProjects() {
    withTestFolder { clips in
      for name in [
        "My-Project-1-2-h264.mp4", "My-Project-1-2-hevc.mp4", "Gone-1-2-h264.mp4",
        "My-Project-3-4-h264.partial.mp4", "notes.txt", "odd-name.mp4",
      ] {
        touch(clips.appending(path: name))
      }
      HistoryStore.pruneClipCache(in: clips, projects: ["My-Project"], codec: .h264)
      #expect(names(clips) == ["My-Project-1-2-h264.mp4", "notes.txt", "odd-name.mp4"])
    }
  }

  @Test func deletingAClipRemovesItsFilesInEveryCodecOnly() {
    withTestFolder { clips in
      for name in ["P-1-2-h264.mp4", "P-1-2-hevc.mp4", "P-1-3-h264.mp4", "Q-1-2-h264.mp4"] {
        touch(clips.appending(path: name))
      }
      HistoryStore.removeClipFiles(in: clips, project: "P", clipId: 1, tensorId: 2)
      #expect(names(clips) == ["P-1-3-h264.mp4", "Q-1-2-h264.mp4"])
    }
  }
}

struct OrphanTests {
  @Test func aFailedImportRemovesOnlyTheFilesItMade() {
    withTestFolder { models in
      touch(models.appending(path: "foo_bar_f16.ckpt"))
      touch(models.appending(path: "other_f16.ckpt"))
      let before = names(models)
      for file in ["foo_f16.ckpt", "foo_clip_vit_l14_f16.ckpt", "foo_f16.ckpt-wal", "elsewhere_f16.ckpt"] {
        touch(models.appending(path: file))
      }
      ModelLibrary.removeNewFiles(in: models, before: before, prefix: "foo_")
      #expect(names(models) == before.union(["elsewhere_f16.ckpt"]))
    }
  }

  @MainActor @Test func moodboardImagesNotOnTheBoardGo() {
    withTestFolder { folder in
      let kept = UUID(), orphan = UUID()
      for name in ["\(kept).png", "\(orphan).png", "index.json", "picture.png"] {
        touch(folder.appending(path: name))
      }
      Moodboard.removeOrphans(in: folder, keeping: [kept])
      #expect(names(folder) == ["\(kept).png", "index.json", "picture.png"])
    }
  }

  @MainActor @Test func thumbnailsOfGoneStylesGo() {
    withTestFolder { folder in
      let kept = UUID().uuidString, orphan = UUID().uuidString
      for id in [kept, orphan] {
        for suffix in [".jpg", "-full.png", ".json"] { touch(folder.appending(path: id + suffix)) }
      }
      touch(folder.appending(path: "other.jpg"))
      StyleStore.removeOrphanedThumbnails(in: folder, keeping: [UUID(uuidString: kept)!])
      #expect(names(folder) == [kept + ".jpg", kept + "-full.png", kept + ".json", "other.jpg"])
    }
  }
}

struct ModelFolderTests {
  func folders(_ root: URL) -> (a: String, b: String, c: String) {
    let paths = ["a", "b", "c"].map { root.appending(path: $0).path }
    for path in paths {
      try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    return (paths[0], paths[1], paths[2])
  }

  @Test func theOrderIsPrimaryThenAdditional() {
    withTestFolder { root in
      let (a, b, c) = folders(root)
      #expect(AppSettings.availableModelsDirectories(primary: b, additional: [c, a]) == [b, c, a])
    }
  }

  @Test func theSameFolderCountsOnceHoweverItIsWritten() {
    withTestFolder { root in
      let (a, b, _) = folders(root)
      let result = AppSettings.availableModelsDirectories(
        primary: a, additional: [a + "/", b, a + "/../a", b])
      #expect(result == [a, b])
    }
  }

  @Test func folderThatCantBeReachedAreLeftOut() {
    withTestFolder { root in
      let (a, b, _) = folders(root)
      let missing = root.appending(path: "missing").path
      #expect(AppSettings.availableModelsDirectories(primary: missing, additional: [a, missing, "", b]) == [a, b])
    }
  }

  @Test func aFileIsNotAFolder() {
    withTestFolder { root in
      let (a, _, _) = folders(root)
      let file = root.appending(path: "file")
      touch(file)
      #expect(AppSettings.availableModelsDirectories(primary: a, additional: [file.path]) == [a])
    }
  }
}
