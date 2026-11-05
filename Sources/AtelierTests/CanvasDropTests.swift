@testable import Atelier
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

/// What the canvas does with a dropped file, read the way a drop reads it: through an item provider.
struct CanvasDropTests {
  private static func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CanvasDropTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private static func image() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    return try #require(context.makeImage())
  }

  private static func movie(in folder: URL) async throws -> URL {
    let image = try image()
    let url = folder.appending(path: "dropped clip.mp4")
    try await ClipVideo.write(
      to: url, count: 8, frame: { _ in image }, framesPerSecond: 24, audio: nil, audioSampleRate: 0,
      codec: .h264, metadata: nil)
    return url
  }

  private static func drop(_ url: URL) async throws -> CanvasDrop {
    let provider = try #require(NSItemProvider(contentsOf: url))
    return try #require(try await CanvasDrop.load(provider))
  }

  @Test func aMovieDropsAsACopyThatOutlivesTheOriginal() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = try await Self.movie(in: folder)
    guard case .video(let copy, let name) = try await Self.drop(movie) else {
      Issue.record("a movie should drop as a video")
      return
    }
    defer { try? FileManager.default.removeItem(at: copy) }
    try FileManager.default.removeItem(at: movie)
    #expect(name == "dropped clip")
    let composition = try await TimelineComposition.make(file: copy)
    #expect(composition.width == 64 && composition.height == 32)
    #expect(composition.frameCount == 8)
    #expect(composition.framesPerSecond == 24)
    #expect(composition.runs == [0..<8])
  }

  @Test func anImageStillDropsAsAnImage() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "dropped.png")
    try #require(ImageTensor.png(try Self.image())).write(to: url)
    guard case .image(let dropped) = try await Self.drop(url) else {
      Issue.record("an image should drop as an image")
      return
    }
    #expect(dropped.image.width == 64)
  }

  @Test func aFileWithoutVideoFails() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "not a video.mp4")
    try Data("nope".utf8).write(to: url)
    await #expect(throws: (any Error).self) { try await TimelineComposition.make(file: url) }
  }
}
