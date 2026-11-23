@testable import Atelier
import AVFoundation
import CoreGraphics
import Foundation
import Testing

/// Writes a short H.264 movie whose frame `i` is a flat gray of level `level(i)`, so a decoded
/// frame says which one it is. `transform` turns it as a phone's video is turned.
func writeTestMovie(
  to url: URL, width: Int = 64, height: Int = 32, frames: Int, framesPerSecond: Int32,
  transform: CGAffineTransform = .identity, level: (Int) -> UInt8 = { UInt8(clamping: $0 * 8) }
) async throws {
  try? FileManager.default.removeItem(at: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
  input.transform = transform
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ])
  writer.add(input)
  #expect(writer.startWriting())
  writer.startSession(atSourceTime: .zero)
  for index in 0..<frames {
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(pixels)
    let value = level(index)
    for y in 0..<height {
      for x in 0..<width {
        let pixel = base + y * row + x * 4
        pixel[0] = value
        pixel[1] = value
        pixel[2] = value
        pixel[3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: framesPerSecond)))
  }
  input.markAsFinished()
  await writer.finishWriting()
  #expect(writer.status == .completed)
}

/// A folder only this test uses, removed afterwards.
func withMediaFolder(_ body: (URL) async throws -> Void) async throws {
  let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-media-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  try await body(folder)
}

/// The gray level at the center of `image`.
func centerLevel(_ image: CGImage) -> Int {
  var pixel = [UInt8](repeating: 0, count: 4)
  let context = CGContext(
    data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
  return Int(pixel[1])
}

@Suite(.tags(.smoke))
struct MediaTests {
  @Test func aProfileKeepsItsMediaRecord() {
    let record = Media.Record(
      file: "\(UUID().uuidString).mov", bytes: 1234, name: "Beach", width: 640, height: 360, framesPerSecond: 30, frameCount: 360,
      duration: 12, hasAudio: true)
    let profile = ProjectMapping.Profile(duration: 0, inputTensorId: nil, parentTensorId: 0, media: record)
    #expect(ProjectMapping.Profile(profile.bytes)?.media == record)
    // A profile written before media, or by Draw Things, has none.
    let older = ProjectMapping.Profile(duration: 0, inputTensorId: nil, parentTensorId: 0)
    #expect(ProjectMapping.Profile(older.bytes)?.media == nil)
  }

  @Test func onlyNamesThisAppWritesAreFiles() {
    #expect(Media.isSafeFileName("\(UUID().uuidString).mov"))
    #expect(Media.isSafeFileName("\(UUID().uuidString).mp4"))
    #expect(!Media.isSafeFileName("../\(UUID().uuidString).mov"))
    #expect(!Media.isSafeFileName("\(UUID().uuidString).mov/x"))
    #expect(!Media.isSafeFileName("clip.mov"))
    #expect(!Media.isSafeFileName("\(UUID().uuidString)"))
    #expect(!Media.isSafeFileName("\(UUID().uuidString)..mov"))
    let record = Media.Record(file: "../../etc/passwd", bytes: 0, name: "", width: 1, height: 1, framesPerSecond: 1, frameCount: 1, duration: 1, hasAudio: false)
    #expect(Media.url(of: record, inProject: URL(fileURLWithPath: "/tmp/P.sqlite3")) == nil)
  }

  @Test func theMediaFolderSitsBesideTheProject() {
    #expect(Media.folder(forProject: URL(fileURLWithPath: "/a/My Project.sqlite3")).path == "/a/My Project.sqlite3-media")
  }

  @Test func orphansAreWhatNoStepNamesAndHalfCopies() {
    let kept = "\(UUID().uuidString).mov", gone = "\(UUID().uuidString).mov", copying = "\(UUID().uuidString).mp4"
    let files = [kept, gone, copying + ".partial", gone + ".partial", ".DS_Store", copying]
    let orphans = Media.orphans(files: files, referenced: [kept], inFlight: [copying])
    #expect(Set(orphans) == [gone, gone + ".partial"])
  }

  @Test func aMovieIsInspectedUpright() async throws {
    try await withMediaFolder { folder in
      let url = folder.appending(path: "turned.mov")
      // Turned a quarter, as a phone held upright records.
      try await writeTestMovie(to: url, width: 64, height: 32, frames: 15, framesPerSecond: 30, transform: CGAffineTransform(rotationAngle: .pi / 2))
      let inspected = try await Media.inspect(url)
      #expect(inspected.width == 32 && inspected.height == 64)
      #expect(abs(inspected.framesPerSecond - 30) < 0.5)
      #expect(inspected.frameCount == 15)
      #expect(!inspected.hasAudio)
      let first = try await Media.frame(0, of: url, framesPerSecond: inspected.framesPerSecond)
      #expect(first.width == 32 && first.height == 64)
    }
  }

  @Test func whatIsntAVideoIsRefused() async throws {
    try await withMediaFolder { folder in
      let url = folder.appending(path: "not.mov")
      try Data("not a movie".utf8).write(to: url)
      await #expect(throws: Media.Failure.self) { try await Media.inspect(url) }
    }
  }
}

/// An imported video's frames as H3 Ref2VA takes them (`ReferenceVideo.fileFrames`), the way the
/// engine CLI's `loadInputVideoTensor` reads `--video`.
@Suite(.tags(.smoke))
struct MediaReferenceTests {
  @Test func framesAreReadAt24FromA30FrameVideo() async throws {
    try await withMediaFolder { folder in
      let url = folder.appending(path: "thirty.mov")
      try await writeTestMovie(to: url, frames: 36, framesPerSecond: 30)
      let frames = try await ReferenceVideo.fileFrames(url: url, count: 22, rate: 24, width: 32, height: 32)
      #expect(frames.count == 22)
      #expect(frames.allSatisfy { $0.width == 32 && $0.height == 32 })
      // Frame i is at i/24 s, which shows source frame floor(i × 30 / 24): the same gray as that
      // frame decoded on its own (the codec's range conversion shifts levels a little).
      var expected: [Int] = []
      for index in 0..<22 {
        expected.append(centerLevel(try await Media.frame(index * 30 / 24, of: url, framesPerSecond: 30)))
      }
      let levels = frames.map(centerLevel)
      #expect(zip(levels, expected).allSatisfy { abs($0 - $1) <= 1 }, "levels \(levels), expected \(expected)")
      // And they're distinct frames, not one held.
      #expect(Set(levels).count >= 15)
    }
  }

  @Test func aShortVideoHoldsItsLastFrame() async throws {
    try await withMediaFolder { folder in
      let url = folder.appending(path: "short.mov")
      // Half a second at 24 fps: 12 frames.
      try await writeTestMovie(to: url, frames: 12, framesPerSecond: 24)
      let frames = try await ReferenceVideo.fileFrames(url: url, count: 22, rate: 24, width: 16, height: 16)
      #expect(frames.count == 22)
      let levels = frames.map(centerLevel)
      let last = centerLevel(try await Media.frame(11, of: url, framesPerSecond: 24))
      #expect(abs(levels[11] - last) <= 1)
      #expect(levels[10] != levels[11])
      #expect(levels[12...].allSatisfy { abs($0 - last) <= 1 }, "levels \(levels)")
    }
  }

  @Test func aFileThatIsntAVideoGivesNoFrames() async throws {
    try await withMediaFolder { folder in
      let url = folder.appending(path: "broken.mov")
      try Data("nope".utf8).write(to: url)
      await #expect(throws: (any Error).self) {
        try await ReferenceVideo.fileFrames(url: url, count: 22, rate: 24, width: 16, height: 16)
      }
    }
  }
}

/// Media records read from a project file, and which files a delete removes.
@Suite(.tags(.smoke))
struct MediaRecordTests {
  func record(file: String = "\(UUID().uuidString).mov", width: Int = 640, height: Int = 360, rate: Double = 30, frames: Int = 360, duration: Double = 12) -> Media.Record {
    Media.Record(file: file, bytes: 10, name: "v", width: width, height: height, framesPerSecond: rate, frameCount: frames, duration: duration, hasAudio: false)
  }

  @Test func aRecordThatIsntAVideoIsNone() {
    #expect(record().isValid)
    let bad = [
      record(frames: 0), record(frames: -5), record(width: 0), record(height: -1), record(rate: 0), record(rate: -24),
      record(rate: .nan), record(rate: .infinity), record(duration: .nan), record(file: "../x.mov"),
    ]
    for record in bad {
      #expect(!record.isValid)
      let profile = ProjectMapping.Profile(duration: 0, inputTensorId: nil, parentTensorId: 0, media: record)
      #expect(ProjectMapping.Profile(profile.bytes)?.media == nil, "\(record) reads as no media")
    }
  }

  @Test func aDeleteRemovesOnlyFilesNoStepNames() {
    let kept = "\(UUID().uuidString).mov", gone = "\(UUID().uuidString).mp4"
    #expect(Media.unnamed(deleted: [kept, gone], named: [kept]) == [gone])
    #expect(Media.unnamed(deleted: [kept], named: [kept]).isEmpty)
    #expect(Media.unnamed(deleted: ["../../x.mov"], named: []).isEmpty)
  }
}
