@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// A `CanvasEdit` makes the same run inputs as the same values given straight to
/// `RefineInputs.make` (what `setRefineInputs` sets on a request): the Create screen's request is
/// built from one, so every field has to arrive where it did before. MGK's `Configuration` has no
/// public initializer, so the request itself isn't made here; `--refine-check` and `--paint-check`
/// cover it with a real model.
@Suite(.tags(.smoke))
struct CanvasEditTests {
  private static let frame = CGSize(width: 64, height: 64)

  /// Every field of the inputs that a request takes, comparable.
  private struct Fields: Equatable {
    var canvas: [UInt8]
    var mask: Data?
    var sourceMask: CanvasSourceMask?
    var merge: RefineMerge.Record?
    var mergesIntoSource: Bool
    var unpainted: [UInt8]?
    var canvasKey: String
    var canvasTensorId: Int64?

    init(_ inputs: RefineInputs, source: CGImage) {
      canvas = CanvasRefineTests.rgba(inputs.canvas)
      mask = inputs.mask
      sourceMask = inputs.sourceMask
      merge = inputs.merge?.record
      mergesIntoSource = inputs.merge.map { $0.source === source } ?? true
      unpainted = inputs.merge?.unpaintedInput.map(CanvasRefineTests.rgba)
      canvasKey = inputs.canvasKey
      canvasTensorId = inputs.canvasTensorId
    }
  }

  /// The inputs from `edit`, and from its values passed one by one.
  private static func both(_ edit: CanvasEdit, maskBlur: Double = 0, maskBlurOutset: Int = 0) throws -> (edit: Fields, direct: Fields) {
    let fromEdit = try #require(edit.refineInputs(frame: frame, maskBlur: maskBlur, maskBlurOutset: maskBlurOutset))
    let direct = try #require(
      RefineInputs.make(
        source: edit.source, sourceTensorId: edit.sourceTensorId, isImported: edit.isImported, scale: edit.scale,
        offset: edit.offset, frame: frame, mask: edit.mask, merge: edit.merge, detail: edit.detail, paint: edit.paint,
        maskBlur: maskBlur, maskBlurOutset: maskBlurOutset))
    return (Fields(fromEdit, source: edit.source), Fields(direct, source: edit.source))
  }

  @Test func aFittedImageIsItsStep() throws {
    let image = try CanvasRefineTests.pattern(width: 64, height: 64)
    let inputs = try Self.both(CanvasEdit(source: image, sourceTensorId: 42))
    #expect(inputs.edit == inputs.direct)
    // The frame is the step's image as it is: nothing to merge, the step reused.
    #expect(inputs.edit.canvasTensorId == 42 && inputs.edit.merge == nil && inputs.edit.mask == nil)
    #expect(inputs.edit.canvas == CanvasRefineTests.rgba(image))
    // From outside the project there's no step to reuse.
    let imported = try Self.both(CanvasEdit(source: image, sourceTensorId: 42, isImported: true))
    #expect(imported.edit == imported.direct && imported.edit.canvasTensorId == nil)
  }

  @Test func aZoomedMaskedMergeKeepsItsPlaceAndMask() throws {
    let image = try CanvasRefineTests.pattern(width: 128, height: 96)
    let mask = CanvasMask(rects: [CGRect(x: 40, y: 30, width: 20, height: 16)])
    let edit = CanvasEdit(
      source: image, sourceTensorId: 7, scale: 2, offset: CGSize(width: 24, height: -8), mask: mask, merge: true)
    let inputs = try Self.both(edit)
    #expect(inputs.edit == inputs.direct)
    let merge = try #require(inputs.edit.merge)
    #expect(merge.scale == 2 && merge.offsetX == 24 && merge.offsetY == -8 && merge.mask == mask && merge.sourceTensorId == 7)
    #expect(merge.frameWidth == 64 && merge.frameHeight == 64 && inputs.edit.mergesIntoSource)
    #expect(inputs.edit.mask != nil && inputs.edit.canvasTensorId == 7)
    #expect(inputs.edit.sourceMask == CanvasSourceMask(tensorId: 7, width: 128, height: 96, mask: mask))
    // Zoom and offset aren't swapped or dropped: another placement is another frame.
    var moved = edit
    moved.offset = CGSize(width: -8, height: 24)
    #expect(try Self.both(moved).edit.canvas != inputs.edit.canvas)
    // Without merge the frame alone is the input, saved as its own step.
    var unmerged = edit
    unmerged.merge = false
    let plain = try Self.both(unmerged)
    #expect(plain.edit == plain.direct && plain.edit.merge == nil && plain.edit.canvasTensorId == nil)
    #expect(plain.edit.canvasKey != inputs.edit.canvasKey)
  }

  @Test func paintAndMaskBlurGoIn() throws {
    let image = try CanvasRefineTests.solid(width: 64, height: 64, red: 255, green: 255, blue: 255)
    let mask = CanvasMask(rects: [CGRect(x: 16, y: 16, width: 32, height: 32)])
    let flat = try #require(mask.flattenedStroke(width: 64, height: 64))
    let green = CanvasPaint.Color(red: 0, green: 1, blue: 0)
    let paint = CanvasPaint(strokes: [try #require(CanvasPaint.Stroke.fill(flat, color: green))])
    let edit = CanvasEdit(source: image, sourceTensorId: 3, mask: mask, paint: paint, merge: true)
    let blurred = try Self.both(edit, maskBlur: 1.5, maskBlurOutset: 0)
    #expect(blurred.edit == blurred.direct)
    #expect(blurred.edit.merge?.painted == true && blurred.edit.unpainted == CanvasRefineTests.rgba(image))
    // The painted frame is a new input; the merge still goes back into the step.
    #expect(blurred.edit.canvasTensorId == nil && blurred.edit.merge?.sourceTensorId == 3)
    // Mask Blur reaches the paint's fade: a hard mask takes the paint up to its edge.
    let hard = try Self.both(edit)
    #expect(hard.edit == hard.direct && hard.edit.canvas != blurred.edit.canvas && hard.edit.canvasKey != blurred.edit.canvasKey)
    // No paint, the same mask: the unpainted frame.
    var unpainted = edit
    unpainted.paint = nil
    let bare = try Self.both(unpainted, maskBlur: 1.5)
    #expect(bare.edit == bare.direct && bare.edit.canvas == CanvasRefineTests.rgba(image) && bare.edit.merge?.painted == nil)
  }

  @Test func detailLayersAreDrawnIn() throws {
    let image = try CanvasRefineTests.solid(width: 32, height: 32, red: 0, green: 0, blue: 0)
    let fine = try CanvasRefineTests.solid(width: 32, height: 32, red: 255, green: 0, blue: 0)
    let layer = Project.DetailLayer(image: fine, rect: CGRect(x: 8, y: 8, width: 16, height: 16))
    let edit = CanvasEdit(source: image, sourceTensorId: 5, scale: 2, detail: [layer], merge: true)
    let inputs = try Self.both(edit)
    #expect(inputs.edit == inputs.direct)
    var without = edit
    without.detail = []
    #expect(try Self.both(without).edit.canvas != inputs.edit.canvas)
  }
}
