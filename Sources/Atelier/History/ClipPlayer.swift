import AVFoundation
import AVKit
import SwiftUI

/// Plays a clip from History or the canvas: the system player with its own controls, looping,
/// over the first frame until the video file is ready. Its menu takes the frame on screen.
struct ClipPlayer: View {
  let item: HistoryItem
  /// Starts playing once loaded (the canvas); History's detail waits for Play.
  var autoplay = true
  @Environment(HistoryStore.self) private var history
  @Environment(CreateModel.self) private var model
  @State private var playback = ClipPlayback()
  @State private var failure: String?

  var body: some View {
    ZStack {
      if playback.isReady {
        VideoPlayer(player: playback.player)
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
        playback.load(url, framesPerSecond: item.clip?.framesPerSecond ?? 24, play: autoplay)
      } catch {
        failure = error.localizedDescription
      }
    }
    .onDisappear { playback.player.pause() }
  }
}

/// A looping player for one clip.
@MainActor
@Observable
final class ClipPlayback {
  let player = AVQueuePlayer()
  @ObservationIgnored private var looper: AVPlayerLooper?
  private(set) var isReady = false
  private(set) var framesPerSecond: Double = 24

  func load(_ url: URL, framesPerSecond: Double, play: Bool) {
    self.framesPerSecond = framesPerSecond
    player.removeAllItems()
    looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    isReady = true
    if play { player.play() }
  }

  /// The frame on screen (pausing playback, so it stays there).
  func pauseOnFrame(count: Int) -> Int {
    player.pause()
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
      playback.player.pause()
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
