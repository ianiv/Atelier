import AVFoundation
import AVKit
import SwiftUI

/// Plays a clip from History or the canvas, looping, over the first frame until the video file
/// is ready. The system player only draws the video: its own controls would take over the context
/// menu once one of them has focus, so the transport is drawn here and the menu (Save Video, Use
/// This Frame as Input, …) stays Atelier's.
struct ClipPlayer: View {
  let item: HistoryItem
  /// Starts playing once loaded (the canvas); History's detail waits for Play.
  var autoplay = true
  @Environment(HistoryStore.self) private var history
  @Environment(CreateModel.self) private var model
  @State private var playback = ClipPlayback()
  @State private var failure: String?
  @State private var hovering = false

  var body: some View {
    ZStack {
      if playback.isReady {
        VideoPlayer(player: playback.player)
          .allowsHitTesting(false)
          .contentShape(.rect)
          .onTapGesture { playback.togglePlaying() }
          .overlay(alignment: .bottom) {
            // Always there on iPad, where there's no pointer to hover with.
            if hovering || !playback.isPlaying || Self.alwaysShowsControls {
              ClipTransport(playback: playback, duration: item.clip?.duration ?? 0)
                .padding(8)
            }
          }
          .onHover { hovering = $0 }
      } else {
        Thumbnail(item: item, half: false, fill: false)
          .overlay {
            if let failure {
              Label(failure, systemImage: "exclamationmark.triangle")
                .padding(8)
                .glassEffect(in: .rect(cornerRadius: 8))
            } else {
              ProgressView().controlSize(.small)
            }
          }
      }
    }
    .contextMenu { ClipFrameMenu(item: item, playback: playback) }
    .task(id: item.tensorId) {
      failure = nil
      do {
        let url = try await history.videoFile(for: item)
        playback.load(
          url, framesPerSecond: item.clip?.framesPerSecond ?? 24,
          duration: item.clip?.duration ?? 0, play: autoplay)
      } catch {
        failure = error.localizedDescription
      }
    }
    .onDisappear { playback.pause() }
  }

  #if os(iOS)
    private static let alwaysShowsControls = true
  #else
    private static let alwaysShowsControls = false
  #endif
}

/// Play/pause, a scrubber with the time, and mute, over the bottom of the video.
private struct ClipTransport: View {
  let playback: ClipPlayback
  let duration: Double

  var body: some View {
    HStack(spacing: 8) {
      Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
        playback.togglePlaying()
      }
      .touchTarget()
      Slider(
        value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }),
        in: 0...max(duration, 0.01)
      ) { editing in
        if editing { playback.pause() }
      }
      .controlSize(.small)
      Text(Duration.seconds(playback.time).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1))))
        .font(.caption.monospacedDigit())
      Button(
        playback.isMuted ? "Unmute" : "Mute",
        systemImage: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
      ) {
        playback.isMuted.toggle()
      }
      .touchTarget()
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .glassEffect(in: .capsule)
  }
}

/// A looping player for one clip.
@MainActor
@Observable
final class ClipPlayback {
  let player = AVQueuePlayer()
  @ObservationIgnored private var looper: AVPlayerLooper?
  @ObservationIgnored private var timeObserver: Any?
  private(set) var isReady = false
  private(set) var isPlaying = false
  /// Seconds into the clip, kept current while it plays.
  private(set) var time: Double = 0
  private(set) var framesPerSecond: Double = 24
  private var duration: Double = 0
  var isMuted = false {
    didSet { player.isMuted = isMuted }
  }

  func load(_ url: URL, framesPerSecond: Double, duration: Double, play: Bool) {
    self.framesPerSecond = framesPerSecond
    self.duration = duration
    player.removeAllItems()
    looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    if timeObserver == nil {
      timeObserver = player.addPeriodicTimeObserver(
        forInterval: CMTime(value: 1, timescale: 30), queue: .main
      ) { [weak self] time in
        MainActor.assumeIsolated {
          guard let self, time.seconds.isFinite else { return }
          // Looping restarts the item, so the time wraps within the clip.
          self.time = self.duration > 0 ? time.seconds.truncatingRemainder(dividingBy: self.duration) : time.seconds
        }
      }
    }
    isReady = true
    if play { self.play() }
  }

  func play() {
    player.play()
    isPlaying = true
  }

  func pause() {
    player.pause()
    isPlaying = false
  }

  func togglePlaying() {
    if isPlaying { pause() } else { play() }
  }

  func seek(to seconds: Double) {
    time = seconds
    player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  /// The frame on screen (pausing playback, so it stays there).
  func pauseOnFrame(count: Int) -> Int {
    pause()
    let seconds = player.currentTime().seconds
    guard seconds.isFinite else { return 0 }
    return min(max(Int((seconds * framesPerSecond).rounded(.down)), 0), max(count - 1, 0))
  }
}

/// What can be done with the frame a clip shows: start a new run from it (extending the clip
/// from its last frame, or branching at any frame), copy it, or add it to the moodboard.
struct ClipFrameMenu: View {
  let item: HistoryItem
  let playback: ClipPlayback
  @Environment(CreateModel.self) private var model
  @Environment(HistoryStore.self) private var history
  @Environment(Navigation.self) private var navigation
  @Environment(FileDialogs.self) private var fileDialogs

  var body: some View {
    let count = item.clip?.frames.count ?? 0
    Button("Save Video…") { ClipActions.save(item, history: history, dialogs: fileDialogs) }
    #if os(iOS)
      Button("Save to Photos") { ClipActions.saveToPhotos(item, history: history) }
    #endif
    Divider()
    Button("Use This Frame as Input") {
      let index = playback.pauseOnFrame(count: count)
      model.useFrame(index, of: item)
      navigation.section = .create
    }
    Button("Use Last Frame as Input") {
      playback.pause()
      model.useFrame(count - 1, of: item)
      navigation.section = .create
    }
    Divider()
    Button("Copy Frame") {
      let index = playback.pauseOnFrame(count: count)
      Task { if let frame = await history.frame(index, of: item) { HistoryStore.copy(frame) } }
    }
    Button("Add Frame to Moodboard") {
      let index = playback.pauseOnFrame(count: count)
      Task { if let frame = await history.frame(index, of: item) { model.moodboard.add(frame) } }
    }
  }
}

/// A video run's live preview: its frames played in a loop at the clip's rate.
struct FlipBook: View {
  let frames: [CGImage]
  var framesPerSecond: Double = 12

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / max(framesPerSecond, 1))) { context in
      let index = Int(context.date.timeIntervalSinceReferenceDate * framesPerSecond) % max(frames.count, 1)
      if frames.indices.contains(index) {
        Image(decorative: frames[index], scale: 1).resizable()
      }
    }
  }
}

/// Saving a clip, from the canvas and History.
@MainActor
enum ClipActions {
  /// Asks where to save the clip as an MP4 carrying its settings.
  static func save(_ item: HistoryItem, history: HistoryStore, dialogs: FileDialogs) {
    dialogs.save = FileDialogs.Save(
      file: ExportedFile(type: .mpeg4Movie) {
        try Data(contentsOf: try await history.videoFile(for: item))
      },
      name: history.fileName(for: item) + ".mp4")
  }

  #if os(iOS)
    static func saveToPhotos(_ item: HistoryItem, history: HistoryStore) {
      Task { try? await PhotoLibrary.save([], videos: [try await history.videoFile(for: item)]) }
    }
  #endif
}
