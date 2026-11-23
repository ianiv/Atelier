import AVFoundation
import CoreGraphics
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// A clip from History that MiniMax H3 Ref2VA takes as its reference video, `<Video 1>` in the
/// prompt, with the moodboard images as Picture 1, 2, … The engine reads a canvas tensor of 22 or
/// more frames as the clip (`LocalImageGenerator`'s `referenceClipSamples`): its autoencoder takes
/// 17 n + 5 of them, and its text encoder sees two frames a second. The frames are prepared the
/// way the engine's own CLI loads `--video` (`loadInputVideoTensor` in DrawThingsCLI.swift): one
/// per output frame from the start at the model's frame rate, the clip's last frame held past its
/// end, each scaled to cover the output size and center-cropped.
///
/// A queued job keeps only which clip (`sourceTensorId` in `project`); its frames are read and
/// prepared when it starts (`CreateModel.run`), so a long queue doesn't hold every clip in memory.
nonisolated struct ReferenceVideo: Sendable {
  /// The clip's History item (its first frame's image tensor). Nil when the frames came with the
  /// job instead, as a paired device's do.
  var sourceTensorId: Int64?
  /// The project `sourceTensorId` belongs to.
  var project: String?
  /// One per output frame at the output size, in order; empty until the job starts, and again
  /// once they're in `tensor`.
  var frames: [CGImage] = []
  /// The frames as the engine takes them (`ImageTensor.tensor(frames:width:height:)`), made in
  /// their place for a run on this device so the images and the tensor aren't both kept through
  /// it (`withTensor`).
  var tensor: Tensor<FloatType>?

  /// The shortest clip the engine takes as a reference rather than a first frame (17 + 5).
  static let minimumFrames = 22
  /// The most frames a paired device may send: 17 × 60 + 5, about 43 s at H3's 24 fps, far past
  /// the clips it makes. Bounds what an untrusted request can make this device decode.
  static let maximumFrames = 17 * 60 + 5

  /// This reference with `frames` turned into `tensor` at `width`×`height`, the images let go.
  /// Nil when there are none or they won't draw.
  func withTensor(width: Int, height: Int) -> ReferenceVideo? {
    guard let tensor = ImageTensor.tensor(frames: frames, width: width, height: height) else { return nil }
    var made = self
    made.frames = []
    made.tensor = tensor
    return made
  }

  /// How many frames it holds, in either form.
  var frameCount: Int { tensor?.shape.first ?? frames.count }

  /// Which source frame each of `count` output frames at `rate` shows, for a clip of
  /// `sourceCount` frames at `sourceRate`: the one on screen at that time, as
  /// `AVAssetImageGenerator.copyCGImage` with zero tolerance gives it, and the last one past the
  /// end. A rate that isn't a positive finite number (from a damaged project) counts as `rate`.
  static func sourceIndices(count: Int, rate: Double, sourceCount: Int, sourceRate: Double) -> [Int] {
    guard count > 0, sourceCount > 0 else { return [] }
    let rate = rate.isFinite && rate > 0 ? rate : 24
    let sourceRate = sourceRate.isFinite && sourceRate > 0 ? sourceRate : rate
    let last = sourceCount - 1
    return (0..<count).map { index in
      // The small bias keeps a time exactly on a frame's start (24 into 24) from rounding below it.
      let position = Double(index) * sourceRate / rate + 1e-9
      return position >= Double(last) ? last : max(Int(position), 0)
    }
  }

  /// Where a `sourceWidth`×`sourceHeight` frame is drawn to cover `width`×`height`, centered, with
  /// the CLI's rounding (`loadInputVideoTensor`): the side that overflows is rounded to whole
  /// pixels and the offset halved toward zero.
  static func coverRect(sourceWidth: Int, sourceHeight: Int, width: Int, height: Int) -> CGRect {
    guard sourceWidth > 0, sourceHeight > 0 else { return CGRect(x: 0, y: 0, width: width, height: height) }
    var scaledWidth = width
    var scaledHeight = height
    if sourceWidth * height > sourceHeight * width {
      scaledWidth = Int((Double(sourceWidth) * Double(height) / Double(sourceHeight)).rounded())
    } else {
      scaledHeight = Int((Double(sourceHeight) * Double(width) / Double(sourceWidth)).rounded())
    }
    return CGRect(x: (width - scaledWidth) / 2, y: (height - scaledHeight) / 2, width: scaledWidth, height: scaledHeight)
  }

  /// `image` scaled to cover `width`×`height` and center-cropped, opaque, drawn with high-quality
  /// interpolation as the CLI draws each frame.
  static func frame(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0,
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: coverRect(sourceWidth: image.width, sourceHeight: image.height, width: width, height: height))
    return context.makeImage()
  }

  /// An imported video's frames (`Media`), read from its file as the engine's CLI reads `--video`
  /// (`loadInputVideoTensor`): `count` frames from the start at `rate`, each at the time it
  /// starts with zero tolerance, upright and in SDR (`Media.generator`); a time past the end has
  /// no image, which holds the frame before, and a first frame that doesn't read is a video that
  /// doesn't. Each is prepared as `frame(_:width:height:)` does; one the file shows again (a
  /// slower video) is the same image.
  @concurrent static func fileFrames(url: URL, count: Int, rate: Double, width: Int, height: Int) async throws -> [CGImage] {
    guard count > 0 else { return [] }
    let generator = Media.generator(for: url)
    var frames: [CGImage] = []
    frames.reserveCapacity(count)
    var last: (time: CMTime, frame: CGImage)?
    for index in 0..<count {
      try Task.checkCancellation()
      let time = Media.time(ofFrame: index, framesPerSecond: rate)
      if let image = try? await generator.image(at: time) {
        if let last, image.actualTime == last.time {
          frames.append(last.frame)
          continue
        }
        guard let frame = frame(image.image, width: width, height: height) else { throw Failure.unreadable }
        last = (image.actualTime, frame)
        frames.append(frame)
      } else if let last {
        frames.append(last.frame)
      } else {
        throw Media.Failure.invalidVideo
      }
    }
    return frames
  }

  /// Why a run can't take a reference video, or nil when it can. `numFrames` is the length the
  /// run makes (snapped to the model's counts). The CLI refuses the same (`--video` with
  /// `--audio`, or with a strength below 1 or under 22 frames): the clip is a reference for a
  /// video made from noise, and the engine reads a shorter one as a first frame.
  /// `takesReferences` is the model's `VideoModel.takesReferences`.
  static func problem(takesReferences: Bool, strength: Float, numFrames: Int, hasAudio: Bool) -> String? {
    guard takesReferences else {
      return "Only MiniMax H3 Ref2VA takes a video as a reference."
    }
    if hasAudio {
      return "A reference video can't go with an audio file: remove the audio, or put an image on the canvas instead."
    }
    if !(strength >= 1) {
      return "A reference video needs Strength 100%: the new video is made from noise, with the clip as its reference."
    }
    if numFrames < minimumFrames {
      return "A reference video needs a Length of at least \(minimumFrames) frames."
    }
    return nil
  }

  enum Failure: LocalizedError {
    /// The clip is gone from the project (deleted while the job waited, or another project).
    case sourceMissing
    /// The clip is there, but some of its frames didn't read or decode.
    case unreadable

    var errorDescription: String? {
      switch self {
      case .sourceMissing: "The reference video is no longer in this project."
      case .unreadable: "The reference video's frames couldn't be read."
      }
    }
  }
}
