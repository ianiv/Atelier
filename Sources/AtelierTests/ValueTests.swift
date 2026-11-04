@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// A step with what a test cares about; the rest filled in.
func makeItem(
  _ tensorId: Int64, prompt: String = "a prompt", clip: ClipInfo? = nil, width: Int = 512, height: Int = 512
) -> HistoryItem {
  HistoryItem(
    id: StepID(lineage: 0, logicalTime: tensorId), tensorId: tensorId, previewId: tensorId,
    sidecar: HistoryStore.Sidecar(
      createdAt: Date(timeIntervalSince1970: 0), durationSeconds: 1, prompt: prompt, negativePrompt: "",
      model: "model.ckpt", seed: 1, width: width, height: height, steps: 2, guidanceScale: 1, shift: 1,
      sampler: "eulerA", resolutionDependentShift: false, hiresFix: false, configuration: [:]),
    clip: clip)
}

/// A folder only this test uses, removed afterwards.
func withTestFolder(_ body: (URL) throws -> Void) rethrows {
  let folder = FileManager.default.temporaryDirectory
    .appending(path: "atelier-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  try body(folder)
}

func touch(_ url: URL, age: TimeInterval = 0) {
  try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
  if age > 0 {
    try? FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
  }
}

func names(_ url: URL) -> Set<String> {
  Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
}

func smallImage() -> CGImage {
  let context = CGContext(
    data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
  return context.makeImage()!
}

struct HostTests {
  /// The tests run inside the app: this is what keeps it off the user's data at launch.
  @Test func theHostLaunchesAsAScriptedRun() {
    #expect(Automation.isRequested)
    #expect(!SessionState.isEnabled)
  }
}

struct JSONValueTests {
  @Test func codableRoundTrip() throws {
    let value = JSONValue.object([
      "null": .null, "bool": .bool(true), "number": .number(1.5), "string": .string("text"),
      "array": .array([.number(1), .string("two")]), "object": .object(["nested": .bool(false)]),
    ])
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
  }

  @Test func aFloatKeepsItsShortDecimal() {
    #expect(JSONValue(Float(0.1)) == .number(0.1))
  }

  @Test func anEmptyOptionalIsNull() {
    let missing: Int? = nil
    #expect(JSONValue(missing as Any) == .null)
  }

  @Test func fieldsReadAStructsProperties() {
    struct Example {
      var name = "x"
      var count = 2
      var flag = true
    }
    #expect(
      JSONValue.fields(of: Example())
        == ["name": .string("x"), "count": .number(2), "flag": .bool(true)])
  }
}

struct PNGTextTests {
  @Test func textReadsBackWhatWasInserted() throws {
    let png = try #require(ImageTensor.png(smallImage()))
    let tagged = try #require(PNGText.inserting(keyword: "Atelier", text: "héllo {\"a\":1}", into: png))
    #expect(PNGText.text(keyword: "Atelier", in: tagged) == "héllo {\"a\":1}")
    #expect(PNGText.text(keyword: "Other", in: tagged) == nil)
  }

  @Test func theTaggedFileIsStillAnImage() throws {
    let png = try #require(ImageTensor.png(smallImage()))
    let tagged = try #require(PNGText.inserting(keyword: "Atelier", text: "x", into: png))
    let image = try #require(ImageLoader.image(from: tagged))
    #expect(image.width == 4)
  }

  @Test func somethingThatIsNotAPNGIsRefused() {
    #expect(PNGText.inserting(keyword: "Atelier", text: "x", into: Data([1, 2, 3])) == nil)
  }
}

struct SizePresetTests {
  @Test func snappingGoesToMultiplesOf64AndNeverBelow() {
    #expect(SizePreset.snap(1000) == 1024)
    #expect(SizePreset.snap(1) == 64)
    #expect(SizePreset.snap(1023.0) == 1024)
  }

  @Test func oneMegapixelSquareIs1024() {
    let square = SizePreset.AspectRatio(width: 1, height: 1)
    let size = SizePreset.size(aspect: square, megapixels: 1)
    #expect(size.width == 1024 && size.height == 1024)
  }

  @Test(arguments: SizePreset.aspectRatios)
  func everyPresetIsMatchedBack(aspect: SizePreset.AspectRatio) throws {
    for megapixels in SizePreset.megapixels {
      let size = SizePreset.size(aspect: aspect, megapixels: megapixels)
      let match = try #require(SizePreset.match(width: size.width, height: size.height))
      // Another preset can round to the same size; what comes back must give that size.
      let back = SizePreset.size(aspect: match.0, megapixels: match.1)
      #expect(back == size)
    }
  }

  @Test func aSizeNoPresetMakesHasNoMatch() {
    #expect(SizePreset.match(width: 100, height: 3000) == nil)
  }
}

struct ClipTests {
  let clip = ClipInfo(clipId: 1, frames: [10, 11, 12, 13], framesPerSecond: 2, previewOffset: 100)

  @Test func durationAndPreviewIds() {
    #expect(clip.duration == 2)
    #expect(clip.previewId(1) == 111)
  }

  @Test func noFrameRateMeansNoDuration() {
    #expect(ClipInfo(clipId: 1, frames: [1], framesPerSecond: 0).duration == 0)
  }

  @Test func itemsAreTheSameByImageNotByStep() {
    var moved = makeItem(5)
    moved.id = StepID(lineage: 9, logicalTime: 9)
    #expect(moved == makeItem(5))
    #expect(moved.hashValue == makeItem(5).hashValue)
    #expect(makeItem(5) != makeItem(6))
  }

  @Test func accessibilityDescriptionShortensThePrompt() {
    #expect(makeItem(1, prompt: " a cat ").accessibilityDescription == "Image: a cat")
    #expect(makeItem(1, prompt: "").accessibilityDescription == "Image")
    #expect(makeItem(1, prompt: "", clip: clip).accessibilityDescription == "Video")
    let long = makeItem(1, prompt: String(repeating: "x", count: 200)).accessibilityDescription
    #expect(long == "Image: " + String(repeating: "x", count: 80) + "…")
  }

  @Test func systemUpscaleMultipliesTheSize() {
    let size = ClipUpscale.outputSize(width: 640, height: 360, scale: 4, method: .system)
    #expect(size.width == 2560 && size.height == 1440)
  }
}

struct TimelineLayoutTests {
  /// Clips 1 and 2: 48 frames at 24 fps. Clip 3 is gone.
  func item(_ id: Int64) -> HistoryItem? {
    guard id == 1 || id == 2 else { return nil }
    return makeItem(id, clip: ClipInfo(clipId: id, frames: Array(0..<48).map { id * 100 + $0 }, framesPerSecond: 24))
  }

  func timeline(_ entries: [Timeline.Entry]) -> Timeline {
    var timeline = Timeline(name: "T")
    timeline.entries = entries
    return timeline
  }

  @Test func entriesFollowOneAnother() {
    let layout = TimelineLayout(
      timeline([.init(clip: 1, start: 0, end: 24), .init(clip: 2, start: 0, end: 48)]), item: item)
    #expect(layout.segments.map(\.start) == [0, 1])
    #expect(layout.duration == 3)
    #expect(layout.framesPerSecond == 24)
  }

  @Test func aGoneClipOrBadRangeIsLeftOut() {
    let layout = TimelineLayout(
      timeline([
        .init(clip: 3, start: 0, end: 24), .init(clip: 1, start: 0, end: 99), .init(clip: 2, start: 5, end: 5),
        .init(clip: 2, start: 0, end: 24),
      ]), item: item)
    #expect(layout.segments.map(\.entry.clip) == [2])
  }

  @Test func aCrossfadeOverlapsAndIsCappedAtHalfTheShorterClip() {
    var first = Timeline.Entry(clip: 1, start: 0, end: 48)
    first.crossfadeFrames = 12
    let layout = TimelineLayout(timeline([first, .init(clip: 2, start: 0, end: 48)]), item: item)
    #expect(layout.segments[0].fade == 0.5)
    #expect(layout.segments[1].start == 1.5)
    #expect(layout.duration == 3.5)

    var long = Timeline.Entry(clip: 1, start: 0, end: 48)
    long.crossfadeFrames = 1000
    let capped = TimelineLayout(timeline([long, .init(clip: 2, start: 0, end: 12)]), item: item)
    #expect(capped.segments[0].fade == 0.25)
  }

  @Test func aTimeFindsItsSegmentAndFrame() throws {
    let layout = TimelineLayout(
      timeline([.init(clip: 1, start: 10, end: 34), .init(clip: 2, start: 0, end: 24)]), item: item)
    let first = try #require(layout.locate(0.5))
    #expect(first.index == 0 && first.frame == 22)
    let second = try #require(layout.locate(1.5))
    #expect(second.index == 1 && second.frame == 12)
    let past = try #require(layout.locate(100))
    #expect(past.index == 1 && past.frame == 23)
    #expect(layout.time(ofFrame: 22, inSegment: 0) == 0.5)
  }

  @Test func anEmptyTimelineLocatesNothing() {
    #expect(TimelineLayout(timeline([]), item: item).locate(0) == nil)
  }
}
