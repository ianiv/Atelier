@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// The Edit screen's Crop: the rectangle's geometry (`CropGeometry`) as the overlay drags it, the
/// crop kept whole and inside the image (`Edit.Crop`), the ratio presets, the view-to-image
/// mapping the overlay goes through (`EditViewport`), `crop_image`'s arguments, and reading a
/// crop from a file leniently.
@Suite(.tags(.smoke))
struct CropTests {
  private let bounds = CGSize(width: 1000, height: 800)

  private func near(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 1e-6) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
  }

  @Test func freeCornerDragMovesOnlyThatCorner() {
    let start = CGRect(x: 100, y: 100, width: 400, height: 300)
    let dragged = CropGeometry.drag(.bottomRight, from: start, by: CGSize(width: 50, height: -20), ratio: nil, bounds: bounds, minimum: 16)
    #expect(near(dragged, CGRect(x: 100, y: 100, width: 450, height: 280)))
    let topLeft = CropGeometry.drag(.topLeft, from: start, by: CGSize(width: -30, height: 40), ratio: nil, bounds: bounds, minimum: 16)
    #expect(near(topLeft, CGRect(x: 70, y: 140, width: 430, height: 260)))
  }

  @Test func freeEdgeDragMovesOnlyThatEdge() {
    let start = CGRect(x: 100, y: 100, width: 400, height: 300)
    let left = CropGeometry.drag(.left, from: start, by: CGSize(width: 40, height: 99), ratio: nil, bounds: bounds, minimum: 16)
    #expect(near(left, CGRect(x: 140, y: 100, width: 360, height: 300)))
    let bottom = CropGeometry.drag(.bottom, from: start, by: CGSize(width: 99, height: 25), ratio: nil, bounds: bounds, minimum: 16)
    #expect(near(bottom, CGRect(x: 100, y: 100, width: 400, height: 325)))
  }

  @Test func heldCornerDragKeepsTheOppositeCornerAndRatio() {
    let start = CGRect(x: 100, y: 100, width: 400, height: 500)
    let dragged = CropGeometry.drag(.bottomRight, from: start, by: CGSize(width: 100, height: 10), ratio: 0.8, bounds: bounds, minimum: 16)
    #expect(dragged.minX == 100 && dragged.minY == 100)
    #expect(abs(dragged.width / dragged.height - 0.8) < 1e-9)
    // From the top left: the bottom right stays.
    let fromTopLeft = CropGeometry.drag(.topLeft, from: start, by: CGSize(width: -50, height: -10), ratio: 0.8, bounds: bounds, minimum: 16)
    #expect(abs(fromTopLeft.maxX - 500) < 1e-9 && abs(fromTopLeft.maxY - 600) < 1e-9)
    #expect(abs(fromTopLeft.width / fromTopLeft.height - 0.8) < 1e-9)
  }

  @Test func heldDragStopsAtTheImageEdge() {
    let start = CGRect(x: 100, y: 100, width: 400, height: 500)
    let dragged = CropGeometry.drag(.bottomRight, from: start, by: CGSize(width: 2000, height: 2000), ratio: 0.8, bounds: bounds, minimum: 16)
    #expect(dragged.maxX <= bounds.width + 1e-9 && dragged.maxY <= bounds.height + 1e-9)
    #expect(abs(dragged.width / dragged.height - 0.8) < 1e-9)
    #expect(abs(dragged.maxY - bounds.height) < 1e-9)
  }

  @Test func heldEdgeDragKeepsTheCentreAcross() {
    let start = CGRect(x: 300, y: 200, width: 200, height: 200)
    let dragged = CropGeometry.drag(.right, from: start, by: CGSize(width: 100, height: 0), ratio: 1, bounds: bounds, minimum: 16)
    #expect(near(dragged, CGRect(x: 300, y: 150, width: 300, height: 300)))
  }

  @Test func dragsKeepTheMinimumSize() {
    let start = CGRect(x: 100, y: 100, width: 400, height: 300)
    let squashed = CropGeometry.drag(.bottomRight, from: start, by: CGSize(width: -1000, height: -1000), ratio: nil, bounds: bounds, minimum: 16)
    #expect(squashed.width == 16 && squashed.height == 16 && squashed.minX == 100)
    let held = CropGeometry.drag(.topLeft, from: start, by: CGSize(width: 1000, height: 1000), ratio: 2, bounds: bounds, minimum: 16)
    #expect(held.height >= 16 - 1e-9 && held.width >= 32 - 1e-9 && abs(held.width / held.height - 2) < 1e-9)
  }

  @Test func movingStaysInside() {
    let start = CGRect(x: 100, y: 100, width: 400, height: 300)
    let moved = CropGeometry.drag(.inside, from: start, by: CGSize(width: 5000, height: -5000), ratio: nil, bounds: bounds, minimum: 16)
    #expect(near(moved, CGRect(x: 600, y: 0, width: 400, height: 300)))
  }

  @Test func drawingANewRectangle() {
    #expect(CropGeometry.drawn(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 15, y: 12), ratio: nil, bounds: bounds, minimum: 16) == nil)
    let free = CropGeometry.drawn(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 200, y: 100), ratio: nil, bounds: bounds, minimum: 16)
    #expect(free.map { near($0, CGRect(x: 200, y: 100, width: 300, height: 300)) } == true)
    let held = CropGeometry.drawn(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 200), ratio: 0.5, bounds: bounds, minimum: 16)
    #expect(held.map { $0.minX == 100 && $0.minY == 100 && abs($0.width / $0.height - 0.5) < 1e-9 } == true)
    // Out past the image, it stops at the edge.
    let past = CropGeometry.drawn(from: CGPoint(x: 900, y: 700), to: CGPoint(x: 5000, y: 5000), ratio: nil, bounds: bounds, minimum: 16)
    #expect(past.map { near($0, CGRect(x: 900, y: 700, width: 100, height: 100)) } == true)
  }

  @Test func handlesAreFoundCornersFirst() {
    let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
    #expect(CropGeometry.handle(at: CGPoint(x: 102, y: 98), rect: rect, reach: 8) == .topLeft)
    #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 203), rect: rect, reach: 8) == .bottom)
    #expect(CropGeometry.handle(at: CGPoint(x: 150, y: 101), rect: rect, reach: 8) == .top)
    #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 150), rect: rect, reach: 8) == .inside)
    #expect(CropGeometry.handle(at: CGPoint(x: 10, y: 10), rect: rect, reach: 8) == nil)
  }

  @Test func ratiosAndFitting() {
    let largest = CropGeometry.largest(ratio: 1, in: bounds)
    #expect(near(largest, CGRect(x: 100, y: 0, width: 800, height: 800)))
    let fitted = CropGeometry.fitting(CGRect(x: 100, y: 100, width: 400, height: 400), ratio: 4, in: bounds)
    // 800 × 200 about (300, 300) would start left of the image: moved in to its edge.
    #expect(abs(fitted.width / fitted.height - 4) < 1e-9 && fitted.minX == 0 && abs(fitted.midY - 300) < 1e-9)
    #expect(abs(fitted.width * fitted.height - 160_000) < 1e-6)
    // Too big to fit: made smaller, then moved inside.
    let shrunk = CropGeometry.fitting(CGRect(x: 0, y: 0, width: 1000, height: 800), ratio: 0.25, in: bounds)
    #expect(shrunk.height <= 800 + 1e-9 && shrunk.minY >= -1e-9 && abs(shrunk.width / shrunk.height - 0.25) < 1e-9)
  }

  @Test func presetsAndOrientation() {
    #expect(Edit.CropAspect.original.ratio(imageWidth: 1200, imageHeight: 900, swapped: false) == 1200.0 / 900)
    #expect(Edit.CropAspect.original.ratio(imageWidth: 1200, imageHeight: 900, swapped: true) == 900.0 / 1200)
    #expect(Edit.CropAspect.r4x5.ratio(imageWidth: 1, imageHeight: 1, swapped: true) == 1.25)
    #expect(Edit.CropAspect.r4x5.label(swapped: true) == "5:4")
    #expect(Edit.CropAspect.r4x5.swapping(false) == (.r4x5, true))
    // 9:16 turned is 16:9, the preset itself.
    #expect(Edit.CropAspect.r9x16.swapping(false) == (.r16x9, false))
    #expect(!Edit.CropAspect.square.canSwap && Edit.CropAspect.original.canSwap)
    #expect(Edit.CropAspect.allCases.map(\.title) == ["Original", "1:1", "4:5", "2:3", "3:4", "9:16", "16:9"])
  }

  /// Every preset, either way up, on images whose sides don't divide: whole pixels at the ratio
  /// exactly, inside the image, as large as fits when it's the largest asked for.
  @Test func heldRatiosAreExactOnOddSizes() {
    for (width, height) in [(1001, 1001), (999, 777), (1201, 901), (37, 1000), (4001, 3)] {
      for aspect in Edit.CropAspect.allCases {
        for swapped in [false, true] {
          let parts = aspect.wholeParts(imageWidth: width, imageHeight: height, swapped: swapped)
          let ratio = aspect.ratio(imageWidth: width, imageHeight: height, swapped: swapped)
          let bounds = CGSize(width: width, height: height)
          let crop = Edit.Crop(
            rect: CropGeometry.largest(ratio: ratio, in: bounds), imageWidth: width, imageHeight: height, aspect: aspect, swapped: swapped)
          let label = "\(aspect) \(swapped ? "swapped" : "") on \(width)×\(height)"
          guard height >= Edit.Crop.minimumSide else {
            #expect(crop == nil, "\(label)")
            continue
          }
          guard let crop else {
            // Only a ratio that can't be 16 a side here.
            #expect(Double(min(width, height)) < 16 * max(ratio, 1 / ratio), "\(label)")
            continue
          }
          #expect(crop.x >= 0 && crop.y >= 0 && crop.x + crop.width <= width && crop.y + crop.height <= height, "\(label)")
          #expect(crop.width >= 16 && crop.height >= 16, "\(label)")
          if max(parts.width, parts.height) <= 64 {
            #expect(crop.width * parts.height == crop.height * parts.width, "\(label): \(crop.width)×\(crop.height)")
            // The largest: one more step of the ratio wouldn't fit.
            #expect(crop.width + parts.width > width || crop.height + parts.height > height, "\(label)")
          } else {
            #expect(abs(Double(crop.width) / Double(crop.height) - ratio) < 2 / Double(crop.height), "\(label)")
          }
        }
      }
    }
    // The reviewer's cases: 4:5 and 1:1 on 1001×1001.
    let r45 = Edit.Crop(rect: CGRect(x: 0, y: 0, width: 800.8, height: 1001), imageWidth: 1001, imageHeight: 1001, aspect: .r4x5)
    #expect(r45?.width == 800 && r45?.height == 1000)
    let square = Edit.Crop(rect: CGRect(x: 0.4, y: 0.6, width: 999.6, height: 999.2), imageWidth: 1001, imageHeight: 1001, aspect: .square)
    #expect(square.map { $0.width == $0.height } == true)
    // Holding is idempotent: a held crop made whole again doesn't move.
    if let r45 { #expect(r45.clamped(imageWidth: 1001, imageHeight: 1001) == r45) }
  }

  /// The anchor keeps the corner opposite the one dragged.
  @Test func heldCropKeepsItsAnchor() {
    let rect = CGRect(x: 100.3, y: 50.2, width: 400.7, height: 500.1)
    let fromBottomRight = Edit.Crop(rect: rect, imageWidth: 2000, imageHeight: 2000, aspect: .r4x5, anchor: CGPoint(x: 0, y: 0))
    #expect(fromBottomRight?.x == 100 && fromBottomRight?.y == 50)
    let fromTopLeft = Edit.Crop(rect: rect, imageWidth: 2000, imageHeight: 2000, aspect: .r4x5, anchor: CGPoint(x: 1, y: 1))
    #expect(fromTopLeft.map { abs(Double($0.x + $0.width) - rect.maxX) <= 1 && abs(Double($0.y + $0.height) - rect.maxY) <= 1 } == true)
  }

  /// A pinch during a Crop drag (two fingers on iPad) never edits the crop: the drag is dropped,
  /// its later events pan, and letting go commits nothing, until both gestures have ended.
  @MainActor @Test func aPinchNeverEditsTheCrop() {
    let viewport = EditViewport(imageWidth: 1000, imageHeight: 800, viewSize: CGSize(width: 500, height: 400), displayScale: 1)
    let crop = Edit.Crop(x: 100, y: 100, width: 400, height: 300)
    let drag = CropDrag()
    let start = viewport.viewRect(crop.rect)
    let corner = CGPoint(x: start.maxX, y: start.maxY)
    #expect(drag.dragChanged(translation: CGSize(width: 10, height: 0)))
    drag.changed(from: corner, to: CGPoint(x: corner.x + 10, y: corner.y), crop: crop, image: (1000, 800), viewport: viewport)
    #expect(drag.draft != nil)
    drag.pinchChanged()
    #expect(drag.draft == nil && !drag.isDragging && drag.pinched)
    // The drag goes on, now a pan from where the pinch began.
    #expect(!drag.dragChanged(translation: CGSize(width: 30, height: 5)))
    #expect(drag.pinchPan == CGSize(width: 20, height: 5))
    drag.changed(from: corner, to: CGPoint(x: corner.x + 30, y: corner.y), crop: crop, image: (1000, 800), viewport: viewport)
    #expect(drag.draft == nil)
    // Letting go of either first commits nothing.
    #expect(drag.dragEnded(crop: crop, image: (1000, 800)) == nil)
    #expect(drag.pinched)
    drag.pinchEnded()
    #expect(!drag.pinched && drag.pinchPan == .zero)
    // The next touch crops again.
    #expect(drag.dragChanged(translation: CGSize(width: 10, height: 0)))
    drag.changed(from: corner, to: CGPoint(x: corner.x + 10, y: corner.y), crop: crop, image: (1000, 800), viewport: viewport)
    #expect(drag.dragEnded(crop: crop, image: (1000, 800)) != nil)
    // A pinch alone (the Mac's trackpad) leaves nothing behind.
    drag.pinchChanged()
    drag.pinchEnded()
    #expect(!drag.pinched && !drag.isDragging)
  }

  /// A touch cancelled with no `onEnded` (a system interruption) leaves nothing set: the pane's
  /// `moving` going back calls `reset`, and the next touch crops.
  @MainActor @Test func aCancelledGestureResets() {
    let viewport = EditViewport(imageWidth: 1000, imageHeight: 800, viewSize: CGSize(width: 500, height: 400), displayScale: 1)
    let crop = Edit.Crop(x: 100, y: 100, width: 400, height: 300)
    let drag = CropDrag()
    let corner = CGPoint(x: viewport.viewRect(crop.rect).maxX, y: viewport.viewRect(crop.rect).maxY)
    _ = drag.dragChanged(translation: CGSize(width: 10, height: 0))
    drag.changed(from: corner, to: CGPoint(x: corner.x + 10, y: corner.y), crop: crop, image: (1000, 800), viewport: viewport)
    drag.pinchChanged()
    _ = drag.dragChanged(translation: CGSize(width: 40, height: 0))
    // Cancelled: neither gesture's onEnded comes.
    drag.reset()
    #expect(!drag.dragActive && !drag.pinchActive && !drag.pinched && !drag.isDragging && drag.draft == nil && drag.pinchPan == .zero)
    #expect(drag.pinchZoom == nil)
    #expect(drag.dragChanged(translation: CGSize(width: 10, height: 0)))
    drag.changed(from: corner, to: CGPoint(x: corner.x + 10, y: corner.y), crop: crop, image: (1000, 800), viewport: viewport)
    #expect(drag.dragEnded(crop: crop, image: (1000, 800)) != nil)
  }

  /// Original of 4000×3072 (125:96, no whole multiple under 64) follows the width pixel by pixel,
  /// not in 125 px steps.
  @Test func originalOfALargeRatioTakesFineSteps() {
    let parts = Edit.CropAspect.original.wholeParts(imageWidth: 4000, imageHeight: 3072, swapped: false)
    #expect(parts == (125, 96))
    for width in [1000.0, 1001, 1050, 1099] {
      let crop = Edit.Crop(
        rect: CGRect(x: 0, y: 0, width: width, height: width * 3072 / 4000), imageWidth: 4000, imageHeight: 3072, aspect: .original)
      #expect(crop?.width == Int(width), "\(width)")
      #expect(crop.map { abs(Double($0.height) - width * 3072 / 4000) <= 0.5 } == true, "\(width)")
    }
  }

  @Test func heldCropOfTheWholeImageAndOfACrop() {
    let square = EditModel.held(nil, to: .square, swapped: false, width: 1200, height: 900)
    #expect(square == Edit.Crop(x: 150, y: 0, width: 900, height: 900, aspect: .square))
    let turned = EditModel.held(Edit.Crop(x: 100, y: 100, width: 400, height: 500), to: .r4x5, swapped: true, width: 1200, height: 900)
    #expect(turned.map { abs(Double($0.width) / Double($0.height) - 1.25) < 0.01 && $0.swapped } == true)
  }

  @Test func cropsAreWholePixelsInsideTheImage() {
    let crop = Edit.Crop(rect: CGRect(x: -10.4, y: 20.6, width: 300.2, height: 5000), imageWidth: 1000, imageHeight: 800)
    #expect(crop == Edit.Crop(x: 0, y: 21, width: 290, height: 779))
    #expect(Edit.Crop(rect: CGRect(x: 0, y: 0, width: 10, height: 500), imageWidth: 1000, imageHeight: 800) == nil)
    #expect(Edit.Crop(rect: CGRect(x: Double.nan, y: 0, width: 100, height: 100), imageWidth: 1000, imageHeight: 800) == nil)
    #expect(Edit.Crop(rect: CGRect(x: 0, y: 0, width: Double.infinity, height: 100), imageWidth: 1000, imageHeight: 800) == nil)
    // A huge value is clamped before it becomes an Int.
    #expect(Edit.Crop(rect: CGRect(x: 1e300, y: 0, width: 100, height: 100), imageWidth: 1000, imageHeight: 800) == nil)
    // A record's crop from a larger image, kept to this one.
    #expect(Edit.Crop(x: 900, y: 0, width: 400, height: 400).clamped(imageWidth: 1000, imageHeight: 800) == Edit.Crop(x: 900, y: 0, width: 100, height: 400))
    #expect(Edit.Crop(x: 0, y: 0, width: 1000, height: 800).isWhole(imageWidth: 1000, imageHeight: 800))
    #expect(EditRetouch.effectiveCrop(Edit.Crop(x: 0, y: 0, width: 1000, height: 800), imageWidth: 1000, imageHeight: 800) == nil)
  }

  @Test func applyingCrops() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let source = try #require(context.makeImage())
    #expect(EditRetouch.apply(.none, to: source) === source)
    #expect(EditRetouch.apply(Edit.Retouch(crop: Edit.Crop(x: 0, y: 0, width: 64, height: 48)), to: source) === source)
    let cropped = EditRetouch.apply(Edit.Retouch(crop: Edit.Crop(x: 8, y: 4, width: 32, height: 20)), to: source)
    #expect(cropped.width == 32 && cropped.height == 20)
  }

  @Test func viewportMapsBothWays() {
    let viewport = EditViewport(imageWidth: 2000, imageHeight: 1000, viewSize: CGSize(width: 500, height: 500), displayScale: 2)
    // Fitted: 2 screen pixels per point, 500 points wide for 2000 pixels: a quarter point per pixel.
    let rect = viewport.viewRect(CGRect(x: 0, y: 0, width: 2000, height: 1000))
    #expect(near(rect, viewport.imageFrame))
    let point = viewport.imagePoint(CGPoint(x: rect.midX, y: rect.midY))
    #expect(abs(point.x - 1000) < 1e-9 && abs(point.y - 500) < 1e-9)
    let back = viewport.viewRect(CGRect(x: 400, y: 200, width: 100, height: 100))
    let corner = viewport.imagePoint(CGPoint(x: back.minX, y: back.minY))
    #expect(abs(corner.x - 400) < 1e-9 && abs(corner.y - 200) < 1e-9)
  }

  @Test func decodingIsLenientAboutTheRatioOnly() throws {
    let decoder = JSONDecoder()
    let crop = try decoder.decode(Edit.Crop.self, from: Data(#"{"x":1,"y":2,"width":30,"height":40,"aspect":"r7x9","swapped":"yes"}"#.utf8))
    #expect(crop == Edit.Crop(x: 1, y: 2, width: 30, height: 40))
    let held = try decoder.decode(Edit.Crop.self, from: Data(#"{"x":1,"y":2,"width":30,"height":40,"aspect":"r4x5","swapped":true}"#.utf8))
    #expect(held.aspect == .r4x5 && held.swapped)
    #expect((try? decoder.decode(Edit.Crop.self, from: Data(#"{"x":1,"y":2,"width":30}"#.utf8))) == nil)
    let round = try decoder.decode(Edit.Crop.self, from: JSONEncoder().encode(held))
    #expect(round == held)
  }

  #if os(macOS)
  @Test func cropImageArguments() throws {
    #expect(try CropArguments.parse(["x": 1, "y": 2, "width": 30, "height": 40]) == .rect(CGRect(x: 1, y: 2, width: 30, height: 40)))
    #expect(try CropArguments.parse(["aspect": "5:4"]) == .aspect(.r4x5, swapped: true))
    #expect(try CropArguments.parse(["aspect": "16:9", "anchor": "center"]) == .aspect(.r16x9, swapped: false))
    #expect(try CropArguments.parse(["aspect": "Original"]) == .aspect(.original, swapped: false))
    #expect(try CropArguments.parse(["clear": true]) == .clear)
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.parse([:]) }
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.parse(["aspect": "7:3"]) }
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.parse(["aspect": "1:1", "x": 0]) }
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.parse(["x": 0, "y": 0, "width": 30]) }
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.parse(["x": true, "y": 0, "width": 30, "height": 30]) }
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.parse(["x": 0, "y": 0, "width": -30, "height": 30]) }
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.parse(["clear": 1]) }
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.parse(["aspect": "1:1", "anchor": "top"]) }

    let inside = try CropArguments.Change.rect(CGRect(x: 10, y: 10, width: 100, height: 50)).crop(over: nil, width: 200, height: 100)
    #expect(inside == Edit.Crop(x: 10, y: 10, width: 100, height: 50))
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.Change.rect(CGRect(x: 150, y: 0, width: 100, height: 50)).crop(over: nil, width: 200, height: 100) }
    #expect(throws: AgentTools.ToolError.self) { try CropArguments.Change.rect(CGRect(x: 0, y: 0, width: 8, height: 50)).crop(over: nil, width: 200, height: 100) }
    let square = try CropArguments.Change.aspect(.square, swapped: false).crop(over: nil, width: 200, height: 100)
    #expect(square == Edit.Crop(x: 50, y: 0, width: 100, height: 100, aspect: .square))
    #expect(try CropArguments.Change.clear.crop(over: inside, width: 200, height: 100) == nil)
  }
  #endif
}
