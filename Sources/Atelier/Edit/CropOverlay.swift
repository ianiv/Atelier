import SwiftUI

/// A drag of the Crop tool under way, written by the pane's gesture and read only by the
/// overlay: the pane's body never reads it, so a drag redraws the rectangle, not the pane.
///
/// It also keeps a pinch apart from the crop. The pane's drag runs alongside its pinch, so on
/// iPad a two-finger pinch reaches the drag too: once a pinch starts, the drag on its way is
/// dropped and every drag event is a pan of the view (`pinchPan`) until both gestures have
/// ended, and nothing is committed (`dragEnded`).
@MainActor
@Observable
final class CropDrag {
  /// The rectangle being dragged, in source pixels; nil when no drag is under way (or a drag
  /// outside hasn't gone far enough to be a rectangle yet).
  var draft: CGRect?

  /// What the drag started from: the handle (nil for a new rectangle drawn outside) and the
  /// rectangle it held.
  @ObservationIgnored private var start: (handle: CropGeometry.Handle?, rect: CGRect)?
  /// The part of the draft that stays put while its size is made whole (`Edit.Crop.init(rect:…)`).
  @ObservationIgnored private var anchor = CGPoint(x: 0.5, y: 0.5)

  /// The gestures in play: the drag's and the pinch's, each between its first change and its end.
  @ObservationIgnored private(set) var dragActive = false
  @ObservationIgnored private(set) var pinchActive = false
  /// A pinch began during this touch: no crop is edited until both gestures end.
  @ObservationIgnored private(set) var pinched = false
  /// Since the pinch began, how far the drag (the fingers' centre on iPad) has moved, in points:
  /// what two fingers pan the view by while they zoom it.
  @ObservationIgnored private(set) var pinchPan = CGSize.zero
  @ObservationIgnored private var panBase: CGSize?

  /// How near a handle, in points, a drag starts on it: a finger's reach on iPad.
  #if os(macOS)
  static let reach: Double = 8
  #else
  static let reach: Double = 22
  #endif

  var isDragging: Bool { start != nil }

  /// The drag moved by `translation`: false when it's a pinch's (a pan, `pinchPan` updated), true
  /// when it edits the crop and the caller goes on to `changed`.
  func dragChanged(translation: CGSize) -> Bool {
    dragActive = true
    lastTranslation = translation
    guard pinched else { return true }
    let base = panBase ?? translation
    panBase = base
    pinchPan = CGSize(width: translation.width - base.width, height: translation.height - base.height)
    return false
  }

  /// A pinch changed: the first change drops the crop drag on its way (its draft too).
  func pinchChanged() {
    pinchActive = true
    guard !pinched else { return }
    cancel()
    pinched = true
    panBase = dragActive ? lastTranslation : nil
    pinchPan = .zero
  }

  @ObservationIgnored private var lastTranslation = CGSize.zero
  /// The pinch's last magnification and where it began (from the pane's centre), so a drag event
  /// can put the zoom and the pan together again (`EditPane.applyPinch`).
  @ObservationIgnored var pinchZoom: (magnification: Double, anchor: CGPoint)?

  /// The pinch ended; the touch is over once the drag has too.
  func pinchEnded() {
    pinchActive = false
    if !dragActive { endTouch() }
  }

  /// The drag let go: the crop it made, or nil when it made none or a pinch took the touch.
  func dragEnded(crop: Edit.Crop?, image: (width: Int, height: Int)) -> Edit.Crop? {
    dragActive = false
    defer { if !pinchActive { endTouch() } }
    guard !pinched, isDragging else {
      cancel()
      return nil
    }
    return ended(crop: crop, image: image)
  }

  private func endTouch() {
    pinched = false
    pinchZoom = nil
    panBase = nil
    pinchPan = .zero
  }

  /// The drag has moved to `location` from `startLocation` (both in the pane's points). `crop`
  /// is the crop there is (nil: the whole image, which a handle drag starts from).
  func changed(from startLocation: CGPoint, to location: CGPoint, crop: Edit.Crop?, image: (width: Int, height: Int), viewport: EditViewport) {
    guard !pinched else { return }
    let bounds = CGSize(width: image.width, height: image.height)
    let current = crop?.rect ?? CGRect(origin: .zero, size: bounds)
    if start == nil {
      start = (CropGeometry.handle(at: startLocation, rect: viewport.viewRect(current), reach: Self.reach), current)
    }
    guard let start else { return }
    let ratio = crop?.ratio(imageWidth: image.width, imageHeight: image.height)
    let minimum = Double(Edit.Crop.minimumSide)
    if let handle = start.handle {
      let ppp = max(viewport.pointsPerPixel, 1e-6)
      let delta = CGSize(width: (location.x - startLocation.x) / ppp, height: (location.y - startLocation.y) / ppp)
      draft = CropGeometry.drag(handle, from: start.rect, by: delta, ratio: ratio, bounds: bounds, minimum: minimum)
      // The side opposite the one dragged stays; an edge's cross axis keeps its centre.
      let (sx, sy) = handle.sides
      anchor = CGPoint(x: sx < 0 ? 1 : sx > 0 ? 0 : 0.5, y: sy < 0 ? 1 : sy > 0 ? 0 : 0.5)
    } else {
      draft = CropGeometry.drawn(
        from: viewport.imagePoint(startLocation), to: viewport.imagePoint(location), ratio: ratio, bounds: bounds, minimum: minimum)
      // Drawn from where the drag began.
      anchor = CGPoint(x: location.x < startLocation.x ? 1 : 0, y: location.y < startLocation.y ? 1 : 0)
    }
  }

  /// The drag let go: the crop it made, kept to the crop's ratio and orientation, or nil when it
  /// made none (a click outside, say).
  func ended(crop: Edit.Crop?, image: (width: Int, height: Int)) -> Edit.Crop? {
    defer {
      start = nil
      draft = nil
    }
    guard let draft else { return nil }
    return Edit.Crop(
      rect: draft, imageWidth: image.width, imageHeight: image.height, aspect: crop?.aspect, swapped: crop?.swapped ?? false, anchor: anchor)
  }

  /// The drag was cancelled (another tool, the pane went away, a pinch).
  func cancel() {
    start = nil
    draft = nil
  }

  /// The pane's gestures are over, ended or cancelled: SwiftUI calls no `onEnded` for a cancelled
  /// gesture (a system interruption, the pane going away mid-touch), so the pane calls this when
  /// its `moving` state goes back, and nothing is left set for the next touch.
  func reset() {
    cancel()
    dragActive = false
    pinchActive = false
    endTouch()
  }
}

/// The Crop tool's drawing over the whole image: outside the crop dimmed, its border, eight
/// handles, and the rule-of-thirds grid while it's dragged. It takes no hits: the pane's own drag
/// moves the handles (`CropDrag`), so pinching and double-clicking still reach the pane.
struct CropOverlay: View {
  @Environment(EditModel.self) private var edit
  let drag: CropDrag
  let viewport: EditViewport

  var body: some View {
    let image = CGRect(x: 0, y: 0, width: viewport.imageWidth, height: viewport.imageHeight)
    let rect = viewport.viewRect(drag.draft ?? edit.retouch.crop?.rect ?? image)
    let frame = viewport.viewRect(image)
    ZStack(alignment: .topLeading) {
      // The image outside the crop, dimmed: the frame with the crop cut out.
      Path { path in
        path.addRect(frame)
        path.addRect(rect)
      }
      .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
      if drag.draft != nil {
        Path { path in
          for third in [1.0 / 3, 2.0 / 3] {
            path.move(to: CGPoint(x: rect.minX + rect.width * third, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * third, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * third))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * third))
          }
        }
        .stroke(.white.opacity(0.6), lineWidth: 0.5)
      }
      Rectangle()
        .stroke(.white, lineWidth: 1)
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
      ForEach(CropGeometry.Handle.grabbable, id: \.self) { handle in
        let point = handle.point(in: rect)
        handleShape(handle)
          .position(point)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// A corner's L or an edge's bar, white over a dark edge so it shows on any image.
  private func handleShape(_ handle: CropGeometry.Handle) -> some View {
    let length: Double = handle.isCorner ? 16 : 20
    let horizontal = handle.sides.y != 0 && !handle.isCorner
    return Group {
      if handle.isCorner {
        Path { path in
          let (sx, sy) = handle.sides
          let x = Double(-sx) * length / 2, y = Double(-sy) * length / 2
          path.move(to: CGPoint(x: length / 2 + x, y: length / 2))
          path.addLine(to: CGPoint(x: length / 2, y: length / 2))
          path.addLine(to: CGPoint(x: length / 2, y: length / 2 + y))
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
        .shadow(color: .black.opacity(0.6), radius: 1)
        .frame(width: length, height: length)
      } else {
        Capsule()
          .fill(.white)
          .shadow(color: .black.opacity(0.6), radius: 1)
          .frame(width: horizontal ? length : 4, height: horizontal ? 4 : length)
      }
    }
  }
}
