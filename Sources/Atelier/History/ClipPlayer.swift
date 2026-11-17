import AVFoundation
@preconcurrency import NNC
import SwiftUI

/// Plays a clip from History or the canvas, looping, straight from the project: its frames are
/// decoded from their tensors just ahead of the playhead and its soundtrack from its audio
/// tensor, so a clip plays at once instead of after it's encoded to a video file (which only
/// Save Video, drags and exports need). The frames are drawn here rather than by the system
/// player, whose own controls showed over the video beside this transport and took over the
/// context menu once one of them had focus; the menu (Save Video, Use This Frame as Input, …)
/// stays Atelier's.
struct ClipPlayer: View {
  let item: HistoryItem
  /// Starts playing once loaded. Neither the canvas nor History's detail does: both wait for Play.
  var autoplay = false
  /// Plays the canvas's playback and offers the canvas menu; otherwise (History) its own and
  /// the frame menu, since opening, clearing and zooming are about the canvas.
  var onCanvas = false
  @Environment(HistoryStore.self) private var history
  @Environment(CreateModel.self) private var model
  @State private var ownPlayback = ClipPlayback()
  @State private var hovering = false

  private var playback: ClipPlayback { onCanvas ? model.canvasPlayback : ownPlayback }

  var body: some View {
    ZStack {
      // The canvas's playback is shared, so it may still hold the clip shown before this one.
      if playback.isReady(for: item.tensorId) {
        ClipFrames(item: item, playback: playback)
          .contentShape(.rect)
          .onTapGesture { playback.togglePlaying() }
          .overlay {
            if playback.failed {
              Label("The video's frames couldn't be read.", systemImage: "exclamationmark.triangle")
                .padding(8)
                .glassEffect(in: .rect(cornerRadius: 8))
            }
          }
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
      }
    }
    .contextMenu {
      if onCanvas {
        CanvasClipMenu(item: item, playback: playback)
      } else {
        ClipFrameMenu(item: item, playback: playback)
      }
    }
    // On the canvas, the canvas is the anchor (`CreateView`).
    .shareAnchor(onCanvas ? nil : AnyHashable(ShareAnchor.player(item.tensorId)))
    .task(id: item.tensorId) {
      // Coming back to the clip the canvas already has keeps its place.
      guard !playback.isReady(for: item.tensorId), let clip = item.clip else { return }
      playback.load(
        clip, tensorId: item.tensorId, project: history.project,
        audioSampleRate: RemoteModelTraits.audioSampleRate(of: item.sidecar.model), play: autoplay)
    }
    .onDisappear { playback.pause() }
  }

  #if os(iOS)
    private static let alwaysShowsControls = true
  #else
    private static let alwaysShowsControls = false
  #endif
}

/// The clip's frames, fitted, on black; its first frame's thumbnail until that's decoded.
private struct ClipFrames: View {
  let item: HistoryItem
  let playback: ClipPlayback

  var body: some View {
    // Paced by the display, and paused by SwiftUI while the view isn't on screen.
    TimelineView(.animation(paused: !playback.isPlaying)) { timeline in
      ZStack {
        Color.black
        if let frame = playback.frame {
          Image(decorative: frame, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
        } else {
          Thumbnail(item: item, half: false, fill: false)
        }
      }
      .onChange(of: timeline.date) { playback.displayDidTick() }
    }
  }
}

/// Play/pause, a scrubber with the time, and mute, over the bottom of the video.
private struct ClipTransport: View {
  let playback: ClipPlayback
  let duration: Double

  var body: some View {
    HStack(spacing: 8) {
      Button("Previous Frame", systemImage: "backward.frame.fill") { playback.step(-1) }
        .touchTarget()
      Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
        playback.togglePlaying()
      }
      .touchTarget()
      Button("Next Frame", systemImage: "forward.frame.fill") { playback.step(1) }
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

/// A looping player for one clip, reading it from its project. Frames are decoded a second
/// ahead of the playhead, several at once: one frame's fpzip tensor takes ~75 ms to read
/// (1280×832), longer than a frame lasts at 24 fps, but each read opens the store on its own
/// (`Project.clipFrame`), so four together keep up. The soundtrack, when there is one, is the
/// clock (an `AVAudioPlayerNode` looping it), so the picture follows the sound; a silent clip
/// runs on the system clock. A frame that isn't decoded in time is skipped: the one before it
/// stays up.
@MainActor
@Observable
final class ClipPlayback {
  private(set) var isReady = false
  /// The clip loaded, by first-frame tensor id, so a view can tell its own clip from the one a
  /// shared playback held before.
  private(set) var loadedTensorId: Int64?
  private(set) var isPlaying = false
  /// Seconds into the clip, kept current while it plays.
  private(set) var time: Double = 0
  private(set) var framesPerSecond: Double = 24
  /// The frame on screen, nil until the clip's first one is decoded.
  private(set) var frame: CGImage?
  /// The clip's first frame couldn't be read.
  private(set) var failed = false
  var isMuted = false {
    didSet { if engineState == .running { audioPlayer.volume = isMuted ? 0 : 1 } }
  }

  /// The tensor of the frame on screen, for `--canvas-clip-check`.
  @ObservationIgnored private(set) var shownFrameTensorId: Int64?
  @ObservationIgnored private var project: Project?
  @ObservationIgnored private var frameIds: [Int64] = []
  @ObservationIgnored private var duration: Double = 0
  @ObservationIgnored private var shownIndex: Int?
  @ObservationIgnored private var decoded: [Int: CGImage] = [:]
  /// Decodes running, by frame index, each with a token so a cancelled one that finishes late
  /// can't clear the entry of a newer one for the same frame.
  @ObservationIgnored private var decoding: [Int: (token: Int, task: Task<Void, Never>)] = [:]
  @ObservationIgnored private var nextToken = 0
  /// Goes up when the clip changes, so nothing of the old one lands in the new one.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var audioTask: Task<Void, Never>?

  /// The clock: the clip time it started at, and when (the system clock), or the audio player's
  /// own time since it started when it plays the soundtrack.
  @ObservationIgnored private var clockStart: Double = 0
  @ObservationIgnored private var clockDate = Date()
  @ObservationIgnored private var audioClock = false
  @ObservationIgnored private let engine = AVAudioEngine()
  @ObservationIgnored private let audioPlayer = AVAudioPlayerNode()
  @ObservationIgnored private var soundtrack: AVAudioPCMBuffer?
  /// The engine's start and stop wait on coreaudiod, which can stop answering (a coreaudiod
  /// stuck for a day froze the app on Play, 2026-11-17), and so can graph changes while one is
  /// waiting. So all three run on this queue, never the main actor, and the main actor touches
  /// the player only once the engine is running. Until then the picture runs on the system clock.
  @ObservationIgnored private let audioQueue = DispatchQueue(label: "Atelier.ClipPlayback.audio")
  @ObservationIgnored private var engineState = EngineState.stopped
  private enum EngineState { case stopped, starting, running }

  /// How far ahead frames are decoded, and how many at once.
  private static let lookahead = 24
  private static let concurrentDecodes = 4

  init() {
    engine.attach(audioPlayer)
  }

  func isReady(for tensorId: Int64) -> Bool { isReady && loadedTensorId == tensorId }

  /// Unloads the clip, so nothing plays until the next `load`.
  func reset() {
    pause()
    generation += 1
    for entry in decoding.values { entry.task.cancel() }
    decoding = [:]
    decoded = [:]
    audioTask?.cancel()
    audioTask = nil
    soundtrack = nil
    if engineState != .stopped {
      engineState = .stopped
      nonisolated(unsafe) let engine = engine
      audioQueue.async { engine.stop() }
    }
    project = nil
    frameIds = []
    duration = 0
    frame = nil
    shownIndex = nil
    shownFrameTensorId = nil
    failed = false
    isReady = false
    time = 0
    loadedTensorId = nil
  }

  func load(_ clip: ClipInfo, tensorId: Int64, project: Project, audioSampleRate: Int, play: Bool) {
    reset()
    guard !clip.frames.isEmpty else { return }
    self.project = project
    frameIds = clip.frames
    framesPerSecond = clip.framesPerSecond > 0 ? clip.framesPerSecond : 24
    duration = Double(clip.frames.count) / framesPerSecond
    isReady = true
    loadedTensorId = tensorId
    if let audioId = clip.audioId, audioSampleRate > 0 {
      let current = generation
      // As long as the picture, so the sound loops with it.
      let length = Int((duration * Double(audioSampleRate)).rounded())
      audioTask = Task { [weak self] in
        let samples = await project.read { $0.audio(id: audioId) }
        guard let self, current == self.generation, let samples,
              let buffer = Self.buffer(samples, sampleRate: audioSampleRate, length: length)
        else { return }
        self.soundtrack = buffer
        nonisolated(unsafe) let engine = self.engine, player = self.audioPlayer, format = buffer.format
        self.audioQueue.async {
          engine.disconnectNodeOutput(player)
          engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        // Already playing on the system clock: the sound takes over from here.
        if self.isPlaying { self.startClock(at: self.clockTime) }
      }
    }
    show(index: 0)
    if play { self.play() }
  }

  func play() {
    guard isReady else { return }
    isPlaying = true
    startClock(at: time)
  }

  func pause() {
    if isPlaying { time = clockTime }
    isPlaying = false
    if engineState == .running { audioPlayer.stop() }
  }

  func togglePlaying() {
    if isPlaying { pause() } else { play() }
  }

  func seek(to seconds: Double) {
    guard isReady else { return }
    // The slider's end is the clip's end, which is its start again; stay on the last frame.
    time = min(max(seconds, 0), max(duration - 1 / framesPerSecond, 0))
    if isPlaying { startClock(at: time) }
    show(index: index(at: time))
  }

  /// Pauses and moves `frames` frames from the one on screen, stopping at the clip's ends (as
  /// the Video Editor's frame steps do).
  func step(_ frames: Int) {
    guard isReady, !frameIds.isEmpty else { return }
    pause()
    // From the playhead's frame, not the one up now: a step back waits for its frame to decode,
    // and a second step made meanwhile goes on from the first.
    let index = min(max(index(at: time) + frames, 0), frameIds.count - 1)
    time = Double(index) / framesPerSecond
    show(index: index)
  }

  /// The frame on screen (pausing playback, so it stays there).
  func pauseOnFrame(count: Int) -> Int {
    pause()
    // Nothing loaded yet: the clip's first frame is what's on screen.
    guard isReady else { return 0 }
    // The playhead's frame: on screen, or about to be once it's decoded.
    return min(index(at: time), max(count - 1, 0))
  }

  /// Moves the picture along while playing: `ClipFrames` calls this for each frame of the display.
  func displayDidTick() {
    guard isPlaying else { return }
    time = clockTime
    show(index: index(at: time))
  }

  // MARK: Clock

  private func startClock(at start: Double) {
    clockStart = start
    clockDate = Date()
    audioClock = false
    // The engine stops on its own when the output device changes.
    if engineState == .running, !engine.isRunning { engineState = .stopped }
    if engineState == .running { audioPlayer.stop() }
    guard let soundtrack else { return }
    guard engineState == .running else {
      startEngine()
      return
    }
    audioPlayer.volume = isMuted ? 0 : 1
    // From here to the end, then the whole soundtrack over and over.
    let offset = Int(start * soundtrack.format.sampleRate)
    if let rest = Self.tail(of: soundtrack, from: offset) {
      audioPlayer.scheduleBuffer(rest)
    }
    audioPlayer.scheduleBuffer(soundtrack, at: nil, options: .loops)
    audioPlayer.play()
    audioClock = true
  }

  /// Starts the engine on `audioQueue`; once it's running, a clip still playing moves over to
  /// the sound's clock. A start that never returns leaves the clip playing silently.
  private func startEngine() {
    guard engineState == .stopped else { return }
    engineState = .starting
    let current = generation
    nonisolated(unsafe) let engine = engine
    audioQueue.async { [weak self] in
      let started = (try? engine.start()) != nil
      Task { @MainActor in
        guard let self, current == self.generation, self.engineState == .starting else { return }
        self.engineState = started ? .running : .stopped
        if started, self.isPlaying { self.startClock(at: self.clockTime) }
      }
    }
  }

  /// Where the clock is in the clip, wrapped round as it loops.
  private var clockTime: Double {
    guard isPlaying, duration > 0 else { return time }
    var elapsed = Date().timeIntervalSince(clockDate)
    if audioClock {
      // Before the player has rendered anything it has no time yet: it hasn't started.
      elapsed = 0
      if let now = audioPlayer.lastRenderTime, let played = audioPlayer.playerTime(forNodeTime: now) {
        elapsed = max(Double(played.sampleTime) / played.sampleRate, 0)
      }
    }
    return (clockStart + elapsed).truncatingRemainder(dividingBy: duration)
  }

  private func index(at seconds: Double) -> Int {
    // A hair over, so a frame's own start time (index / rate) isn't rounded into the frame before.
    min(max(Int((seconds * framesPerSecond + 1e-6).rounded(.down)), 0), max(frameIds.count - 1, 0))
  }

  // MARK: Frames

  /// Puts frame `index` up if it's decoded (otherwise the one up now stays until it is), and
  /// keeps the frames after it decoding.
  private func show(index: Int) {
    if index != shownIndex, let image = decoded[index] {
      frame = image
      shownIndex = index
      shownFrameTensorId = frameIds[index]
    }
    prefetch(from: index)
  }

  private func prefetch(from index: Int) {
    guard let project, !frameIds.isEmpty else { return }
    let count = frameIds.count
    let wanted = (0..<min(Self.lookahead, count)).map { (index + $0) % count }
    let keep = Set(wanted).union(shownIndex.map { [$0] } ?? [])
    for key in decoded.keys where !keep.contains(key) {
      decoded[key] = nil
    }
    for (key, entry) in decoding where !keep.contains(key) {
      entry.task.cancel()
      decoding[key] = nil
    }
    for next in wanted where decoded[next] == nil && decoding[next] == nil {
      guard decoding.count < Self.concurrentDecodes else { break }
      let id = frameIds[next], current = generation, token = nextToken
      nextToken += 1
      let task = Task { [weak self] in
        let image = await project.read { $0.clipFrame(tensorId: id) }
        guard let self, current == self.generation, self.decoding[next]?.token == token else { return }
        self.decoding[next] = nil
        if let image {
          self.decoded[next] = image
        } else if next == 0, self.frame == nil, !Task.isCancelled {
          self.failed = true
          return
        }
        // Paused, the frame wanted is the playhead's; playing, the next tick shows it.
        self.show(index: self.isPlaying ? self.index(at: self.clockTime) : self.index(at: self.time))
      }
      decoding[next] = (token, task)
    }
  }

  // MARK: Sound

  /// The soundtrack (PCM in [channels, samples] order) as a buffer `length` samples long,
  /// trimmed or padded with silence to the picture's length.
  private static func buffer(_ samples: Tensor<Float>, sampleRate: Int, length: Int) -> AVAudioPCMBuffer? {
    let shape = samples.shape
    guard shape.count == 2, shape[0] > 0, shape[1] > 0, length > 0,
          let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(shape[0])),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
          let channels = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(length)
    let available = min(shape[1], length)
    samples.withUnsafeBytes { raw in
      let values = raw.bindMemory(to: Float.self)
      for channel in 0..<shape[0] {
        let row = channels[channel]
        for sample in 0..<length {
          row[sample] = sample < available ? values[channel * shape[1] + sample] : 0
        }
      }
    }
    return buffer
  }

  /// `buffer` from sample `start` on; nil when that's at or past its end.
  private static func tail(of buffer: AVAudioPCMBuffer, from start: Int) -> AVAudioPCMBuffer? {
    let count = Int(buffer.frameLength) - start
    guard start >= 0, count > 0,
          let rest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
          let source = buffer.floatChannelData, let destination = rest.floatChannelData
    else { return nil }
    rest.frameLength = AVAudioFrameCount(count)
    for channel in 0..<Int(buffer.format.channelCount) {
      destination[channel].update(from: source[channel] + start, count: count)
    }
    return rest
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
    // Until this clip loads, the playback's time belongs to no frame of it (or to another clip).
    let frameKnown = playback.isReady(for: item.tensorId)
    Button("Save Video…") { ClipActions.save(item, history: history, dialogs: fileDialogs) }
    Button("Save to Photos") { ClipActions.saveToPhotos(item, history: history, model: model) }
    ShareItem(exports: [history.dragExport(item)], anchor: ShareAnchor.player(item.tensorId))
    Divider()
    Button("Use This Frame as Input") {
      let index = playback.pauseOnFrame(count: count)
      model.useFrame(index, of: item)
      navigation.section = .create
    }
    .disabled(!frameKnown)
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
    .disabled(!frameKnown)
    Button("Add Frame to Moodboard") {
      let index = playback.pauseOnFrame(count: count)
      Task { if let frame = await history.frame(index, of: item) { model.moodboard.add(frame) } }
    }
    .disabled(!frameKnown)
  }
}

/// The canvas menu while the canvas plays a clip: the image menu's groups in its order, with the
/// frame actions a video adds. Copy and Add to Moodboard take the frame on screen.
struct CanvasClipMenu: View {
  let item: HistoryItem
  let playback: ClipPlayback
  @Environment(CreateModel.self) private var model
  @Environment(HistoryStore.self) private var history
  @Environment(FileDialogs.self) private var fileDialogs

  var body: some View {
    let count = item.clip?.frames.count ?? 0
    // The canvas's playback is shared: until this clip loads it may hold another one's time.
    let frameKnown = playback.isReady(for: item.tensorId)
    Button("Copy Frame") {
      let index = playback.pauseOnFrame(count: count)
      Task { if let frame = await history.frame(index, of: item) { HistoryStore.copy(frame) } }
    }
    .disabled(!frameKnown)
    Button("Save Video…") { ClipActions.save(item, history: history, dialogs: fileDialogs) }
    Button("Save to Photos") { ClipActions.saveToPhotos(item, history: history, model: model) }
    ShareItem(exports: [history.dragExport(item)], anchor: ShareAnchor.canvas)
    Divider()
    Button("Use This Frame as Input") {
      let index = playback.pauseOnFrame(count: count)
      model.useFrame(index, of: item)
    }
    .disabled(!frameKnown)
    Button("Use Last Frame as Input") {
      playback.pause()
      model.useFrame(count - 1, of: item)
    }
    Divider()
    CanvasContentItems(
      noun: "Video", addToMoodboardTitle: "Add Frame to Moodboard",
      canLoadSettings: model.canUse(item),
      loadSettings: { model.use(item, loadImage: false) },
      addToMoodboard: {
        let index = playback.pauseOnFrame(count: count)
        Task { if let frame = await history.frame(index, of: item) { model.moodboard.add(frame) } }
      },
      canAddToMoodboard: frameKnown)
    Divider()
    // A clip always fills the frame: canvas zoom doesn't reach it.
    ZoomMenuItems(canvas: model.canvas)
      .disabled(true)
    Divider()
    Button("Delete Video", role: .destructive) { model.pendingHistoryDelete = [item] }
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

  static func saveToPhotos(_ item: HistoryItem, history: HistoryStore, model: CreateModel) {
    Task {
      do {
        try await PhotoLibrary.save([], videos: [try await history.videoFile(for: item)])
      } catch {
        model.errorMessage = error.localizedDescription
      }
    }
  }
}
