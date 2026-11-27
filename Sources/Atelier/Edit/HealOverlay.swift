import SwiftUI

/// A touch of the Heal tool under way, written by the pane's gesture and read only by the overlay
/// (as `CropDrag` is for Crop): the pane's body never reads it, so painting redraws the overlay,
/// not the pane.
///
/// It keeps a pinch apart from the brush the way `CropDrag` does. The pane's drag runs alongside
/// its pinch, so on iPad a two-finger pinch reaches the drag too: once a pinch starts, the stroke
/// on its way is dropped and every drag event is a pan of the view (`pinchPan`) until both
/// gestures have ended, and nothing is healed (`dragEnded`). A pinch never paints.
@MainActor
@Observable
final class HealDrag {
  /// What a touch does, decided at its first event: paint a stroke, or set the source (Set Source
  /// on, or Option held on the Mac).
  enum Mode: Sendable {
    case paint, source
  }

  /// The stroke being painted (or the source being placed), in image pixels; empty when no
  /// touch is under way.
  var points: [CGPoint] = []
  private(set) var mode: Mode?
  /// The pointer over the pane, in the pane's points: where the brush outline is drawn while not
  /// painting. Nil off the pane, and on iPad until a trackpad's pointer or a Pencil hovers (a
  /// finger has no hover).
  var hover: CGPoint?

  @ObservationIgnored private(set) var dragActive = false
  @ObservationIgnored private(set) var pinchActive = false
  /// A pinch began during this touch: nothing is healed until both gestures end.
  @ObservationIgnored private(set) var pinched = false
  /// Since the pinch began, how far the drag (the fingers' centre on iPad) has moved, in points.
  @ObservationIgnored private(set) var pinchPan = CGSize.zero
  @ObservationIgnored private var panBase: CGSize?
  @ObservationIgnored private var lastTranslation = CGSize.zero
  /// The pinch's last magnification and where it began (from the pane's centre).
  @ObservationIgnored var pinchZoom: (magnification: Double, anchor: CGPoint)?

  var isActive: Bool { mode != nil }

  /// The drag moved by `translation`: false when it's a pinch's (a pan, `pinchPan` updated), true
  /// when it's the brush's and the caller goes on to `move(to:)`.
  func dragChanged(translation: CGSize) -> Bool {
    dragActive = true
    lastTranslation = translation
    guard pinched else { return true }
    let base = panBase ?? translation
    panBase = base
    pinchPan = CGSize(width: translation.width - base.width, height: translation.height - base.height)
    return false
  }

  /// A pinch changed: the first change drops the stroke on its way.
  func pinchChanged() {
    pinchActive = true
    guard !pinched else { return }
    cancel()
    pinched = true
    panBase = dragActive ? lastTranslation : nil
    pinchPan = .zero
  }

  /// The pinch ended; the touch is over once the drag has too.
  func pinchEnded() {
    pinchActive = false
    if !dragActive { endTouch() }
  }

  /// The touch's first event: what it does.
  func begin(_ mode: Mode) {
    guard !pinched, self.mode == nil else { return }
    self.mode = mode
    points = []
  }

  /// The brush (or the source being placed) is at `point` (image pixels). A painted stroke keeps
  /// points at least `spacing` apart (the brush resamples between them anyway), so a slow drag
  /// doesn't store hundreds of points on top of each other.
  func move(to point: CGPoint, spacing: Double) {
    guard !pinched, let mode, point.x.isFinite, point.y.isFinite else { return }
    switch mode {
    case .source:
      points = [point]
    case .paint:
      if let last = points.last, hypot(point.x - last.x, point.y - last.y) < spacing { return }
      points.append(point)
    }
  }

  /// The drag let go: what it did and where, or nil when it did nothing or a pinch took the touch.
  func dragEnded() -> (mode: Mode, points: [CGPoint])? {
    dragActive = false
    defer {
      cancel()
      if !pinchActive { endTouch() }
    }
    guard !pinched, let mode, !points.isEmpty else { return nil }
    return (mode, points)
  }

  /// The touch was dropped (another tool, the pane went away, a pinch).
  func cancel() {
    mode = nil
    if !points.isEmpty { points = [] }
  }

  private func endTouch() {
    pinched = false
    pinchZoom = nil
    panBase = nil
    pinchPan = .zero
  }

  /// The pane's gestures are over, ended or cancelled (SwiftUI calls no `onEnded` for a cancelled
  /// one): nothing is left set for the next touch.
  func reset() {
    cancel()
    dragActive = false
    pinchActive = false
    endTouch()
  }
}

/// The Heal tool's drawing over the image: the brush outline at the pointer (`BrushOutline`), the
/// stroke being painted and any not yet healed in, and the source crosshair, which follows the
/// brush at the offset while painting (so you see what's being copied) and rests at the source
/// otherwise. It takes no hits: the pane's own drag paints (`HealDrag`).
///
/// Strokes and the source are in the source's pixels; the pane shows the working image, which a
/// crop moves by `origin` (`EditModel.workingOrigin`), so every point is mapped through it.
struct HealOverlay: View {
  @Environment(EditModel.self) private var edit
  let drag: HealDrag
  let viewport: EditViewport
  let origin: CGPoint
  /// Whether the outline stands in for the pointer when not painting: not while a click sets the
  /// source (the pointer is a crosshair then) or Space pans.
  var showsOutline = true

  /// A source pixel in the pane's points.
  private func view(_ point: CGPoint) -> CGPoint {
    viewport.viewPoint(CGPoint(x: point.x - origin.x, y: point.y - origin.y))
  }

  /// The source pixel under a point of the pane.
  private func source(_ point: CGPoint) -> CGPoint {
    let p = viewport.imagePoint(point)
    return CGPoint(x: p.x + origin.x, y: p.y + origin.y)
  }

  var body: some View {
    let ppp = viewport.pointsPerPixel
    let radius = edit.healBrushSize
    let painting = drag.mode == .paint ? drag.points : []
    ZStack(alignment: .topLeading) {
      // Strokes painted, and the one under way: a light band the brush's width.
      Path { path in
        for stroke in edit.unappliedHealStrokes { add(stroke.points.map { CGPoint(x: Double($0.x), y: Double($0.y)) }, to: &path) }
        add(painting, to: &path)
      }
      .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: max(radius * 2 * ppp, 1), lineCap: .round, lineJoin: .round))
      // The faint inner ring is where the feather begins, as new strokes are made.
      BrushOutline(
        center: painting.isEmpty && !showsOutline ? nil : brushCenter(painting), radius: radius, pointsPerPixel: ppp,
        innerRadius: BrushOutline.innerRadius(radius: radius, feather: Double(Edit.HealStroke.defaultFeather)))
      if let source = sourcePoint(painting) {
        Crosshair().position(view(source))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// A polyline in source pixels as the pane's points (a single point as a dot: a round cap on a
  /// line of almost no length).
  private func add(_ points: [CGPoint], to path: inout Path) {
    guard let first = points.first else { return }
    let start = view(first)
    path.move(to: start)
    if points.count == 1 {
      path.addLine(to: CGPoint(x: start.x + 0.01, y: start.y))
      return
    }
    for point in points.dropFirst() { path.addLine(to: view(point)) }
  }

  /// Where the brush outline goes: on the stroke being painted, else at the pointer.
  private func brushCenter(_ painting: [CGPoint]) -> CGPoint? {
    if let last = painting.last { return view(last) }
    return drag.hover
  }

  /// Where the source crosshair goes (image pixels): following the brush at the offset while
  /// painting or hovering once the offset is fixed, else at rest; nil with no source.
  private func sourcePoint(_ painting: [CGPoint]) -> CGPoint? {
    guard let healSource = edit.healSource else { return nil }
    let brush = painting.last ?? drag.hover.map(source)
    switch healSource {
    case .point(let point):
      // Fixed by this stroke's first point once painting begins.
      if let first = painting.first, let last = painting.last {
        return CGPoint(x: Double(point.x) + last.x - first.x, y: Double(point.y) + last.y - first.y)
      }
      return CGPoint(x: Double(point.x), y: Double(point.y))
    case .offset(let offset):
      if let brush { return CGPoint(x: brush.x + Double(offset.x), y: brush.y + Double(offset.y)) }
      return edit.healSourceRest.map { CGPoint(x: Double($0.x), y: Double($0.y)) }
    }
  }
}

/// The source mark: a cross in a circle, white over a dark edge so it shows on any image.
private struct Crosshair: View {
  var body: some View {
    ZStack {
      shape.stroke(.black.opacity(0.7), lineWidth: 3)
      shape.stroke(.white, lineWidth: 1.5)
    }
    .frame(width: 22, height: 22)
  }

  private var shape: Path {
    Path { path in
      path.addEllipse(in: CGRect(x: 5, y: 5, width: 12, height: 12))
      path.move(to: CGPoint(x: 11, y: 0))
      path.addLine(to: CGPoint(x: 11, y: 7))
      path.move(to: CGPoint(x: 11, y: 15))
      path.addLine(to: CGPoint(x: 11, y: 22))
      path.move(to: CGPoint(x: 0, y: 11))
      path.addLine(to: CGPoint(x: 7, y: 11))
      path.move(to: CGPoint(x: 15, y: 11))
      path.addLine(to: CGPoint(x: 22, y: 11))
    }
  }
}
