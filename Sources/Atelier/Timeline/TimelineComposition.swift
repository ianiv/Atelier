import AVFoundation
import CoreGraphics

/// A timeline as one AVFoundation composition, which the viewer plays and Export writes. Each
/// clip comes from its MP4 (`HistoryStore.videoFile`), on two alternating tracks so a crossfade
/// can overlap two clips; clips of another size are scaled to fit, on black; sound ramps across
/// crossfades, and muted clips and clips without sound leave silence.
struct TimelineComposition: @unchecked Sendable {
  let composition: AVComposition
  let videoComposition: AVVideoComposition
  let audioMix: AVAudioMix
  let duration: Double
  let width: Int
  let height: Int
  let framesPerSecond: Double
  /// The frames between hard cuts, at `framesPerSecond`: a crossfade joins the clips on either
  /// side into one run.
  let runs: [Range<Int>]

  var frameCount: Int { runs.last?.upperBound ?? 0 }

  /// nil when the layout has nothing to play.
  static func make(_ layout: TimelineLayout, files: [URL]) async throws -> TimelineComposition? {
    guard !layout.segments.isEmpty, files.count == layout.segments.count else { return nil }
    let composition = AVMutableComposition()
    let videoTracks = (0..<2).compactMap { _ in
      composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    }
    let audioTracks = (0..<2).compactMap { _ in
      composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    }
    guard videoTracks.count == 2, audioTracks.count == 2 else { throw ClipVideoError.cantWrite }
    let renderSize = CGSize(width: layout.width, height: layout.height)

    // Where each segment starts and how long it and its fade into the next last, in CMTime so
    // the instructions below meet exactly.
    var starts: [CMTime] = []
    var durations: [CMTime] = []
    var fades: [CMTime] = []
    var transforms: [CGAffineTransform] = []
    var cursor = CMTime.zero
    for (index, segment) in layout.segments.enumerated() {
      let asset = AVURLAsset(url: files[index])
      guard let source = try await asset.loadTracks(withMediaType: .video).first else {
        throw ClipVideoError.noFrames
      }
      let fps = segment.framesPerSecond
      let available = try await source.load(.timeRange)
      let wanted = CMTimeRange(
        start: frameTime(segment.entry.start, fps), duration: frameTime(segment.entry.frameCount, fps))
      let range = wanted.intersection(available)
      try videoTracks[index % 2].insertTimeRange(range, of: source, at: cursor)
      if !segment.entry.muted, let sound = try await asset.loadTracks(withMediaType: .audio).first {
        let soundRange = range.intersection(try await sound.load(.timeRange))
        if soundRange.duration > .zero {
          try audioTracks[index % 2].insertTimeRange(soundRange, of: sound, at: cursor)
        }
      }
      let size = try await source.load(.naturalSize)
      let scale = min(renderSize.width / max(size.width, 1), renderSize.height / max(size.height, 1))
      transforms.append(
        CGAffineTransform(scaleX: scale, y: scale)
          .concatenating(
            CGAffineTransform(
              translationX: (renderSize.width - size.width * scale) / 2,
              y: (renderSize.height - size.height * scale) / 2)))
      let fade = CMTime(seconds: segment.fade, preferredTimescale: 60_000)
      starts.append(cursor)
      durations.append(range.duration)
      fades.append(min(fade, range.duration))
      cursor = cursor + range.duration - fades[index]
    }

    var instructions: [AVVideoCompositionInstruction] = []
    let mixes = audioTracks.map { track in
      let parameters = AVMutableAudioMixInputParameters(track: track)
      parameters.setVolume(1, at: .zero)
      return parameters
    }
    for index in starts.indices {
      let track = videoTracks[index % 2]
      let passStart = starts[index] + (index > 0 ? fades[index - 1] : .zero)
      let passEnd = starts[index] + durations[index] - fades[index]
      if passEnd > passStart {
        instructions.append(
          instruction(
            CMTimeRange(start: passStart, end: passEnd),
            layers: [layer(track, transform: transforms[index])]))
      }
      guard fades[index] > .zero, index + 1 < starts.count else { continue }
      let range = CMTimeRange(start: passEnd, duration: fades[index])
      var outgoing = layer(track, transform: transforms[index])
      outgoing.addOpacityRamp(.init(timeRange: range, start: 1, end: 0))
      let incoming = layer(videoTracks[(index + 1) % 2], transform: transforms[index + 1])
      instructions.append(instruction(range, layers: [outgoing, incoming]))
      mixes[index % 2].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range)
      mixes[(index + 1) % 2].setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range)
    }

    for track in videoTracks + audioTracks where track.segments.isEmpty {
      composition.removeTrack(track)
    }
    let audioMix = AVMutableAudioMix()
    audioMix.inputParameters = zip(audioTracks, mixes).filter { !$0.0.segments.isEmpty }.map(\.1)
    let videoComposition = AVVideoComposition(
      configuration: AVVideoComposition.Configuration(
        frameDuration: frameTime(1, layout.framesPerSecond), instructions: instructions,
        renderSize: renderSize))
    let fps = layout.framesPerSecond
    func frame(_ time: CMTime) -> Int { Int((time.seconds * fps).rounded()) }
    var runs: [Range<Int>] = []
    var runStart = 0
    for index in starts.indices.dropLast() where fades[index] == .zero {
      let cut = frame(starts[index + 1])
      if cut > runStart { runs.append(runStart..<cut) }
      runStart = cut
    }
    let end = frame(cursor)
    if end > runStart { runs.append(runStart..<end) }
    return TimelineComposition(
      composition: composition.copy() as! AVComposition, videoComposition: videoComposition,
      audioMix: audioMix, duration: cursor.seconds, width: layout.width, height: layout.height,
      framesPerSecond: fps, runs: runs)
  }

  func playerItem() -> AVPlayerItem {
    let item = AVPlayerItem(asset: composition)
    item.videoComposition = videoComposition
    item.audioMix = audioMix
    return item
  }

  /// Writes it as one MP4 in `codec`, with AAC sound, titled `title`. Cancelling the task stops it.
  func export(
    to url: URL, codec: VideoCodec, title: String, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let preset = codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
      throw ClipVideoError.cantWrite
    }
    session.videoComposition = videoComposition
    session.audioMix = audioMix
    let name = AVMutableMetadataItem()
    name.identifier = .iTunesMetadataSongName
    name.value = title as NSString
    session.metadata = [name]
    let monitor = Task {
      for await state in session.states(updateInterval: 0.2) {
        if case .exporting(let fraction) = state { progress(fraction.fractionCompleted) }
      }
    }
    defer { monitor.cancel() }
    try? FileManager.default.removeItem(at: url)
    try await session.export(to: url, as: .mp4)
  }

  private static func instruction(
    _ range: CMTimeRange, layers: [AVVideoCompositionLayerInstruction.Configuration]
  ) -> AVVideoCompositionInstruction {
    AVVideoCompositionInstruction(
      configuration: .init(
        layerInstructions: layers.map(AVVideoCompositionLayerInstruction.init(configuration:)),
        timeRange: range))
  }

  private static func layer(
    _ track: AVCompositionTrack, transform: CGAffineTransform
  ) -> AVVideoCompositionLayerInstruction.Configuration {
    var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
    layer.setTransform(transform, at: .zero)
    return layer
  }

  /// `frames` frames at `fps`, as ClipVideo times them.
  static func frameTime(_ frames: Int, _ fps: Double) -> CMTime {
    if fps > 0, abs(fps - fps.rounded()) < 1e-9 {
      return CMTime(value: Int64(frames), timescale: Int32(fps.rounded()))
    }
    return CMTime(value: Int64(frames) * Int64((60_000 / max(fps, 1)).rounded()), timescale: 60_000)
  }
}
