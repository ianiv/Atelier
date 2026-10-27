import Foundation
import Observation

/// Clips from a project put in order: each entry plays part of a clip (from `start` up to, not
/// including, `end`). Nothing is copied; entries name their clip by its first frame's image
/// tensor, which a fork or delete doesn't change.
struct Timeline: Codable, Identifiable, Hashable {
  struct Entry: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The clip, by its first frame's image tensor (`HistoryItem.tensorId`).
    var clip: Int64
    /// The first frame played, and the one after the last.
    var start: Int
    var end: Int
    var muted = false
    /// Frames this entry fades over into the next one.
    var crossfadeFrames = 0
    /// The Continue from Here or Bridge run that put it here (`TimelinePlacement.id`).
    var placement: UUID?

    var frameCount: Int { end - start }
  }

  var id = UUID()
  var name: String
  var entries: [Entry] = []
  /// The size and rate it plays and exports at; nil takes the first clip's.
  var width: Int?
  var height: Int?
  var framesPerSecond: Double?
}

/// Where a run started from a timeline frame goes when it finishes: right after that frame (the
/// rest of the entry is cut off), or for a bridge, between that frame and the next entry.
struct TimelinePlacement: Codable, Hashable, Sendable {
  var id = UUID()
  var project: String
  var timeline: UUID
  var entry: UUID
  /// The frame the run starts from, in the entry's clip.
  var frame: Int
  /// Its image tensor: the run takes the placement while the canvas still shows this frame.
  var frameTensorId: Int64
  /// Bridge: the entry whose first frame the run ends on.
  var bridgesTo: UUID?
}

/// Where each entry plays, in seconds: entries follow one another, overlapping by their
/// crossfades. Entries whose clip is gone are left out.
struct TimelineLayout {
  struct Segment {
    var entry: Timeline.Entry
    var item: HistoryItem
    var start: Double
    var duration: Double
    /// Seconds it overlaps the next segment by.
    var fade: Double
    var framesPerSecond: Double

    var end: Double { start + duration }
    var clip: ClipInfo { item.clip! }
  }

  var segments: [Segment] = []
  var duration: Double = 0
  var width = 0
  var height = 0
  var framesPerSecond: Double = 24

  init() {}

  init(_ timeline: Timeline, item: (Int64) -> HistoryItem?) {
    var segments: [Segment] = []
    for entry in timeline.entries {
      guard let item = item(entry.clip), let clip = item.clip, clip.framesPerSecond > 0,
            entry.start >= 0, entry.end <= clip.frames.count, entry.frameCount > 0
      else { continue }
      segments.append(
        Segment(
          entry: entry, item: item, start: 0,
          duration: Double(entry.frameCount) / clip.framesPerSecond, fade: 0,
          framesPerSecond: clip.framesPerSecond))
    }
    var cursor = 0.0
    for index in segments.indices {
      segments[index].start = cursor
      if index + 1 < segments.count {
        let wanted = Double(segments[index].entry.crossfadeFrames) / segments[index].framesPerSecond
        segments[index].fade = min(wanted, segments[index].duration / 2, segments[index + 1].duration / 2)
      }
      cursor += segments[index].duration - segments[index].fade
    }
    self.segments = segments
    duration = cursor
    let first = segments.first
    width = timeline.width ?? first?.item.sidecar.width ?? 512
    height = timeline.height ?? first?.item.sidecar.height ?? 512
    framesPerSecond = timeline.framesPerSecond ?? first?.framesPerSecond ?? 24
  }

  /// The segment playing at `time` (the outgoing one during a crossfade) and the frame of its
  /// clip on screen.
  func locate(_ time: Double) -> (index: Int, frame: Int)? {
    guard !segments.isEmpty else { return nil }
    let index = segments.firstIndex { time < $0.end - $0.fade / 2 } ?? segments.count - 1
    let segment = segments[index]
    let offset = Int(((time - segment.start) * segment.framesPerSecond + 1e-6).rounded(.down))
    return (index, segment.entry.start + min(max(offset, 0), segment.entry.frameCount - 1))
  }

  /// When frame `frame` of segment `index`'s clip shows.
  func time(ofFrame frame: Int, inSegment index: Int) -> Double {
    let segment = segments[index]
    return segment.start + Double(frame - segment.entry.start) / segment.framesPerSecond
  }

  func index(of entry: UUID) -> Int? {
    segments.firstIndex { $0.entry.id == entry }
  }
}

/// The current project's timelines, kept in the project file (`Project.timelinesJSON`). Edits
/// are undoable in the window's undo stack.
@MainActor
@Observable
final class TimelineStore {
  private let history: HistoryStore
  private(set) var timelines: [Timeline] = []
  /// The project `timelines` were read from.
  private var loadedProject: String?
  /// The timeline on screen.
  var selectedId: UUID?
  /// Points per second of video in the track.
  var pointsPerSecond: Double = 120
  /// The track's visible width, for Zoom to Fit.
  var trackWidth: Double = 800

  /// The closest and farthest the track zooms, in points per second.
  static let zoomRange: ClosedRange<Double> = 4...2000

  func zoomIn() { pointsPerSecond = min(pointsPerSecond * 1.5, Self.zoomRange.upperBound) }
  func zoomOut() { pointsPerSecond = max(pointsPerSecond / 1.5, Self.zoomRange.lowerBound) }

  /// Fits the timeline on screen.
  func zoomToFit(duration: Double) {
    guard duration > 0 else { return }
    pointsPerSecond = min(max((trackWidth - 140) / duration, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
  }

  init(history: HistoryStore) {
    self.history = history
  }

  /// The timeline on screen (once `load` has read the project's).
  var selected: Timeline? {
    timelines.first { $0.id == selectedId } ?? timelines.first
  }

  /// Reads the current project's timelines, when they aren't the ones loaded.
  func load() {
    let project = history.project
    guard loadedProject != project.name else { return }
    loadedProject = project.name
    timelines = project.timelinesJSON.flatMap { Self.decode($0) } ?? []
    if !timelines.contains(where: { $0.id == selectedId }) { selectedId = timelines.first?.id }
  }

  private func save() {
    guard loadedProject == history.project.name else { return }
    history.project.timelinesJSON =
      timelines.isEmpty ? nil : (try? JSONEncoder().encode(timelines)).map { String(decoding: $0, as: UTF8.self) }
  }

  private static func decode(_ json: String) -> [Timeline]? {
    try? JSONDecoder().decode([Timeline].self, from: Data(json.utf8))
  }

  /// Replaces every timeline, undoably as `actionName`.
  private func set(_ new: [Timeline], actionName: String, undoManager: UndoManager?) {
    let old = timelines
    let project = loadedProject
    timelines = new
    save()
    guard let undoManager else { return }
    undoManager.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        // Another project's timelines are no longer on screen.
        guard target.loadedProject == project else { return }
        target.set(old, actionName: actionName, undoManager: undoManager)
      }
    }
    undoManager.setActionName(actionName)
  }

  /// Changes one timeline.
  func edit(
    _ id: UUID, _ actionName: String, undoManager: UndoManager?, _ change: (inout Timeline) -> Void
  ) {
    load()
    var new = timelines
    guard let index = new.firstIndex(where: { $0.id == id }) else { return }
    change(&new[index])
    guard new != timelines else { return }
    set(new, actionName: actionName, undoManager: undoManager)
  }

  /// A name not taken yet: "Timeline 1", "Timeline 2", …
  private var nextName: String {
    var n = timelines.count + 1
    while timelines.contains(where: { $0.name == "Timeline \(n)" }) { n += 1 }
    return "Timeline \(n)"
  }

  @discardableResult
  func newTimeline(undoManager: UndoManager?) -> UUID {
    load()
    let timeline = Timeline(name: nextName)
    set(timelines + [timeline], actionName: "New Timeline", undoManager: undoManager)
    selectedId = timeline.id
    return timeline.id
  }

  func rename(_ id: UUID, to name: String, undoManager: UndoManager?) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    edit(id, "Rename Timeline", undoManager: undoManager) { $0.name = name }
  }

  func delete(_ id: UUID, undoManager: UndoManager?) {
    load()
    set(timelines.filter { $0.id != id }, actionName: "Delete Timeline", undoManager: undoManager)
    if selectedId == id { selectedId = timelines.first?.id }
  }

  /// An entry playing the whole clip.
  static func entry(for item: HistoryItem) -> Timeline.Entry? {
    guard let clip = item.clip, !clip.frames.isEmpty else { return nil }
    return Timeline.Entry(clip: item.tensorId, start: 0, end: clip.frames.count)
  }

  /// Adds clips to the end of the timeline on screen (a new one when there's none).
  func append(_ items: [HistoryItem], undoManager: UndoManager?) {
    let entries = items.compactMap(Self.entry(for:))
    guard !entries.isEmpty else { return }
    let id = selected?.id ?? newTimeline(undoManager: undoManager)
    edit(id, "Add to Timeline", undoManager: undoManager) { $0.entries += entries }
  }

  /// Puts a clip in the timeline at `index`.
  func insert(_ item: HistoryItem, at index: Int, in id: UUID, undoManager: UndoManager?) {
    guard let entry = Self.entry(for: item) else { return }
    edit(id, "Add to Timeline", undoManager: undoManager) {
      $0.entries.insert(entry, at: min(max(index, 0), $0.entries.count))
    }
  }

  /// The timelines that play the clip.
  func timelines(using tensorId: Int64) -> [Timeline] {
    load()
    return timelines.filter { $0.entries.contains { $0.clip == tensorId } }
  }

  /// Takes deleted clips out of every timeline.
  func removeClips(_ tensorIds: Set<Int64>) {
    load()
    var new = timelines
    for index in new.indices { new[index].entries.removeAll { tensorIds.contains($0.clip) } }
    guard new != timelines else { return }
    timelines = new
    save()
  }

  /// Puts a finished run started from a timeline frame where it was asked for. Only the first
  /// take of a placement goes in; ×N's other takes stay in History. When the entry is gone, the
  /// clip goes at the end.
  func place(_ item: HistoryItem, at placement: TimelinePlacement) {
    load()
    guard placement.project == loadedProject, let clip = item.clip,
          var timeline = timelines.first(where: { $0.id == placement.timeline }),
          !timeline.entries.contains(where: { $0.placement == placement.id })
    else { return }
    // The clip's first frame repeats the one it started from, and a bridge's last frame the next
    // entry's first: both are trimmed so the joins don't stutter.
    var entry = Timeline.Entry(
      clip: item.tensorId, start: clip.frames.count > 1 ? 1 : 0, end: clip.frames.count,
      placement: placement.id)
    if placement.bridgesTo != nil, entry.frameCount > 1 { entry.end -= 1 }
    if let index = timeline.entries.firstIndex(where: { $0.id == placement.entry }) {
      let source = timeline.entries[index]
      if (source.start..<source.end).contains(placement.frame) {
        timeline.entries[index].end = placement.frame + 1
        timeline.entries[index].crossfadeFrames = 0
      }
      timeline.entries.insert(entry, at: index + 1)
    } else {
      timeline.entries.append(entry)
    }
    guard let index = timelines.firstIndex(where: { $0.id == timeline.id }) else { return }
    timelines[index] = timeline
    save()
  }
}
