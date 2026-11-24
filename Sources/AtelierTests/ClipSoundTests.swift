@testable import Atelier
import AVFoundation
import Foundation
@preconcurrency import NNC
import Testing

/// A clip's sound on the canvas and in History (`ClipPlayback`): a generated clip's soundtrack from
/// its project, an imported video's audio track from its file.
@MainActor
struct ClipSoundTests {
  /// Waits up to `seconds` for `condition`.
  func wait(_ seconds: Double = 10, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
      if Date() > deadline { return false }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return true
  }

  func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ClipSoundTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// The canvas's playback is shared: an imported video, then a generated clip, then the video
  /// again, each with its sound.
  @Test func soundFollowsTheCanvasFromClipToClip() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(url: folder.appending(path: "Both.sqlite3"))
    let rate = 32_000
    var audio = Tensor<Float>(.CPU, .NC(2, rate * 2))
    for index in 0..<(rate * 2) {
      audio[0, index] = sin(Float(index) * 0.05) * 0.001
      audio[1, index] = audio[0, index]
    }
    let frame = try #require(ImageTensor.tensor(from: smallImage()))
    let generated = try await project.appendClip(
      frames: Array(repeating: frame, count: 48), clip: Project.ClipContent(framesPerSecond: 24, audio: audio),
      model: "v", prompt: "", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(), duration: 0)
    let file = "\(UUID().uuidString).mp4"
    try FileManager.default.createDirectory(at: project.mediaFolder, withIntermediateDirectories: true)
    let movie = project.mediaFolder.appending(path: file)
    try await Self.writeMovieWithSound(to: movie)
    let inspected = try await Media.inspect(movie)
    let record = Media.Record(
      file: file, bytes: 1, name: "tone", width: inspected.width, height: inspected.height,
      framesPerSecond: inspected.framesPerSecond, frameCount: inspected.frameCount, duration: inspected.duration,
      hasAudio: true)
    let playback = ClipPlayback()
    for round in 0..<2 {
      playback.load(.media(record, tensorId: 1, previewOffset: 0), tensorId: 1, project: project, audioSampleRate: 0, play: false)
      _ = await wait { playback.sound.attached }
      playback.play()
      #expect(await wait { playback.sound.playing }, "round \(round): the imported video plays its sound")
      playback.load(try #require(generated.clip), tensorId: generated.tensorId, project: project, audioSampleRate: rate, play: false)
      _ = await wait { playback.sound.attached }
      playback.play()
      #expect(await wait { playback.sound.playing }, "round \(round): then the generated clip plays its sound")
    }
    playback.reset()
    await project.close()
  }

  @Test func aGeneratedClipPlaysItsSoundtrack() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(url: folder.appending(path: "Sound.sqlite3"))
    let rate = 32_000
    var audio = Tensor<Float>(.CPU, .NC(2, rate * 2))
    for index in 0..<(rate * 2) {
      audio[0, index] = sin(Float(index) * 0.05) * 0.001
      audio[1, index] = audio[0, index]
    }
    let frame = try #require(ImageTensor.tensor(from: smallImage()))
    let item = try await project.appendClip(
      frames: Array(repeating: frame, count: 48), clip: Project.ClipContent(framesPerSecond: 24, audio: audio),
      model: "v", prompt: "", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(), duration: 0)
    let clip = try #require(item.clip)
    #expect(clip.audioId != nil)
    let playback = ClipPlayback()
    playback.load(clip, tensorId: item.tensorId, project: project, audioSampleRate: rate, play: true)
    #expect(await wait { playback.sound.attached }, "the soundtrack is read")
    #expect(await wait { playback.sound.playing }, "and plays")
    playback.reset()
    await project.close()
  }

  @Test func anImportedVideoPlaysItsAudioTrack() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(url: folder.appending(path: "Imported.sqlite3"))
    let file = "\(UUID().uuidString).mp4"
    try FileManager.default.createDirectory(at: project.mediaFolder, withIntermediateDirectories: true)
    let movie = project.mediaFolder.appending(path: file)
    try await Self.writeMovieWithSound(to: movie)
    let inspected = try await Media.inspect(movie)
    #expect(inspected.hasAudio)
    let record = Media.Record(
      file: file, bytes: 1, name: "tone", width: inspected.width, height: inspected.height,
      framesPerSecond: inspected.framesPerSecond, frameCount: inspected.frameCount, duration: inspected.duration,
      hasAudio: true)
    let playback = ClipPlayback()
    playback.load(.media(record, tensorId: 1, previewOffset: 0), tensorId: 1, project: project, audioSampleRate: 0, play: true)
    #expect(await wait { playback.sound.attached }, "the audio track is in the player")
    #expect(await wait { playback.sound.playing }, "and plays")
    playback.reset()
    await project.close()
  }

  /// Two seconds of a picture with a quiet tone, AAC, written as the app writes a clip's MP4.
  static func writeMovieWithSound(to url: URL) async throws {
    let rate = 32_000
    var audio = Tensor<Float>(.CPU, .NC(1, rate * 2))
    for index in 0..<(rate * 2) { audio[0, index] = sin(Float(index) * 0.05) * 0.001 }
    let image = smallImage()
    nonisolated(unsafe) let frame = image
    try await ClipVideo.write(
      to: url, count: 48, frame: { _ in frame }, framesPerSecond: 24, audio: audio, audioSampleRate: rate, codec: .h264,
      metadata: nil)
  }
}
