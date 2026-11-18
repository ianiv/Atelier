@testable import Atelier
import CoreGraphics
import Foundation
import Synchronization
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

@Suite(.tags(.smoke))
struct HostTests {
  /// The tests run inside the app: this is what keeps it off the user's data at launch.
  @Test func theHostLaunchesAsAScriptedRun() {
    #expect(Automation.isRequested)
    #expect(!SessionState.isEnabled)
  }
}

@Suite(.tags(.smoke))
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

@Suite(.tags(.smoke))
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

@Suite(.tags(.smoke))
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

  /// MiniMax H3 Image's presets go to 24 megapixels, in multiples of 64, and never pass its
  /// 6400 px side: wide shapes there stop at the limit, keeping their aspect.
  @Test func largePresetsStayWithinTheSideLimit() {
    for aspect in SizePreset.aspectRatios {
      for megapixels in SizePreset.largeMegapixels {
        let size = SizePreset.size(aspect: aspect, megapixels: megapixels, maxSide: SizePreset.largeMaxSide)
        #expect(size.width <= 6400 && size.height <= 6400)
        #expect(size.width % 64 == 0 && size.height % 64 == 0)
      }
    }
    let square = SizePreset.size(aspect: .init(width: 1, height: 1), megapixels: 20, maxSide: SizePreset.largeMaxSide)
    #expect(Double(square.width * square.height) / 1_048_576 > 19)
    let wide = SizePreset.size(aspect: .init(width: 21, height: 9), megapixels: 24, maxSide: SizePreset.largeMaxSide)
    #expect(wide.width == 6400)
  }

  @Test func lockedSixteenByNineRoundTrips() throws {
    let size = SizePreset.size(aspect: .init(width: 16, height: 9), megapixels: 1)
    let ratio = try #require(SizePreset.lockRatio(width: size.width, height: size.height))
    #expect(ratio == 16.0 / 9)
    #expect(SizePreset.fits(width: size.width, height: size.height, ratio: ratio))
    let wider = SizePreset.locked(width: 1920, ratio: ratio, maxSide: SizePreset.maxSide)
    #expect(wider == (1920, 1088))
    let back = SizePreset.locked(height: size.height, ratio: ratio, maxSide: SizePreset.maxSide)
    #expect(back == size)
  }

  @Test(arguments: [SizePreset.maxSide, SizePreset.largeMaxSide])
  func lockedSizesStopAtTheLongestSide(maxSide: Int) {
    let ratio = 16.0 / 9
    let typedWidth = SizePreset.locked(width: maxSide * 2, ratio: ratio, maxSide: maxSide)
    #expect(typedWidth.width == maxSide)
    #expect(typedWidth.height == SizePreset.snap(Double(maxSide) / ratio))
    // A tall height asks for a width past the limit; the width stops there and the height follows.
    let typedHeight = SizePreset.locked(height: maxSide, ratio: ratio, maxSide: maxSide)
    #expect(typedHeight == typedWidth)
    let portrait = SizePreset.locked(width: maxSide, ratio: 9.0 / 16, maxSide: maxSide)
    #expect(portrait.height == maxSide)
    #expect(portrait.width == SizePreset.snap(Double(maxSide) * 9 / 16))
  }

  @Test func lockedSizesKeepTheFloorOf64() {
    let ratio = 21.0 / 9
    // A width of 64 would need a height under 64, so the height stays at 64 and the width follows.
    #expect(SizePreset.locked(width: 64, ratio: ratio, maxSide: 4096) == (SizePreset.snap(64 * ratio), 64))
    #expect(SizePreset.locked(height: 1, ratio: ratio, maxSide: 4096) == (SizePreset.snap(64 * ratio), 64))
    #expect(SizePreset.locked(width: 0, ratio: 1, maxSide: 4096) == (64, 64))
  }

  @Test func repeatedLockedCommitsDontDrift() {
    for ratio in [16.0 / 9, 4.0 / 3, 21.0 / 9, 1.37] {
      var size = SizePreset.locked(width: 1024, ratio: ratio, maxSide: 4096)
      for _ in 0..<20 {
        size = SizePreset.locked(height: size.height, ratio: ratio, maxSide: 4096)
        size = SizePreset.locked(width: size.width, ratio: ratio, maxSide: 4096)
      }
      // Sides on the 64 grid can't always meet the ratio exactly; they stay within a step of it.
      #expect(abs(Double(size.width) / ratio - Double(size.height)) <= 32)
      #expect(size.width >= 960 && size.width <= 1088)
      #expect(SizePreset.fits(width: size.width, height: size.height, ratio: ratio))
    }
  }

  @Test func aLockedRatioKeepsItsMegapixels() {
    let size = SizePreset.size(ratio: 16.0 / 9, megapixels: 1)
    #expect(size == SizePreset.size(aspect: .init(width: 16, height: 9), megapixels: 1))
  }

  /// A Megapixels choice while locked makes a size that still fits the ratio, so reopening the
  /// popover keeps it rather than locking afresh (1408 × 1024 at 0.5 MP once made 832 × 640, which
  /// relocked at 4:3).
  @Test func lockedMegapixelsFitTheRatio() {
    let cases: [(ratios: [Double], megapixels: [Double], maxSide: Int)] = [
      ([1.375, 16.0 / 9, 4.0 / 3, 21.0 / 9, 1.37, 1, 0.73, 9.0 / 16, 2.0 / 3, 9.0 / 21],
       SizePreset.megapixels, SizePreset.maxSide),
      ([1.375, 16.0 / 9, 21.0 / 9, 0.73, 9.0 / 21], SizePreset.largeMegapixels, SizePreset.largeMaxSide),
    ]
    for (ratios, megapixels, maxSide) in cases {
      for ratio in ratios {
        for mp in megapixels {
          let size = SizePreset.locked(ratio: ratio, megapixels: mp, maxSide: maxSide)
          #expect(
            SizePreset.fits(width: size.width, height: size.height, ratio: ratio, megapixels: megapixels, maxSide: maxSide),
            "\(ratio) at \(mp) MP: \(size)")
          #expect(size.width <= maxSide && size.height <= maxSide)
          #expect(size.width % 64 == 0 && size.height % 64 == 0)
        }
      }
    }
  }

  /// A Megapixels choice while locked to a preset's ratio gives that preset's size, not one with
  /// the shorter side rederived (3:2 at 2 MP is 1792 × 1152, not 1792 × 1216), and it fits, so the
  /// picker still shows it and reopening the popover keeps the lock. The swapped lock's `1 / ratio`
  /// counts as the portrait preset's ratio too.
  @Test func lockedMegapixelsAtAPresetRatioIsThePreset() {
    let cases: [(megapixels: [Double], maxSide: Int)] = [
      (SizePreset.megapixels, SizePreset.maxSide), (SizePreset.largeMegapixels, SizePreset.largeMaxSide),
    ]
    for (megapixels, maxSide) in cases {
      for aspect in SizePreset.aspectRatios {
        for ratio in [aspect.ratio, 1 / (Double(aspect.height) / Double(aspect.width))] {
          for mp in megapixels {
            let preset = SizePreset.size(aspect: aspect, megapixels: mp, maxSide: maxSide)
            let size = SizePreset.locked(ratio: ratio, megapixels: mp, maxSide: maxSide)
            #expect(size == preset, "\(aspect.label) at \(mp) MP: \(size)")
            #expect(
              SizePreset.fits(width: size.width, height: size.height, ratio: ratio, megapixels: megapixels, maxSide: maxSide),
              "\(aspect.label) at \(mp) MP: \(size)")
          }
        }
      }
    }
  }

  /// Committing a locked side's own result again changes nothing, for every side on the grid, so
  /// a second commit as the popover closes makes no second undo step (21:9 at 4096: H 1760 made
  /// 4096 × 1728, and H 1728 then made 4032 × 1728).
  @Test(arguments: [1024, 2048, SizePreset.maxSide, SizePreset.largeMaxSide])
  func lockedSidesAreIdempotent(maxSide: Int) {
    let ratios = SizePreset.aspectRatios.map(\.ratio) + [1.37, 0.73, 1.375, 2.5, 0.4, 7.3, 0.13]
    for ratio in ratios {
      for side in stride(from: 64, through: maxSide, by: 64) {
        let byWidth = SizePreset.locked(width: side, ratio: ratio, maxSide: maxSide)
        #expect(SizePreset.locked(width: byWidth.width, ratio: ratio, maxSide: maxSide) == byWidth, "W \(side) at \(ratio): \(byWidth)")
        let byHeight = SizePreset.locked(height: side, ratio: ratio, maxSide: maxSide)
        #expect(SizePreset.locked(height: byHeight.height, ratio: ratio, maxSide: maxSide) == byHeight, "H \(side) at \(ratio): \(byHeight)")
        #expect(byWidth.width <= maxSide && byWidth.height <= maxSide && byHeight.width <= maxSide && byHeight.height <= maxSide)
      }
    }
  }

  /// A size with a zero side has no ratio to lock, and a stored bad ratio never fits.
  @Test func unusableRatiosAreNil() {
    #expect(SizePreset.lockRatio(width: 0, height: 0) == nil)
    #expect(SizePreset.lockRatio(width: 1024, height: 0) == nil)
    #expect(SizePreset.lockRatio(width: 0, height: 1024) == nil)
    #expect(SizePreset.validRatio(.nan) == nil)
    #expect(SizePreset.validRatio(.infinity) == nil)
    #expect(SizePreset.validRatio(-1) == nil)
    #expect(SizePreset.validRatio(1.5) == 1.5)
    #expect(!SizePreset.fits(width: 1024, height: 1024, ratio: 0))
    #expect(!SizePreset.fits(width: 1024, height: 1024, ratio: .nan))
  }

  /// A wide preset capped at the side limit still locks to its preset's exact ratio.
  @Test func cappedLargePresetsLockToTheirRatio() {
    let wide = SizePreset.AspectRatio(width: 21, height: 9)
    for megapixels in [20.0, 24] {
      let size = SizePreset.size(aspect: wide, megapixels: megapixels, maxSide: SizePreset.largeMaxSide)
      let ratio = SizePreset.lockRatio(
        width: size.width, height: size.height, megapixels: SizePreset.largeMegapixels,
        maxSide: SizePreset.largeMaxSide)
      #expect(ratio == wide.ratio)
    }
  }
}

@Suite(.tags(.smoke))
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

@Suite(.tags(.smoke))
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

/// Step previews decode off the engine's queue: a slow decode skips previews instead of queuing
/// them, and nothing is delivered once the run has ended.
struct PreviewDecoderTests {
  @Test func aSlowDecodeKeepsOnlyTheNewestPreviewAndNothingAfterClose() async throws {
    let decoder = PreviewDecoder()
    let ran = Mutex<[Int]>([])
    let delivered = Mutex<[Int]>([])
    let gate = DispatchSemaphore(value: 0)
    func preview(_ n: Int, waits: Bool = false) {
      decoder.submit {
        if waits { gate.wait() }
        ran.withLock { $0.append(n) }
        decoder.deliver { delivered.withLock { $0.append(n) } }
      }
    }
    preview(1, waits: true)
    try await Task.sleep(for: .milliseconds(50))
    for n in 2...5 { preview(n) }
    gate.signal()
    try await Task.sleep(for: .milliseconds(200))
    #expect(ran.withLock { $0 } == [1, 5])
    decoder.close()
    preview(6)
    try await Task.sleep(for: .milliseconds(100))
    #expect(delivered.withLock { $0 } == [1, 5])
  }
}
