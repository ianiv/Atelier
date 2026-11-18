@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// `edit_image`'s arguments, read with no image or model to hand (`CanvasEditArguments.parse`):
/// what's taken by default, the forms a reference image comes in, each message an agent gets for
/// arguments that don't go together, and the order the mask is built in (`AgentTools.prepared`).
@Suite(.tags(.smoke))
struct CanvasEditArgumentsTests {
  private static var base: [String: Any] { ["image": "/tmp/in.png", "prompt": "a face"] }

  /// What parsing `base` with `more` fails with; empty when it parses.
  private static func message(_ more: [String: Any], without removed: [String] = []) -> String {
    var arguments = base.merging(more) { _, new in new }
    for key in removed { arguments[key] = nil }
    do {
      _ = try CanvasEditArguments.parse(arguments)
      return ""
    } catch {
      return error.localizedDescription
    }
  }

  @Test func defaults() throws {
    let parsed = try CanvasEditArguments.parse(Self.base)
    #expect(parsed.source == .image("/tmp/in.png"))
    #expect(parsed.prompt == "a face")
    #expect(parsed.region == nil && parsed.width == nil && parsed.height == nil && parsed.scale == nil)
    #expect(parsed.mask == nil && parsed.paint == nil && parsed.references.isEmpty)
    #expect(parsed.merge)
    let step = try CanvasEditArguments.parse(["history_step": 12, "prompt": "", "merge_into_image": false, "scale": 4])
    #expect(step.source == .historyStep(12) && step.prompt.isEmpty && !step.merge && step.scale == 4)
  }

  @Test func regionAndSize() throws {
    let parsed = try CanvasEditArguments.parse(
      Self.base.merging(["region": ["x": 10, "y": 20, "width": 912, "height": 1152], "width": 3648, "height": 4608]) { _, new in new })
    #expect(parsed.region == CGRect(x: 10, y: 20, width: 912, height: 1152))
    #expect(parsed.width == 3648 && parsed.height == 4608)
    #expect(Self.message(["width": 512, "height": 512, "scale": 2]).contains("or `scale`, not both"))
    #expect(Self.message(["width": 512]).contains("`width` and `height` together"))
    #expect(Self.message(["scale": 64]).contains("0.05–32"))
    #expect(Self.message(["region": ["x": 0, "y": 0, "width": 0, "height": 10]]).contains("no size"))
    #expect(Self.message(["region": [0, 0, 10, 10]]).contains("`region` is"))
  }

  @Test func sourceAndPromptErrors() {
    #expect(Self.message(["history_step": 3]) == "Pass `image` or `history_step`, only one.")
    #expect(Self.message([:], without: ["image"]) == "Pass `image` or `history_step`, only one.")
    #expect(Self.message(["image": 7]) == "Pass `image` or `history_step`, only one.")
    #expect(Self.message([:], without: ["prompt"]).contains("`prompt` is required"))
    #expect(Self.message(["input_image": "/tmp/in.png"]).contains("not input_image"))
    #expect(Self.message(["use_canvas": true]).contains("generate with use_canvas"))
    #expect(Self.message(["merge_into_image": "yes"]).contains("true or false"))
  }

  @Test func referenceForms() throws {
    let parsed = try CanvasEditArguments.parse(
      Self.base.merging([
        "reference_images": [
          "/tmp/a.png", ["image": "/tmp/b.png", "weight": 0.5], ["history_step": 9], ["image": "/tmp/off.png", "weight": 0],
          ["history_step": 4, "weight": 3],
        ],
      ]) { _, new in new })
    // A weight of 0 leaves the image out, as generate does; above 1 is 1.
    #expect(
      parsed.references == [
        .init(source: .image("/tmp/a.png"), weight: 1), .init(source: .image("/tmp/b.png"), weight: 0.5),
        .init(source: .historyStep(9), weight: 1), .init(source: .historyStep(4), weight: 1),
      ])
    #expect(Self.message(["reference_images": [["weight": 1]]]).contains("Each reference image"))
    #expect(Self.message(["reference_images": [["image": "/a.png", "history_step": 2]]]).contains("Each reference image"))
    #expect(Self.message(["reference_images": "/a.png"]).contains("Each reference image"))
  }

  @Test func maskFields() throws {
    let mask: [String: Any] = [
      "shapes": [["shape": "ellipse", "x": 8, "y": 8, "width": 16, "height": 16], ["shape": "polygon", "points": [[0, 0], [8, 0], [0, 8]]]],
      "image": "/tmp/mask.png",
      "select": ["points": [["x": 5, "y": 6], ["x": 7, "y": 8, "positive": false]], "box": ["x": 1, "y": 2, "width": 30, "height": 40], "size": "large"],
      "grow": 24, "invert": true,
    ]
    let parsed = try #require(try CanvasEditArguments.parse(Self.base.merging(["mask": mask]) { _, new in new }).mask)
    #expect(parsed.shapes.map(\.kind) == [.ellipse, .polygon])
    #expect(parsed.shapes.allSatisfy { !$0.erases })
    #expect(parsed.image == "/tmp/mask.png")
    #expect(parsed.select?.points == [.init(location: CGPoint(x: 5, y: 6), positive: true), .init(location: CGPoint(x: 7, y: 8), positive: false)])
    #expect(parsed.select?.box == CGRect(x: 1, y: 2, width: 30, height: 40))
    #expect(parsed.select?.size == .large && parsed.select?.subject == false)
    #expect(parsed.grow == 24 && parsed.invert)
    let subject = try #require(try CanvasEditArguments.parse(Self.base.merging(["mask": ["select": ["subject": true]]]) { _, new in new }).mask)
    #expect(subject.select?.subject == true && subject.select?.points.isEmpty == true && subject.grow == 0 && !subject.invert)
  }

  @Test func maskErrors() {
    #expect(Self.message(["mask": true]).contains("`mask` is an object"))
    #expect(Self.message(["mask": ["invert": true]]).contains("`mask` needs `shapes`, an `image` or a `select`"))
    #expect(Self.message(["mask": ["shapes": [["shape": "rect", "x": 0, "y": 0, "width": 4, "height": 4]], "grow": 600]]).contains("-512 to 512"))
    #expect(Self.message(["mask": ["shapes": [["shape": "star"]]]]).contains("Shape 1's `shape`"))
    #expect(Self.message(["mask": ["shapes": [["shape": "polygon", "points": [[0, 0], [1, 1]]]]]]).contains("at least 3"))
    #expect(Self.message(["mask": ["select": [:] as [String: Any]]]).contains("needs `points`, a `box`, or `subject: true`"))
    #expect(Self.message(["mask": ["select": ["subject": true, "box": ["x": 0, "y": 0, "width": 4, "height": 4]]]]).contains("no box"))
    #expect(Self.message(["mask": ["select": ["text": "the face"]]]).contains("text prompt"))
    #expect(Self.message(["mask": ["select": ["points": [["x": 1, "y": 1]], "size": "huge"]]]).contains("`size` is"))
    let many = (0..<13).map { ["x": $0, "y": 1] }
    #expect(Self.message(["mask": ["select": ["points": many, "box": ["x": 0, "y": 0, "width": 4, "height": 4]]]]).contains("at most 12 points with a box"))
  }

  @Test func paint() throws {
    let rect: [String: Any] = ["shape": "rect", "x": 0, "y": 0, "width": 4, "height": 4]
    let masked: [String: Any] = ["mask": ["shapes": [rect]]]
    let filled = try #require(
      try CanvasEditArguments.parse(Self.base.merging(masked) { _, new in new }.merging(["paint": ["fill_mask": true, "color": "#00FF00"]]) { _, new in new }).paint)
    #expect(filled.fillMask && filled.shapes.isEmpty)
    #expect(filled.color == CanvasPaint.Color(red: 0, green: 1, blue: 0))
    // A shape's own color wins over the default; an erasing one needs none.
    let shapes = try #require(
      try CanvasEditArguments.parse(
        Self.base.merging([
          "paint": ["color": "#0000FF", "shapes": [rect, rect.merging(["color": "#FF0000"]) { _, new in new }, rect.merging(["erase": true]) { _, new in new }]],
        ]) { _, new in new }
      ).paint)
    #expect(shapes.shapes.map(\.kind) == [.rect, .rect, .erase])
    #expect(shapes.shapes[0].color == CanvasPaint.Color(red: 0, green: 0, blue: 1) && shapes.shapes[1].color == CanvasPaint.Color(red: 1, green: 0, blue: 0))
    #expect(Self.message(["paint": ["fill_mask": true, "color": "#00FF00"]]) == "`paint.fill_mask` needs a `mask`.")
    #expect(Self.message(masked.merging(["paint": ["fill_mask": true]]) { _, new in new }).contains("needs `paint.color`"))
    #expect(Self.message(["paint": ["color": "#00FF00"]]).contains("`paint` needs `shapes` or `fill_mask`"))
    #expect(Self.message(["paint": ["shapes": [rect]]]).contains("Shape 1 has no `color`"))
    #expect(Self.message(["paint": ["color": "green", "shapes": [rect]]]).contains("#RRGGBB"))
    #expect(Self.message(["paint": "green"]).contains("`paint` is an object"))
  }

  /// The mask is built in the order the tool gives: the shapes, then grown, then inverted, so
  /// growing moves the shape's edge and not the inverted mask's; the fill is what that leaves.
  @Test func maskIsGrownThenInverted() async throws {
    let source = try CanvasRefineTests.pattern(width: 64, height: 64)
    let frame = CGSize(width: 64, height: 64)
    let placement = CanvasPlacement(sourceSize: frame, frameSize: frame, scale: nil, offset: .zero)
    let square = CanvasMask.Stroke.rect(CGRect(x: 16, y: 16, width: 32, height: 32))
    let edit = CanvasEdit(source: source, sourceTensorId: 7, merge: true)
    let grownSquare = MaskMorphology.grown(CanvasMask(strokes: [square]).coverage(width: 64, height: 64), width: 64, height: 64, by: 4)
      .reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
    #expect(grownSquare > 32 * 32 && grownSquare < 40 * 40)

    let plain = await AgentTools.prepared(
      edit, strokes: [square], grow: 0, invert: false, paint: nil, placement: placement, maskBlur: 0, maskBlurOutset: 0)
    #expect(plain.mask?.painted == 32 * 32)
    #expect(plain.mask?.bounds == CGRect(x: 16, y: 16, width: 32, height: 32))
    #expect(plain.mask?.inRegion == 0.25)
    #expect(!plain.hasPaint && plain.inputs?.merge?.painted == false && plain.inputs?.mask != nil)

    let both = await AgentTools.prepared(
      edit, strokes: [square], grow: 4, invert: true,
      paint: .init(fillMask: true, color: CanvasPaint.Color(red: 0, green: 1, blue: 0)), placement: placement, maskBlur: 0, maskBlurOutset: 0)
    #expect(both.mask?.painted == 64 * 64 - grownSquare)
    #expect(both.hasPaint && both.inputs?.merge?.painted == true)
    // The fill is the mask's: green outside the grown square, the picture inside it.
    let input = CanvasRefineTests.rgba(try #require(both.inputs?.canvas))
    let original = CanvasRefineTests.rgba(source)
    #expect(Array(input[0..<3]) == [0, 255, 0])
    let center = (32 * 64 + 32) * 4
    #expect(Array(input[center..<center + 3]) == Array(original[center..<center + 3]))

    // A mask wholly outside what the frame shows gives no inputs: there's nothing to regenerate.
    let corner = CanvasPlacement(sourceSize: frame, frameSize: CGSize(width: 64, height: 64), showing: CGRect(x: 0, y: 0, width: 8, height: 8))
    let outside = await AgentTools.prepared(
      edit, strokes: [square], grow: 0, invert: false, paint: nil, placement: corner, maskBlur: 0, maskBlurOutset: 0)
    #expect(outside.mask?.painted == 32 * 32 && outside.mask?.inRegion == 0 && outside.inputs == nil)
  }
}
