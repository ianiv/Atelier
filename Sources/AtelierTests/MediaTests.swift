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
