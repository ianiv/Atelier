@testable import Atelier
import Foundation
import Synchronization
import Testing

struct ShareTests {
  @Test func aCanvasImageThatIsNoStepSharesAsAPlainPNGNamedAsGiven() async throws {
    let export = PNGExport.image(smallImage(), name: "My Project")
    #expect(export.name == "My Project")
    #expect(export.video == nil)
    let png = try await export.data()
    let image = try #require(ImageLoader.image(from: png))
    #expect(image.width == 4 && image.height == 4)
    #expect(PNGText.text(keyword: "Atelier", in: png) == nil)
  }

  @Test @MainActor func aStepsPNGCarriesItsSettingsUnlessTurnedOff() throws {
    let item = makeItem(7, prompt: "a shared prompt")
    let png = try HistoryStore.pngData(smallImage(), sidecar: item.sidecar)
    let text = PNGText.text(keyword: "Atelier", in: png)
    if AppSettings.embedsSettings {
      #expect(text?.contains("a shared prompt") == true)
    } else {
      #expect(text == nil)
    }
  }

  @Test func sharingAClipWritesNoVideoUntilAsked() {
    let calls = Mutex(0)
    var export = PNGExport(id: 1, name: "Clip") { Data() }
    export.video = {
      calls.withLock { $0 += 1 }
      return URL(filePath: "/nonexistent.mp4")
    }
    let shared = ShareItem(exports: [export]).exports.map(\.shared)
    #expect(shared.count == 1)
    #expect(shared[0].isShared && shared[0].video != nil && shared[0].name == "Clip")
    #expect(!export.isShared)
    #expect(calls.withLock { $0 } == 0)
  }

  @Test func sharedFilesOutlastDraggedOnes() {
    #expect(TemporaryFiles.shareLifetime >= 24 * 60 * 60)
    withTestFolder { root in
      touch(root.appending(path: "Shares/recent"), age: 2 * 60 * 60)
      touch(root.appending(path: "Shares/old"), age: 2 * TemporaryFiles.shareLifetime)
      TemporaryFiles.sweep([.shares], in: root, olderThan: TemporaryFiles.shareLifetime)
      #expect(names(root.appending(path: "Shares")) == ["recent"])
    }
  }

  @Test func aRelaunchKeepsRecentSharesAndEmptiesTheOtherAreas() {
    withTestFolder { root in
      touch(root.appending(path: "Shares/recent"), age: 2 * 60 * 60)
      touch(root.appending(path: "Shares/old"), age: 2 * TemporaryFiles.shareLifetime)
      touch(root.appending(path: "Drags/recent"))
      touch(root.appending(path: "Exports/recent"))
      TemporaryFiles.sweepAreasAtLaunch(in: root)
      #expect(names(root.appending(path: "Shares")) == ["recent"])
      #expect(names(root.appending(path: "Drags")).isEmpty)
      #expect(names(root.appending(path: "Exports")).isEmpty)
    }
  }
}
