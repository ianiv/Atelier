import AVFoundation
import CoreImage
import SwiftUI

/// Puts a project's clips in order: a viewer playing the whole timeline, a track of its clips to
/// reorder, trim and split, and beside them the project's videos to drag in. Any frame can start
/// a new run (Continue from Here), which comes back onto the timeline after that frame.
struct TimelineScreen: View {
  @Environment(HistoryStore.self) private var history
  @Environment(CreateModel.self) private var create
  @Environment(TimelineStore.self) private var store
  @Environment(FileDialogs.self) private var fileDialogs
  @Environment(\.undoManager) private var undoManager
  /// The app's appearance (the controls over the video are always dark).
  @Environment(\.colorScheme) private var colorScheme
  @State private var playback = TimelinePlayback()
  @State private var composition: TimelineComposition?
  @State private var preparing = false
  @State private var failure: String?
  @State private var selectedEntry: UUID?
  /// A trim being dragged: the entry and its new start and end.
  @State private var trim: (entry: UUID, start: Int, end: Int)?
  @State private var exportProgress: Double?
  @State private var exportTask: Task<Void, Never>?
  /// Export Video… is choosing how.
  @State private var choosingExport = false
  @State private var renaming: Timeline?
  @State private var newName = ""
  @State private var editingSettings = false
  @State private var pendingDelete: Timeline?

  /// The timeline as shown, with a trim being dragged applied.
  private var shown: Timeline? {
    guard var timeline = store.selected else { return nil }
    if let trim, let index = timeline.entries.firstIndex(where: { $0.id == trim.entry }) {
      timeline.entries[index].start = trim.start
      timeline.entries[index].end = trim.end
    }
    return timeline
  }

  private var layout: TimelineLayout {
    shown.map { TimelineLayout($0, item: history.item(tensorId:)) } ?? TimelineLayout()
  }

  /// The segment and frame under the playhead.
  private var playhead: (index: Int, frame: Int)? {
    layout.locate(playback.time)
  }

  var body: some View {
    let layout = layout
    VStack(spacing: 0) {
      viewer(layout)
      Divider()
      TimelineTrack(
        layout: layout, playback: playback, selectedEntry: $selectedEntry, trim: $trim,
        commitTrim: commitTrim, menu: { entryMenu($0, layout: layout) },
        insert: insert, move: move)
        .frame(height: 128)
        .overlay(alignment: .bottomTrailing) {
          TimelineZoomControl(duration: layout.duration).padding(6)
        }
    }
    .toolbar { toolbar(layout) }
    .detailInspector(selection: 0, isEmpty: false, clearSelection: {}) {
      TimelineBin(append: { store.append([$0], undoManager: undoManager) })
        .inspectorColumnWidth(min: 220, ideal: 260, max: 400)
    }
    .navigationTitle("Video Editor")
    .onChange(of: history.project.name, initial: true) {
      store.load()
      selectedEntry = nil
    }
    // A timeline opens fitted to the track.
    .onChange(of: store.selected?.id, initial: true) {
      Task { @MainActor in
        store.zoomToFit(duration: self.layout.duration)
      }
    }
    .task(id: RebuildKey(timeline: store.selected, loaded: history.isLoaded, codec: VideoCodec.current)) {
      await rebuild()
    }
    .alert(
      "Rename Timeline", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Name", text: $newName)
      Button("Rename") {
        if let renaming { store.rename(renaming.id, to: newName, undoManager: undoManager) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
      "Delete “\(pendingDelete?.name ?? "")”?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      presenting: pendingDelete
    ) { timeline in
      Button("Delete Timeline", role: .destructive) { store.delete(timeline.id, undoManager: undoManager) }
    } message: { _ in
      Text("Its clips stay in History.")
    }
    .deleteCommand { removeSelected() }
    .onDisappear { playback.pause() }
  }

  private struct RebuildKey: Equatable {
    var timeline: Timeline?
    var loaded: Bool
    var codec: VideoCodec
  }

  // MARK: - Viewer

  private func viewer(_ layout: TimelineLayout) -> some View {
    ZStack {
      Color.black
      if composition != nil {
        TimelineVideo(playback: playback)
          .aspectRatio(CGSize(width: max(layout.width, 1), height: max(layout.height, 1)), contentMode: .fit)
      } else if preparing {
        ProgressView("Preparing clips…").controlSize(.small).foregroundStyle(.white)
      } else if let failure {
        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.white)
      } else {
        ContentUnavailableView(
          store.selected == nil ? "No timeline" : "Empty timeline", systemImage: "film.stack",
          description: Text(
            "Drag videos into the track from the list beside it, or choose Add to Timeline on a video in History."))
          .foregroundStyle(.white)
      }
    }
    .contentShape(.rect)
    .onTapGesture { playback.togglePlaying() }
    .contextMenu {
      if let playhead {
        frameMenu(segment: playhead.index, frame: playhead.frame, layout: layout)
      }
    }
    .overlay(alignment: .bottom) {
      VStack(spacing: 8) {
        if let exportProgress {
          HStack {
            ProgressView(value: exportProgress) { Text("Exporting…") }
              .frame(width: 200)
            Button("Cancel") { exportTask?.cancel() }
          }
          .padding(10)
          .glassEffect(in: .rect(cornerRadius: 12))
        }
        if composition != nil {
          HStack(spacing: 10) {
            TimelineTransport(playback: playback, layout: layout, playhead: playhead)
            editingTools(layout)
          }
        }
      }
      .padding(10)
      // Over black video, whatever the app's appearance.
      .environment(\.colorScheme, .dark)
    }
  }

  /// Split and the timeline's size and frame rate, beside the transport.
  private func editingTools(_ layout: TimelineLayout) -> some View {
    HStack(spacing: 10) {
      Button("Split at Playhead", systemImage: "scissors") { split() }
        .keyboardShortcut("b", modifiers: .command)
        .disabled(!canSplit)
        .help("Split the clip at the playhead (⌘B)")
        .touchTarget()
      Button("Timeline Settings", systemImage: "slider.horizontal.3") { editingSettings = true }
        .disabled(store.selected == nil)
        .help("The size and frame rate the timeline plays and exports at")
        .touchTarget()
        .popover(isPresented: $editingSettings) {
          if let timeline = store.selected {
            TimelineSettings(timeline: timeline, layout: layout) { change in
              store.edit(timeline.id, "Timeline Settings", undoManager: undoManager, change)
            }
            .environment(\.colorScheme, colorScheme)
          }
        }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .glassEffect(in: .capsule)
  }

  // MARK: - Menus

  /// What can be done with frame `frame` of segment `index`'s clip.
  @ViewBuilder
  private func frameMenu(segment index: Int, frame: Int, layout: TimelineLayout) -> some View {
    let segment = layout.segments[index]
    if let timeline = store.selected {
      Button("Continue from Here") {
        playback.pause()
        create.continueTimeline(timeline, entry: segment.entry, frame: frame, of: segment.item)
        navigateToCreate()
      }
      if create.videoModel?.takesLastFrame == true, index + 1 < layout.segments.count {
        let next = layout.segments[index + 1]
        Button("Bridge to Next Clip") {
          playback.pause()
          create.continueTimeline(
            timeline, entry: segment.entry, frame: frame, of: segment.item,
            bridgingTo: (next.entry, next.item))
          navigateToCreate()
        }
      }
    }
    Divider()
    Button("Use This Frame as Input") {
      playback.pause()
      create.useFrame(frame, of: segment.item)
      navigateToCreate()
    }
    Button("Copy Frame") {
      Task { if let image = await history.frame(frame, of: segment.item) { HistoryStore.copy(image) } }
    }
    Button("Add Frame to Moodboard") {
      Task { if let image = await history.frame(frame, of: segment.item) { create.moodboard.add(image) } }
    }
    Divider()
    Button("Split at Playhead") { split() }
      .disabled(!canSplit)
  }

  @Environment(Navigation.self) private var navigation

  private func navigateToCreate() {
    navigation.section = .create
  }

  /// A clip's menu in the track.
  @ViewBuilder
  private func entryMenu(_ entry: Timeline.Entry, layout: TimelineLayout) -> some View {
    if let index = layout.index(of: entry.id) {
      let segment = layout.segments[index]
      // The frame under the playhead when it's on this clip, else its last.
      let frame = playhead?.index == index ? playhead!.frame : entry.end - 1
      Section(playhead?.index == index ? "At the Playhead" : "At the Clip's End") {
        frameMenu(segment: index, frame: frame, layout: layout)
      }
      Divider()
      Toggle("Mute", isOn: Binding(
        get: { entry.muted },
        set: { muted in edit(entry.id, muted ? "Mute Clip" : "Unmute Clip") { $0.muted = muted } }))
      if index + 1 < layout.segments.count {
        Picker("Crossfade into Next", selection: Binding(
          get: { entry.crossfadeFrames },
          set: { frames in edit(entry.id, "Crossfade") { $0.crossfadeFrames = frames } })
        ) {
          Text("None").tag(0)
          ForEach([4, 8, 12, 24, 48], id: \.self) { frames in
            Text("\(frames) frames (\(seconds(frames, segment.framesPerSecond)))").tag(frames)
          }
        }
      }
      Divider()
      Button("Duplicate") { duplicate(entry) }
      Button("Show in History") {
        create.show(segment.item)
        navigation.section = .history
      }
      Divider()
      Button("Remove from Timeline", role: .destructive) { remove(entry.id) }
    }
  }

  private func seconds(_ frames: Int, _ fps: Double) -> String {
    (Double(frames) / max(fps, 1)).formatted(.number.precision(.fractionLength(1))) + " s"
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private func toolbar(_: TimelineLayout) -> some ToolbarContent {
    ToolbarItem(placement: .navigation) { ProjectMenu() }
    ToolbarItem(placement: .navigation) {
      Menu {
        ForEach(store.timelines) { timeline in
          Toggle(
            timeline.name,
            isOn: Binding(
              get: { timeline.id == store.selected?.id },
              set: { if $0 { store.selectedId = timeline.id } }))
        }
        if !store.timelines.isEmpty { Divider() }
        Button("New Timeline") { store.newTimeline(undoManager: undoManager) }
        if let timeline = store.selected {
          Button("Rename “\(timeline.name)”…") {
            newName = timeline.name
            renaming = timeline
          }
          Button("Delete “\(timeline.name)”…", role: .destructive) { pendingDelete = timeline }
        }
      } label: {
        Label(store.selected?.name ?? "Timelines", systemImage: "film.stack")
          .labelStyle(.titleAndIcon)
      }
      .help("Choose, add, rename or delete this project's timelines")
    }
    ToolbarItem {
      Group {
        #if os(iOS)
          Menu {
            Button("Export Video…") { choosingExport = true }
            Button("Save to Photos") { export(toPhotos: true) }
          } label: {
            Label("Export", systemImage: "square.and.arrow.up")
          } primaryAction: {
            choosingExport = true
          }
        #else
          Button("Export Video…", systemImage: "square.and.arrow.up") { choosingExport = true }
        #endif
      }
      .disabled(composition == nil || exportProgress != nil)
      .help("Export the timeline as one MP4, as it is or upscaled")
      .sheet(isPresented: $choosingExport) {
        if let composition {
          VideoExportSheet(
            width: composition.width, height: composition.height,
            frameCount: composition.frameCount
          ) { upscale in
            if let upscale {
              queueUpscaledExport(upscale)
            } else {
              export(toPhotos: false)
            }
          }
        }
      }
    }
  }

  // MARK: - Editing

  private func edit(_ id: UUID, _ name: String, _ change: @escaping (inout Timeline.Entry) -> Void) {
    guard let timeline = store.selected else { return }
    store.edit(timeline.id, name, undoManager: undoManager) { timeline in
      if let index = timeline.entries.firstIndex(where: { $0.id == id }) { change(&timeline.entries[index]) }
    }
  }

  private var canSplit: Bool {
    guard let playhead, let segment = layout.segments[safeIndex: playhead.index] else { return false }
    return playhead.frame > segment.entry.start && playhead.frame < segment.entry.end
  }

  /// Cuts the clip under the playhead in two there.
  private func split() {
    guard canSplit, let playhead, let timeline = store.selected else { return }
    let entry = layout.segments[playhead.index].entry
    store.edit(timeline.id, "Split Clip", undoManager: undoManager) { timeline in
      guard let index = timeline.entries.firstIndex(where: { $0.id == entry.id }) else { return }
      var second = timeline.entries[index]
      second.id = UUID()
      second.placement = nil
      second.start = playhead.frame
      timeline.entries[index].end = playhead.frame
      timeline.entries[index].crossfadeFrames = 0
      timeline.entries.insert(second, at: index + 1)
    }
    selectedEntry = entry.id
  }

  private func duplicate(_ entry: Timeline.Entry) {
    guard let timeline = store.selected else { return }
    store.edit(timeline.id, "Duplicate Clip", undoManager: undoManager) { timeline in
      guard let index = timeline.entries.firstIndex(where: { $0.id == entry.id }) else { return }
      var copy = entry
      copy.id = UUID()
      copy.placement = nil
      timeline.entries.insert(copy, at: index + 1)
    }
  }

  private func remove(_ id: UUID) {
    guard let timeline = store.selected else { return }
    store.edit(timeline.id, "Remove Clip", undoManager: undoManager) { timeline in
      timeline.entries.removeAll { $0.id == id }
    }
    if selectedEntry == id { selectedEntry = nil }
  }

  private func removeSelected() {
    if let selectedEntry { remove(selectedEntry) }
  }

  private func commitTrim() {
    guard let trim, let timeline = store.selected else { return }
    self.trim = nil
    store.edit(timeline.id, "Trim Clip", undoManager: undoManager) { timeline in
      guard let index = timeline.entries.firstIndex(where: { $0.id == trim.entry }) else { return }
      timeline.entries[index].start = trim.start
      timeline.entries[index].end = trim.end
    }
  }

  /// Puts a clip from the bin at `index` (a new timeline when there's none).
  private func insert(_ item: HistoryItem, at index: Int) {
    let id = store.selected?.id ?? store.newTimeline(undoManager: undoManager)
    store.insert(item, at: index, in: id, undoManager: undoManager)
  }

  /// Moves an entry to `index` among the others.
  private func move(_ id: UUID, to index: Int) {
    guard let timeline = store.selected else { return }
    store.edit(timeline.id, "Move Clip", undoManager: undoManager) { timeline in
      guard let from = timeline.entries.firstIndex(where: { $0.id == id }) else { return }
      let entry = timeline.entries.remove(at: from)
      timeline.entries.insert(entry, at: min(max(index, 0), timeline.entries.count))
    }
  }

  // MARK: - Playing and exporting

  /// Builds the composition after an edit, keeping the playhead where it was.
  private func rebuild() async {
    let layout = TimelineLayout(store.selected ?? Timeline(name: ""), item: history.item(tensorId:))
    guard !layout.segments.isEmpty else {
      composition = nil
      playback.load(nil)
      return
    }
    preparing = composition == nil
    defer { preparing = false }
    do {
      var files: [URL] = []
      for segment in layout.segments { files.append(try await history.videoFile(for: segment.item)) }
      let made = try await TimelineComposition.make(layout, files: files)
      guard !Task.isCancelled else { return }
      failure = nil
      composition = made
      playback.load(made)
    } catch {
      guard !Task.isCancelled else { return }
      failure = error.localizedDescription
      composition = nil
      playback.load(nil)
    }
  }

  /// Asks where to save the upscaled timeline, then queues its export: it waits its turn with
  /// generations in the Queue, which shows its progress, and writes the file there when done.
  private func queueUpscaledExport(_ upscale: TimelineUpscale) {
    guard let composition, let timeline = store.selected else { return }
    playback.pause()
    let name = "\(history.project.name) \(timeline.name) \(upscale.scale)x"
    fileDialogs.save = FileDialogs.Save(
      // An empty file holds the place until the export replaces it.
      file: ExportedFile(type: .mpeg4Movie) { Data() }, name: name + ".mp4"
    ) { result in
      guard case .success(let url) = result else { return }
      create.queue(
        TimelineExportJob(
          composition: composition, upscale: upscale, title: timeline.name, destination: url))
    }
  }

  /// Writes the timeline to a temporary MP4 (with progress and Cancel), then asks where to save
  /// it, or on iPad saves it to Photos.
  private func export(toPhotos: Bool) {
    guard let composition, let timeline = store.selected, exportProgress == nil else { return }
    playback.pause()
    let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
    let name = "\(history.project.name) \(timeline.name)"
    exportProgress = 0
    exportTask = Task {
      do {
        let progress: @Sendable (Double) -> Void = { fraction in
          Task { @MainActor in if exportProgress != nil { exportProgress = fraction } }
        }
        try await composition.export(
          to: url, codec: .current, title: timeline.name, progress: progress)
        exportProgress = nil
        #if os(iOS)
          if toPhotos {
            try await PhotoLibrary.save([], videos: [url])
            try? FileManager.default.removeItem(at: url)
            return
          }
        #endif
        fileDialogs.save = FileDialogs.Save(
          file: ExportedFile(type: .mpeg4Movie) { try Data(contentsOf: url) },
          name: name + ".mp4"
        ) { _ in try? FileManager.default.removeItem(at: url) }
      } catch {
        exportProgress = nil
        try? FileManager.default.removeItem(at: url)
        if !(error is CancellationError), (error as? AVError)?.code != .operationCancelled {
          failure = "Couldn't export: \(error.localizedDescription)"
        }
      }
    }
  }
}

extension Array {
  subscript(safeIndex index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

/// Plays a timeline's composition.
@MainActor
@Observable
final class TimelinePlayback {
  let player = AVPlayer()
  private(set) var isPlaying = false
  /// Seconds into the timeline, kept current while it plays.
  private(set) var time: Double = 0
  private(set) var duration: Double = 0
  var isLooping = false
  var isMuted = false {
    didSet { player.isMuted = isMuted }
  }
  /// The frame on screen. Drawn here rather than by the system player, whose own controls
  /// would show over the video and not work.
  private(set) var frame: CGImage?
  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var endObserver: NSObjectProtocol?
  @ObservationIgnored private var output: AVPlayerItemVideoOutput?
  @ObservationIgnored private var frameTask: Task<Void, Never>?
  @ObservationIgnored private let context = CIContext()

  init() {
    player.actionAtItemEnd = .pause
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 30), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self, time.seconds.isFinite, self.isPlaying else { return }
        self.time = min(time.seconds, self.duration)
      }
    }
  }

  /// Plays `composition` from where the playhead was (nil empties the player).
  func load(_ composition: TimelineComposition?) {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    guard let composition else {
      player.replaceCurrentItem(with: nil)
      output = nil
      frame = nil
      duration = 0
      time = 0
      isPlaying = false
      frameTask?.cancel()
      return
    }
    let item = composition.playerItem()
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ])
    item.add(output)
    self.output = output
    duration = composition.duration
    player.replaceCurrentItem(with: item)
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reachedEnd() }
    }
    seek(to: min(time, duration))
    if isPlaying {
      player.play()
      followFrames()
    }
  }

  /// Copies the frame for `time` from the video output, when there's a new one.
  @discardableResult
  private func takeFrame(at time: CMTime) -> Bool {
    guard let output, output.hasNewPixelBuffer(forItemTime: time),
          let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    else { return false }
    let image = CIImage(cvPixelBuffer: buffer)
    guard let cgImage = context.createCGImage(image, from: image.extent) else { return false }
    frame = cgImage
    return true
  }

  /// Keeps `frame` current while playing, at the screen's pace.
  private func followFrames() {
    frameTask?.cancel()
    frameTask = Task { [weak self] in
      while let self, self.isPlaying, !Task.isCancelled {
        self.takeFrame(at: self.player.currentTime())
        try? await Task.sleep(for: .milliseconds(15))
      }
    }
  }

  /// Shows the frame at the playhead once a seek lands (decoding it can take a moment).
  private func showFrameAfterSeek() {
    guard !isPlaying else { return }
    frameTask?.cancel()
    frameTask = Task { [weak self] in
      for _ in 0..<60 {
        guard let self, !Task.isCancelled, !self.isPlaying else { return }
        if self.takeFrame(at: self.player.currentTime()) { return }
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }

  private func reachedEnd() {
    if isLooping {
      seek(to: 0)
      player.play()
      followFrames()
    } else {
      isPlaying = false
      time = duration
    }
  }

  func play() {
    guard player.currentItem != nil else { return }
    if time >= duration - 0.01 { seek(to: 0) }
    player.rate = 1
    isPlaying = true
    followFrames()
  }

  /// Plays backwards (J).
  func playBackwards() {
    guard player.currentItem?.canPlayReverse == true else { return }
    player.rate = -1
    isPlaying = true
    followFrames()
  }

  func pause() {
    player.pause()
    isPlaying = false
    let now = player.currentTime().seconds
    if now.isFinite, player.currentItem != nil { time = min(max(now, 0), duration) }
  }

  func togglePlaying() {
    if isPlaying { pause() } else { play() }
  }

  func seek(to seconds: Double) {
    time = min(max(seconds, 0), duration)
    player.seek(
      to: CMTime(seconds: time, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero
    ) { [weak self] _ in
      Task { @MainActor in self?.showFrameAfterSeek() }
    }
  }
}

/// The timeline's video: the player's frames, fitted, on black.
private struct TimelineVideo: View {
  let playback: TimelinePlayback

  var body: some View {
    if let frame = playback.frame {
      Image(decorative: frame, scale: 1)
        .resizable()
        .interpolation(.high)
    } else {
      Color.black
    }
  }
}

/// Play/pause, frame steps, the time and the clip and frame under the playhead, loop and mute.
private struct TimelineTransport: View {
  let playback: TimelinePlayback
  let layout: TimelineLayout
  let playhead: (index: Int, frame: Int)?

  var body: some View {
    HStack(spacing: 10) {
      Button("Previous Frame", systemImage: "backward.frame.fill") { step(-1) }
        .touchTarget()
      Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
        playback.togglePlaying()
      }
      .touchTarget()
      Button("Next Frame", systemImage: "forward.frame.fill") { step(1) }
        .touchTarget()
      Text(Self.time(playback.time) + " / " + Self.time(layout.duration))
        .font(.caption.monospacedDigit())
      if let playhead {
        Text("Clip \(playhead.index + 1), frame \(playhead.frame + 1)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Toggle(isOn: Binding(get: { playback.isLooping }, set: { playback.isLooping = $0 })) {
        Label("Loop", systemImage: "repeat")
      }
      .toggleStyle(.button)
      .touchTarget()
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
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .glassEffect(in: .capsule)
  }

  /// Moves the playhead one frame of the clip under it.
  private func step(_ frames: Int) {
    TimelineStepping.step(frames, playback: playback, layout: layout)
  }

  static func time(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(
      .time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1)))
  }
}

/// The size and frame rate the timeline plays and exports at: its first clip's unless chosen.
private struct TimelineSettings: View {
  let timeline: Timeline
  let layout: TimelineLayout
  let change: ((inout Timeline) -> Void) -> Void
  @Environment(HistoryStore.self) private var history

  private struct Size: Hashable {
    var width: Int
    var height: Int
  }

  /// The sizes of the clips on the timeline.
  private var sizes: [Size] {
    var seen: [Size] = []
    for segment in layout.segments {
      let size = Size(width: segment.item.sidecar.width, height: segment.item.sidecar.height)
      if !seen.contains(size) { seen.append(size) }
    }
    return seen
  }

  private var rates: [Double] {
    Array(Set([24, 25, 30] + layout.segments.map(\.framesPerSecond))).sorted()
  }

  var body: some View {
    Form {
      Picker(
        "Size",
        selection: Binding(
          get: { timeline.width.flatMap { w in timeline.height.map { Size(width: w, height: $0) } } },
          set: { size in change { $0.width = size?.width; $0.height = size?.height } })
      ) {
        Text("First clip's (\(layout.segments.first.map { "\($0.item.sidecar.width) × \($0.item.sidecar.height)" } ?? "none"))")
          .tag(Size?.none)
        ForEach(sizes, id: \.self) { Text("\($0.width) × \($0.height)").tag(Optional($0)) }
      }
      Picker(
        "Frame rate",
        selection: Binding(get: { timeline.framesPerSecond }, set: { fps in change { $0.framesPerSecond = fps } })
      ) {
        Text("First clip's (\(layout.segments.first.map { rate($0.framesPerSecond) } ?? "none"))")
          .tag(Double?.none)
        ForEach(rates, id: \.self) { Text(rate($0)).tag(Optional($0)) }
      }
      Text("Clips of another size fit inside it, on black.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .frame(width: 340)
  }

  private func rate(_ fps: Double) -> String {
    fps.formatted(.number.precision(.fractionLength(0...2))) + " fps"
  }
}

/// The project's videos, newest first, to drag into the track (or double-click to add at the end).
private struct TimelineBin: View {
  let append: (HistoryItem) -> Void
  @Environment(HistoryStore.self) private var history
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation

  var body: some View {
    let videos = history.items.filter(\.isVideo)
    ScrollView {
      if videos.isEmpty {
        ContentUnavailableView(
          "No videos", systemImage: "film",
          description: Text("Videos you make in this project show up here."))
          .padding(.top, 40)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
        ForEach(videos) { item in
          Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ClipThumbnail(item: item) }
            .overlay(alignment: .bottomTrailing) {
              if let clip = item.clip { ClipBadge(clip: clip).padding(4) }
            }
            .clipShape(.rect(cornerRadius: 6))
            .contentShape(.rect)
            .help(item.sidecar.prompt)
            .onTapGesture(count: 2) { append(item) }
            .draggable(TimelineClipDrag.text(item))
            .contextMenu {
              Button("Add to Timeline") { append(item) }
              Button("Show in History") {
                create.show(item)
                navigation.section = .history
              }
            }
        }
      }
      .padding(10)
    }
  }
}

/// A clip dragged from the bin into the track, as text: "atelier-clip:<first frame's tensor>".
enum TimelineClipDrag {
  static func text(_ item: HistoryItem) -> String { "atelier-clip:\(item.tensorId)" }

  static func tensorId(_ text: String) -> Int64? {
    guard text.hasPrefix("atelier-clip:") else { return nil }
    return Int64(text.dropFirst("atelier-clip:".count))
  }
}
