import CoreGraphics
import Foundation

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
  /// One per output frame at the output size, in order; empty until the job starts.
  var frames: [CGImage] = []

  /// The shortest clip the engine takes as a reference rather than a first frame (17 + 5).
  static let minimumFrames = 22

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
    case sourceMissing

    var errorDescription: String? { "The reference video is no longer in this project." }
  }
}
