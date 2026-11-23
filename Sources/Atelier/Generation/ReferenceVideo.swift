import AVFoundation
import CoreGraphics
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// A clip from History that MiniMax H3 Ref2VA takes as its reference video, `<Video 1>` in the
/// prompt, with the moodboard images as Picture 1, 2, … The engine reads a canvas tensor of 22 or
/// more frames as the clip (`LocalImageGenerator`'s `referenceClipSamples`): its autoencoder takes
/// 17 n + 5 of them, and its text encoder sees two frames a second. The frames are taken as
/// MiniMax's own reference pipeline takes them (diffusers `minimax_h3` before_encoder.py
/// `_normalize_video` and encoders.py): resampled onto the model's 24 fps, cut to the length of the
/// video being made, and snapped down to 17 n + 5, never padded, so a clip shorter than the new
/// video is a shorter reference. The clip keeps its own aspect ratio: each frame is resized onto
/// the canvas MiniMax's pipeline gives it (`canvasSize`, diffusers' `resolve_canvas_size`: 768 on
/// the short edge), the size the engine puts a reference clip at too (`LocalImageGenerator`'s
/// `minimaxH3CanvasSize`), so it takes the frames as they are.
///
/// A queued job keeps only which clip (`sourceTensorId` in `project`); its frames are read and
/// prepared when it starts (`CreateModel.run`), so a long queue doesn't hold every clip in memory.
nonisolated struct ReferenceVideo: Sendable {
  /// The clip's History item (its first frame's image tensor). Nil when the frames came with the
  /// job instead, as a paired device's do.
  var sourceTensorId: Int64?
  /// The project `sourceTensorId` belongs to.
  var project: String?
  /// One per reference frame at the clip's canvas size (`canvasSize`), in order; empty until the
  /// job starts, and again once they're in `tensor`.
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

  /// This reference with `frames` turned into `tensor` at their size, the images let go. Nil when
  /// there are none, they aren't all one size, or they won't draw.
  func withTensor() -> ReferenceVideo? {
    guard let first = frames.first, frames.allSatisfy({ $0.width == first.width && $0.height == first.height }),
          let tensor = ImageTensor.tensor(frames: frames, width: first.width, height: first.height)
    else { return nil }
    var made = self
    made.frames = []
    made.tensor = tensor
    return made
  }

  /// How many frames it holds, in either form.
  var frameCount: Int { tensor?.shape.first ?? frames.count }

  /// The clip's frames at `rate`, as source frame indexes, at most `limit` of them: MiniMax's
  /// resampling (`_normalize_video`), which holds source frame i over the slots from
  /// floor(i · rate / sourceRate + 0.5) to the next frame's, the last up to the slot the clip's end
  /// rounds to. A rate that isn't a positive finite number (from a damaged project) counts as
  /// `rate`.
  static func resampled(sourceCount: Int, sourceRate: Double, rate: Double, limit: Int) -> [Int] {
    guard sourceCount > 0, limit > 0 else { return [] }
    let rate = rate.isFinite && rate > 0 ? rate : 24
    let sourceRate = sourceRate.isFinite && sourceRate > 0 ? sourceRate : rate
    let scale = rate / sourceRate
    func slot(_ index: Int) -> Double { (Double(index) * scale + 0.5).rounded(.down) }
    var indices: [Int] = []
    for index in 0..<sourceCount {
      let start = slot(index), end = slot(index + 1)
      guard end > start else { continue }
      let count = min(end - start, Double(limit - indices.count))
      indices += repeatElement(index, count: Int(count))
      if indices.count >= limit { break }
    }
    return indices
  }

  /// How many frames the reference is for a run of `numFrames` when the clip has `available` at
  /// 24 fps: as many as both have, snapped down to 17 n + 5 (encoders.py); 0 when that's under
  /// `minimumFrames`, a clip too short to be one.
  static func length(available: Int, numFrames: Int) -> Int {
    let frames = min(available, numFrames)
    return frames >= minimumFrames ? (frames - 5) / 17 * 17 + 5 : 0
  }

  /// Whether `count` frames are a whole reference: 17 n + 5, at least `minimumFrames`.
  static func isLength(_ count: Int) -> Bool { count >= minimumFrames && (count - 5) % 17 == 0 }

  /// The source frame of each reference frame for a run of `numFrames` at `rate`, for a clip of
  /// `sourceCount` frames at `sourceRate` (`resampled`, then `length`); none for a clip too short.
  static func sourceIndices(numFrames: Int, rate: Double, sourceCount: Int, sourceRate: Double) -> [Int] {
    let resampled = resampled(sourceCount: sourceCount, sourceRate: sourceRate, rate: rate, limit: max(numFrames, 0))
    return Array(resampled.prefix(length(available: resampled.count, numFrames: numFrames)))
  }

  /// MiniMax H3's canvas for a clip of `width`×`height`, as diffusers' `resolve_canvas_size`
  /// makes it with the released checkpoint's settings (and the engine's `minimaxH3CanvasSize`):
  /// the short edge at 768, the area capped at 768 × 1344, each side rounded to the nearest
  /// multiple of 32 (half to even, as Python rounds), at least 32; the ratio held to 1:4–4:1.
  static func canvasSize(width: Int, height: Int) -> (width: Int, height: Int) {
    let shortEdge = 768.0, maxPixels = 768.0 * 1344, multiple = 32.0
    let ratio = min(max(Double(max(width, 1)) / Double(max(height, 1)), 1.0 / 4), 4)
    var canvas = ratio >= 1 ? (width: shortEdge * ratio, height: shortEdge) : (width: shortEdge, height: shortEdge / ratio)
    let area = canvas.width * canvas.height
    if area > maxPixels {
      let scale = (maxPixels / area).squareRoot()
      canvas = (canvas.width * scale, canvas.height * scale)
    }
    func rounded(_ value: Double) -> Int { max(Int(multiple), Int((value / multiple).rounded(.toNearestOrEven) * multiple)) }
    return (rounded(canvas.width), rounded(canvas.height))
  }

  /// The most pixels a clip's canvas has (`canvasSize`, rounding included), for checking frames a
  /// paired device sends.
  static let maximumCanvasPixels = 800 * 1376

  /// `image` resized onto its clip's canvas (`canvasSize`), opaque, with high-quality
  /// interpolation, as MiniMax's pipeline resizes each frame (no crop).
  static func frame(_ image: CGImage) -> CGImage? {
    let size = canvasSize(width: image.width, height: image.height)
    guard let context = CGContext(
      data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: size.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    return context.makeImage()
  }

  /// An imported video's frames (`Media`) for a run of `numFrames` at `rate`: its `sourceCount`
  /// frames at `sourceRate` resampled and cut as `sourceIndices` does, each read from the file in
  /// the middle of its time with zero tolerance, upright and in SDR (`Media.generator`), and
  /// prepared as `frame(_:)` does; a frame shown more than once is the same image.
  /// The file may hold fewer frames than its record says: the reference ends at the last that
  /// reads, snapped down again, and one too short for that is refused.
  @concurrent static func fileFrames(
    url: URL, sourceCount: Int, sourceRate: Double, numFrames: Int, rate: Double
  ) async throws -> [CGImage] {
    let indices = sourceIndices(numFrames: numFrames, rate: rate, sourceCount: sourceCount, sourceRate: sourceRate)
    guard !indices.isEmpty else { throw Failure.tooShort }
    let generator = Media.generator(for: url)
    let sourceRate = sourceRate.isFinite && sourceRate > 0 ? sourceRate : rate
    var frames: [CGImage] = []
    frames.reserveCapacity(indices.count)
    var last: (index: Int, frame: CGImage)?
    var lastTime: CMTime?
    for index in indices {
      try Task.checkCancellation()
      if let last, last.index == index {
        frames.append(last.frame)
        continue
      }
      let time = CMTime(seconds: (Double(index) + 0.5) / sourceRate, preferredTimescale: 600_000)
      guard let image = try? await generator.image(at: time) else {
        if frames.isEmpty { throw Media.Failure.invalidVideo }
        break
      }
      // Past the file's end the generator gives its last frame again: the clip has ended.
      if let lastTime, image.actualTime <= lastTime { break }
      lastTime = image.actualTime
      guard let frame = frame(image.image) else { throw Failure.unreadable }
      last = (index, frame)
      frames.append(frame)
    }
    let kept = length(available: frames.count, numFrames: numFrames)
    guard kept > 0 else { throw Failure.tooShort }
    return Array(frames.prefix(kept))
  }

  /// Why a run can't take a reference video, or nil when it can. `numFrames` is the length the
  /// run makes (snapped to the model's counts); `clipFrames`, when known, how many frames the clip
  /// has at 24 fps. The CLI refuses the same (`--video` with `--audio`, or with a strength below 1
  /// or under 22 frames): the clip is a reference for a video made from noise, and the engine reads
  /// a shorter one as a first frame. `takesReferences` is the model's `VideoModel.takesReferences`.
  static func problem(takesReferences: Bool, strength: Float, numFrames: Int, hasAudio: Bool, clipFrames: Int? = nil) -> String? {
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
    if let clipFrames, clipFrames < minimumFrames {
      return "The clip is too short to be a reference video: it needs \(minimumFrames) frames at 24 fps, about a second."
    }
    return nil
  }

  enum Failure: LocalizedError {
    /// The clip is gone from the project (deleted while the job waited, or another project).
    case sourceMissing
    /// The clip is there, but some of its frames didn't read or decode.
    case unreadable
    /// The clip has fewer than `minimumFrames` frames at 24 fps.
    case tooShort

    var errorDescription: String? {
      switch self {
      case .sourceMissing: "The reference video is no longer in this project."
      case .unreadable: "The reference video's frames couldn't be read."
      case .tooShort: "The reference video is too short: it needs 22 frames at 24 fps, about a second."
      }
    }
  }
}
