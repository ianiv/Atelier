@testable import Atelier
import Foundation
import Synchronization
import Testing

@Suite(.tags(.smoke))
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

#if os(macOS)
  import AppKit
  import UniformTypeIdentifiers

  @MainActor
  @Suite(.tags(.smoke))
  struct SharePickerTests {
    @Test func anImageProviderOffersAPNGAndAClipsAnMP4() {
      var clip = PNGExport(id: 2, name: "Clip") { Data() }
      clip.video = { URL(filePath: "/nonexistent.mp4") }
      let providers = SharePicker.providers([PNGExport.image(smallImage(), name: "Image"), clip])
      #expect(providers[0].registeredContentTypes.contains(.png))
      #expect(!providers[0].registeredContentTypes.contains(.mpeg4Movie))
      #expect(providers[1].registeredContentTypes.contains(.mpeg4Movie))
      #expect(providers[0].suggestedName == "Image")
    }

    /// What the provider hands a share target asking for a file of `type`: its name and contents.
    private func load(_ provider: NSItemProvider, _ type: UTType) async throws -> (name: String, data: Data) {
      try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
          if let url, let data = try? Data(contentsOf: url) {
            continuation.resume(returning: (url.lastPathComponent, data))
          } else {
            continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
          }
        }
      }
    }

    @Test func anImageLoadsAsAPNGUnderItsName() async throws {
      let name = "share-test-\(UUID().uuidString)"
      let provider = try #require(SharePicker.providers([PNGExport.image(smallImage(), name: name).shared]).first)
      let loaded = try await load(provider, .png)
      #expect(loaded.name == name + ".png")
      #expect(ImageLoader.image(from: loaded.data)?.width == 4)
    }

    @Test func aClipLoadsAsItsMP4WrittenIntoShares() async throws {
      try await withTestFolderAsync { folder in
        let video = folder.appending(path: "clip.mp4")
        try Data("not really a movie".utf8).write(to: video)
        let name = "share-test-\(UUID().uuidString)"
        var clip = PNGExport(id: 3, name: name) { Data() }
        clip.video = { video }
        let shares = TemporaryFiles.folder(.shares)
        let before = names(shares)
        let provider = try #require(SharePicker.providers([clip.shared]).first)
        let loaded = try await load(provider, .mpeg4Movie)
        #expect(loaded.name == name + ".mp4")
        #expect(loaded.data == Data("not really a movie".utf8))
        let added = names(shares).subtracting(before)
        #expect(added.count == 1)
        for item in added { try? FileManager.default.removeItem(at: shares.appending(path: item)) }
      }
    }

    private func withTestFolderAsync(_ body: (URL) async throws -> Void) async throws {
      let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-tests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      try await body(folder)
    }

    @Test func anAnchorDropsOutWhenItsViewGoes() throws {
      let id = AnyHashable(ShareAnchor.historyCell(-42))
      var view: NSView? = NSView()
      ShareAnchors.register(try #require(view), for: id)
      #expect(ShareAnchors.view(for: id) === view)
      view = nil
      #expect(ShareAnchors.view(for: id) == nil)
    }

    @Test func removingAnOldViewKeepsTheNewOne() {
      let id = AnyHashable(ShareAnchor.queueJob(UUID()))
      let old = NSView(), new = NSView()
      ShareAnchors.register(old, for: id)
      ShareAnchors.register(new, for: id)
      ShareAnchors.remove(old, for: id)
      #expect(ShareAnchors.view(for: id) === new)
    }
  }
#endif
