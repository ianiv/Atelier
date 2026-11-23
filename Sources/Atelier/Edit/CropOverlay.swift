import SwiftUI

/// A drag of the Crop tool under way, written by the pane's gesture and read only by the
/// overlay: the pane's body never reads it, so a drag redraws the rectangle, not the pane.
@MainActor
@Observable
final class CropDrag {
  /// The rectangle being dragged, in source pixels; nil when no drag is under way (or a drag
  /// outside hasn't gone far enough to be a rectangle yet).
  var draft: CGRect?

  /// What the drag started from: the handle (nil for a new rectangle drawn outside) and the
  /// rectangle it held.
  @ObservationIgnored private var start: (handle: CropGeometry.Handle?, rect: CGRect)?

  /// How near a handle, in points, a drag starts on it: a finger's reach on iPad.
  #if os(macOS)
  static let reach: Double = 8
  #else
  static let reach: Double = 22
  #endif

  var isDragging: Bool { start != nil }

  /// The drag has moved to `location` from `startLocation` (both in the pane's points). `crop`
  /// is the crop there is (nil: the whole image, which a handle drag starts from).
  func changed(from startLocation: CGPoint, to location: CGPoint, crop: Edit.Crop?, image: (width: Int, height: Int), viewport: EditViewport) {
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
    } else {
      draft = CropGeometry.drawn(
        from: viewport.imagePoint(startLocation), to: viewport.imagePoint(location), ratio: ratio, bounds: bounds, minimum: minimum)
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
    return Edit.Crop(rect: draft, imageWidth: image.width, imageHeight: image.height, aspect: crop?.aspect, swapped: crop?.swapped ?? false)
  }

  /// The drag was cancelled (another tool, the pane went away).
  func cancel() {
    start = nil
    draft = nil
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
