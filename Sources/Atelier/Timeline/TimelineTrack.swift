import SwiftUI

/// The timeline's clips laid end to end as filmstrips, under a ruler, with the playhead. Click to
/// place the playhead and pick a clip, drag a clip to move it, drag its edges to trim it, and drop
/// videos from the bin to add them.
struct TimelineTrack<Menu: View>: View {
  let layout: TimelineLayout
  let playback: TimelinePlayback
  @Binding var selectedEntry: UUID?
  @Binding var trim: (entry: UUID, start: Int, end: Int)?
  let commitTrim: () -> Void
  @ViewBuilder let menu: (Timeline.Entry) -> Menu
  let insert: (HistoryItem, Int) -> Void
  let move: (UUID, Int) -> Void
  @Environment(TimelineStore.self) private var store
  @Environment(HistoryStore.self) private var history
  /// A clip being dragged along the track, and how far.
  @State private var dragging: (entry: UUID, offset: CGFloat)?
  /// The entry as it was when its trim began.
  @State private var trimOrigin: Timeline.Entry?
  @State private var dropTargeted = false
  @FocusState private var focused: Bool
  @State private var scroll = ScrollPosition()
  /// The part of the track on screen, in its own coordinates.
  @State private var visible = CGRect.zero

  private static var rulerHeight: CGFloat { 22 }
  private static var clipHeight: CGFloat { 64 }
  private static var space: String { "TimelineTrack" }

  private var pointsPerSecond: Double { store.pointsPerSecond }

  var body: some View {
    GeometryReader { geometry in
      ScrollView(.horizontal) {
        ZStack(alignment: .topLeading) {
          Color.clear
            .contentShape(.rect)
            .gesture(scrub(selecting: true))
          TimelineRuler(duration: layout.duration, pointsPerSecond: pointsPerSecond)
            .frame(height: Self.rulerHeight)
            .contentShape(.rect)
            .gesture(scrub(selecting: false))
          ForEach(Array(layout.segments.enumerated()), id: \.element.entry.id) { index, segment in
            block(segment, index: index)
              .offset(
                x: segment.start * pointsPerSecond
                  + (dragging?.entry == segment.entry.id ? dragging!.offset : 0),
                y: Self.rulerHeight + 8)
              .zIndex(dragging?.entry == segment.entry.id ? 1 : 0)
          }
          if dropTargeted {
            RoundedRectangle(cornerRadius: 5)
              .strokeBorder(.tint, lineWidth: 2)
              .frame(height: Self.clipHeight + 8)
              .offset(y: Self.rulerHeight + 4)
              .allowsHitTesting(false)
          }
          Rectangle()
            .fill(.red)
            .frame(width: 2)
            .offset(x: playback.time * pointsPerSecond - 1)
            .allowsHitTesting(false)
          if layout.segments.isEmpty {
            Text("Drag videos here")
              .foregroundStyle(.secondary)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .allowsHitTesting(false)
          }
        }
        .frame(
          width: max(layout.duration * pointsPerSecond + 120, geometry.size.width),
          height: geometry.size.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .dropDestination(for: String.self) { texts, location in
          let items = texts.compactMap(TimelineClipDrag.tensorId).compactMap(history.item(tensorId:))
            .filter(\.isVideo)
          guard !items.isEmpty else { return false }
          let index = insertionIndex(at: location.x / pointsPerSecond)
          for (offset, item) in items.enumerated() { insert(item, index + offset) }
          return true
        } isTargeted: { dropTargeted = $0 }
      }
      .scrollPosition($scroll)
      .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { visible = $1 }
      .onChange(of: playback.time) { keepPlayheadVisible() }
      .onChange(of: store.pointsPerSecond) { keepPlayheadVisible() }
      .onChange(of: geometry.size.width, initial: true) { store.trackWidth = geometry.size.width }
    }
    .background(.background.secondary)
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress(.space) {
      playback.togglePlaying()
      return .handled
    }
    .onKeyPress(.leftArrow) {
      TimelineStepping.step(-1, playback: playback, layout: layout)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      TimelineStepping.step(1, playback: playback, layout: layout)
      return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "jkl")) { press in
      switch press.characters {
      case "j": playback.playBackwards()
      case "k": playback.pause()
      default: playback.play()
      }
      return .handled
    }
  }

  /// Dragging along the ruler (or the empty track) moves the playhead.
  private func scrub(selecting: Bool) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
      .onChanged { drag in
        focused = true
        if selecting { selectedEntry = nil }
        playback.pause()
        playback.seek(to: drag.location.x / pointsPerSecond)
      }
  }

  // MARK: - Clips

  private func block(_ segment: TimelineLayout.Segment, index: Int) -> some View {
    let width = max(segment.duration * pointsPerSecond, 8)
    let selected = selectedEntry == segment.entry.id
    return Filmstrip(segment: segment, width: width, height: Self.clipHeight)
      .clipShape(.rect(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.25)), lineWidth: selected ? 2.5 : 1)
      }
      .overlay(alignment: .topLeading) { marks(segment) }
      .overlay(alignment: .leading) { handle(segment, start: true) }
      .overlay(alignment: .trailing) { handle(segment, start: false) }
      .contentShape(.rect)
      .gesture(clipGesture(segment, index: index))
      .contextMenu { menu(segment.entry) }
      .help(segment.item.sidecar.prompt)
  }

  /// Muted, sound and crossfade marks over a clip's corner.
  private func marks(_ segment: TimelineLayout.Segment) -> some View {
    HStack(spacing: 3) {
      if segment.entry.muted {
        Image(systemName: "speaker.slash.fill")
      } else if segment.clip.audioId != nil {
        Image(systemName: "speaker.wave.2.fill")
      }
      if segment.fade > 0 { Image(systemName: "circle.lefthalf.filled") }
    }
    .font(.caption2)
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
    .background(.black.opacity(0.55), in: .capsule)
    .foregroundStyle(.white)
    .padding(4)
    .allowsHitTesting(false)
  }

  /// A click picks the clip and puts the playhead there; a drag moves it among the others.
  private func clipGesture(_ segment: TimelineLayout.Segment, index: Int) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
      .onChanged { drag in
        focused = true
        guard abs(drag.translation.width) > 4 || dragging != nil else { return }
        dragging = (segment.entry.id, drag.translation.width)
      }
      .onEnded { drag in
        defer { dragging = nil }
        guard dragging != nil else {
          selectedEntry = segment.entry.id
          playback.pause()
          playback.seek(to: drag.location.x / pointsPerSecond)
          return
        }
        // Lands among the others by its middle.
        let middle = segment.start + segment.duration / 2 + drag.translation.width / pointsPerSecond
        let others = layout.segments.filter { $0.entry.id != segment.entry.id }
        let target = others.filter { $0.start + $0.duration / 2 < middle }.count
        if target != index { move(segment.entry.id, target) }
        selectedEntry = segment.entry.id
      }
  }

  /// A clip's edge, dragged to trim its first or last frame.
  private func handle(_ segment: TimelineLayout.Segment, start: Bool) -> some View {
    Rectangle()
      .fill(.white.opacity(trim?.entry == segment.entry.id ? 0.6 : 0.001))
      .frame(width: 8)
      .contentShape(.rect)
      #if os(macOS)
        .pointerStyle(.columnResize)
      #endif
      .highPriorityGesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
          .onChanged { drag in
            let origin = trimOrigin?.id == segment.entry.id ? trimOrigin! : segment.entry
            trimOrigin = origin
            let frames = Int((drag.translation.width / pointsPerSecond * segment.framesPerSecond).rounded())
            if start {
              trim = (origin.id, min(max(origin.start + frames, 0), origin.end - 1), origin.end)
            } else {
              trim = (origin.id, origin.start, min(max(origin.end + frames, origin.start + 1), segment.clip.frames.count))
            }
          }
          .onEnded { _ in
            trimOrigin = nil
            commitTrim()
          })
  }

  // MARK: - Positions

  /// Turns the page when the playhead nears the edge of the visible track (playing, stepping, or
  /// a zoom), so it stays in view: it goes back to near the left edge.
  private func keepPlayheadVisible() {
    guard visible.width > 0 else { return }
    let x = playback.time * pointsPerSecond
    let margin = min(40, visible.width / 10)
    guard x < visible.minX + (visible.minX > 0 ? margin : 0) || x > visible.maxX - margin else { return }
    scroll.scrollTo(x: max(x - margin, 0))
  }

  /// Where a clip dropped at `time` goes: before the first clip whose middle is after it.
  private func insertionIndex(at time: Double) -> Int {
    layout.segments.firstIndex { time < $0.start + $0.duration / 2 } ?? layout.segments.count
  }
}

/// Moving the playhead a frame at a time.
@MainActor
enum TimelineStepping {
  /// Moves the playhead `frames` frames of the clip under it, on into the next or previous clip.
  static func step(_ frames: Int, playback: TimelinePlayback, layout: TimelineLayout) {
    playback.pause()
    guard let here = layout.locate(playback.time) else { return }
    var index = here.index
    var frame = here.frame + frames
    let segments = layout.segments
    if frame >= segments[index].entry.end {
      if index + 1 < segments.count {
        // During a crossfade the outgoing clip shows until halfway, so start past that.
        let previous = segments[index]
        index += 1
        let shown = previous.end - previous.fade / 2 - segments[index].start
        frame = segments[index].entry.start + max(Int((shown * segments[index].framesPerSecond).rounded(.up)), 0)
        frame = min(frame, segments[index].entry.end - 1)
      } else {
        frame = segments[index].entry.end - 1
      }
    } else if frame < segments[index].entry.start {
      if index > 0 {
        index -= 1
        frame = segments[index].entry.end - 1
        let segment = segments[index]
        let lastShown = segment.end - segment.fade / 2
        frame = min(frame, segment.entry.start + Int(((lastShown - segment.start) * segment.framesPerSecond).rounded(.down)) - 1)
        frame = max(frame, segment.entry.start)
      } else {
        frame = segments[index].entry.start
      }
    }
    playback.seek(to: layout.time(ofFrame: frame, inSegment: index))
  }
}

/// A clip's frames across its width.
private struct Filmstrip: View {
  let segment: TimelineLayout.Segment
  let width: Double
  let height: Double

  var body: some View {
    let item = segment.item
    let aspect = Double(max(item.sidecar.width, 1)) / Double(max(item.sidecar.height, 1))
    let count = max(1, Int((width / (height * aspect)).rounded(.up)))
    let frames = segment.entry.frameCount
    HStack(spacing: 0) {
      ForEach(0..<count, id: \.self) { k in
        Thumbnail(item: frame(segment.entry.start + min(k * frames / count, frames - 1)))
          .frame(width: width / Double(count), height: height)
          .clipped()
      }
    }
    .frame(width: width, height: height)
  }

  /// The clip's item showing frame `index`'s thumbnail.
  private func frame(_ index: Int) -> HistoryItem {
    var item = segment.item
    item.previewId = segment.clip.previewId(index)
    return item
  }
}

/// Seconds along the top of the track.
private struct TimelineRuler: View {
  let duration: Double
  let pointsPerSecond: Double

  var body: some View {
    Canvas { context, size in
      // A label at least every 60 points.
      let interval = [0.5, 1, 2, 5, 10, 30, 60].first { $0 * pointsPerSecond >= 60 } ?? 120
      var second = 0.0
      while second * pointsPerSecond <= size.width {
        let x = second * pointsPerSecond
        context.fill(
          Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary))
        context.draw(
          Text(
            Duration.seconds(second).formatted(
              .time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: interval < 1 ? 1 : 0))))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary),
          at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
        second += interval
      }
    }
  }
}

/// View ▸ Zoom In, Zoom Out and Zoom to Fit while Timeline is on screen, with the canvas's keys.
struct TimelineZoomMenuItems: View {
  let store: TimelineStore
  let history: HistoryStore

  var body: some View {
    Button("Zoom In") { store.zoomIn() }
      .keyboardShortcut("=", modifiers: .command)
    Button("Zoom Out") { store.zoomOut() }
      .keyboardShortcut("-", modifiers: .command)
    Button("Zoom to Fit") {
      if let timeline = store.selected {
        store.zoomToFit(duration: TimelineLayout(timeline, item: history.item(tensorId:)).duration)
      }
    }
    .keyboardShortcut("9", modifiers: .command)
  }
}

/// − / a zoom slider / + and Fit, over the track's corner. The slider moves in equal steps of
/// scale, so each part of its travel zooms as much.
struct TimelineZoomControl: View {
  let duration: Double
  @Environment(TimelineStore.self) private var store

  var body: some View {
    let range = TimelineStore.zoomRange
    HStack(spacing: 6) {
      Button("Zoom Out", systemImage: "minus.magnifyingglass") { store.zoomOut() }
        .help("Zoom Out (⌘−)")
        .touchTarget()
      Slider(
        value: Binding(
          get: { log(store.pointsPerSecond) },
          set: { store.pointsPerSecond = exp($0) }),
        in: log(range.lowerBound)...log(range.upperBound)
      )
      .frame(width: 120)
      .controlSize(.small)
      .help("Zoom the track")
      Button("Zoom In", systemImage: "plus.magnifyingglass") { store.zoomIn() }
        .help("Zoom In (⌘+)")
        .touchTarget()
      Button("Fit") { store.zoomToFit(duration: duration) }
        .help("Fit the timeline in the track (⌘9)")
        .disabled(duration <= 0)
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .glassEffect(in: .capsule)
  }
}
