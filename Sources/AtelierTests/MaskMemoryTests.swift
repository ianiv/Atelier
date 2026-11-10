@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// Masks kept per image: stretching one onto an image of another size, the per-image key in the
/// project file (through forks and deletes), the fallbacks for older projects, and Draw Things'
/// layer masks read as a mask.
struct MaskMemoryTests {
  private static func coverage(_ mask: CanvasMask, _ width: Int, _ height: Int) -> [UInt8] {
    mask.coverage(width: width, height: height)
  }

  private static func count(_ bytes: [UInt8]) -> Int {
    bytes.count(where: { $0 != 0 })
  }

  private static func project() throws -> (Project, URL) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "MaskMemoryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (Project(url: folder.appending(path: "Masks.sqlite3")), folder)
  }

  private static func append(
    _ project: Project, after parent: Int64? = nil, input: Int64? = nil, refined: RefinedStep? = nil, generated: Bool = true
  ) async throws -> HistoryItem {
    let image = try CanvasRefineTests.pattern(width: 64, height: 64)
    return try await project.append(
      tensor: try #require(ImageTensor.tensor(from: image)), model: "m", prompt: "", negativePrompt: "", seed: 1,
      settings: [:], createdAt: Date(), duration: 0, reason: generated ? .generate : .imported, generated: generated,
      inputTensorId: input, after: parent, refined: refined)
  }

  @Test func theSameSizeLeavesAMaskAsItIs() {
    let mask = CanvasMask(strokes: [.rect(CGRect(x: 1, y: 2, width: 3, height: 4)), .invert])
    #expect(mask.scaled(sx: 1, sy: 1) == mask)
    #expect(mask.scaled(from: CGSize(width: 10, height: 20), to: CGSize(width: 10, height: 20)) == mask)
  }

  @Test func vectorStrokesStretch() {
    let mask = CanvasMask(strokes: [
      .rect(CGRect(x: 10, y: 10, width: 20, height: 10)),
      CanvasMask.Stroke(kind: .brush, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5)], radius: 3),
    ])
    let scaled = mask.scaled(sx: 2, sy: 8)
    #expect(scaled.strokes[0].points == [CGPoint(x: 20, y: 80), CGPoint(x: 60, y: 160)])
    #expect(scaled.strokes[1].points == [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 40)])
    // Round brushes stay round: the radius grows by the geometric mean.
    #expect(scaled.strokes[1].radius == 12)
    // A rectangle covering a quarter of a 40×40 image covers a quarter of it at 80×20.
    let quarter = CanvasMask(rects: [CGRect(x: 0, y: 0, width: 20, height: 20)])
    let stretched = quarter.scaled(from: CGSize(width: 40, height: 40), to: CGSize(width: 80, height: 20))
    #expect(Self.count(Self.coverage(stretched, 80, 20)) == 40 * 10)
  }

  @Test func bitmapStrokesStretchIntoTheirRect() throws {
    // A 20×20 bitmap painted on its left half, placed at 10, 10.
    var bytes = [UInt8](repeating: 0, count: 20 * 20)
    for y in 0..<20 { for x in 0..<10 { bytes[y * 20 + x] = 255 } }
    let png = try #require(CanvasMask.grayPNG(bytes, width: 20, height: 20))
    let mask = CanvasMask(strokes: [CanvasMask.Stroke(kind: .bitmap, points: [CGPoint(x: 10, y: 10)], bitmap: png)])
    #expect(mask.strokes[0].bitmapSize == CGSize(width: 20, height: 20))
    let scaled = mask.scaled(sx: 2, sy: 0.5)
    #expect(scaled.strokes[0].points == [CGPoint(x: 20, y: 5)])
    #expect(scaled.strokes[0].size == CGSize(width: 40, height: 10))
    let painted = Self.coverage(scaled, 80, 20)
    // The painted half lands at x 20..<40, y 5..<15.
    #expect(Self.count(painted) == 20 * 10)
    #expect(painted[10 * 80 + 25] == 255 && painted[10 * 80 + 45] == 0 && painted[2 * 80 + 25] == 0)
  }

  @Test func invertStretchesWithTheRest() {
    let mask = CanvasMask(strokes: [.rect(CGRect(x: 0, y: 0, width: 10, height: 10)), .invert])
    let scaled = mask.scaled(sx: 2, sy: 2)
    #expect(scaled.strokes[1].kind == .invert && scaled.strokes[1].points.isEmpty)
    #expect(Self.count(Self.coverage(scaled, 40, 40)) == 40 * 40 - 20 * 20)
  }

  @Test func masksSavedBeforeBitmapSizesStillDecode() throws {
    let json = #"{"strokes":[{"kind":"rect","points":[[1,2],[3,4]],"radius":0,"erases":false}]}"#
    let mask = try JSONDecoder().decode(CanvasMask.self, from: Data(json.utf8))
    #expect(mask.strokes.count == 1 && mask.strokes[0].size == nil)
    #expect(mask.strokes[0].points == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])
    // And a sized one round-trips.
    var sized = mask
    sized.strokes[0].size = CGSize(width: 5, height: 6)
    #expect(try JSONDecoder().decode(CanvasMask.self, from: JSONEncoder().encode(sized)) == sized)
  }

  @Test @MainActor func severalBitmapsAreCompactedIntoOne() throws {
    let image = try #require(CanvasMask(rects: [CGRect(x: 0, y: 0, width: 8, height: 8)]).image(sourceSize: CGSize(width: 32, height: 32)))
    let other = try #require(CanvasMask(rects: [CGRect(x: 16, y: 16, width: 8, height: 8)]).image(sourceSize: CGSize(width: 32, height: 32)))
    let mask = CanvasMask(strokes: [try #require(CanvasMask.Stroke.bitmap(image)), try #require(CanvasMask.Stroke.bitmap(other)), .rect(CGRect(x: 0, y: 0, width: 4, height: 4), erases: true)])
    let compacted = mask.compacted(for: CGSize(width: 32, height: 32))
    #expect(compacted.strokes.count == 1)
    #expect(Self.coverage(compacted, 32, 32) == Self.coverage(mask, 32, 32))
    // One bitmap is kept as it is.
    let single = CanvasMask(strokes: [try #require(CanvasMask.Stroke.bitmap(image))])
    #expect(single.compacted(for: CGSize(width: 32, height: 32)) == single)
  }

  @Test func aMaskKeyRoundTripsAndSurvivesAFork() async throws {
    let (project, folder) = try Self.project()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try await Self.append(project)
    let second = try await Self.append(project, after: first.tensorId)
    let mask = CanvasMask(strokes: [.ellipse(in: CGRect(x: 4, y: 4, width: 20, height: 10))])
    project.setStoredMask(mask, forImage: second.tensorId)
    project.setStoredMask(CanvasMask(), forImage: first.tensorId)
    #expect(project.storedMask(forImage: second.tensorId) == mask)
    #expect(project.storedMaskImages() == [second.tensorId: true, first.tensorId: false])
    // A fork after the first step, then one after the second (no longer on the greatest lineage
    // at its step) renumbers the second; its image's mask stays.
    _ = try await Self.append(project, after: first.tensorId)
    let fork = try await Self.append(project, after: second.tensorId)
    let tree = await project.read { $0.tree() }
    #expect(tree.step(tensorId: fork.tensorId) != nil && tree.step(tensorId: second.tensorId) != second.id)
    #expect(project.storedMask(forImage: second.tensorId) == mask)
    // Read fresh from the file.
    await project.close()
    let reopened = Project(url: project.url)
    #expect(await reopened.read { $0.storedMask(forImage: second.tensorId) } == mask)
    reopened.setStoredMask(nil, forImage: second.tensorId)
    #expect(reopened.storedMask(forImage: second.tensorId) == nil)
    await reopened.close()
  }

  @Test func deletingAStepRemovesItsMask() async throws {
    let (project, folder) = try Self.project()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try await Self.append(project)
    let second = try await Self.append(project, after: first.tensorId)
    let mask = CanvasMask(rects: [CGRect(x: 0, y: 0, width: 8, height: 8)])
    project.setStoredMask(mask, forImage: first.tensorId)
    project.setStoredMask(mask, forImage: second.tensorId)
    _ = try await project.delete(tensorId: second.tensorId)
    let gone = await project.read { $0.pruneStoredMasks(keeping: $0.tree(items: false)) }
    #expect(gone == [second.tensorId])
    #expect(project.storedMask(forImage: second.tensorId) == nil && project.storedMask(forImage: first.tensorId) == mask)
    await project.close()
  }

  @Test func olderProjectsFallBackToTheNewestChildsMask() async throws {
    let (project, folder) = try Self.project()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try await Self.append(project)
    let composite = try CanvasRefineTests.pattern(width: 64, height: 64)
    func refined(_ mask: CanvasMask?) -> RefinedStep {
      RefinedStep(record: RefineRecord(rect: [0, 0, 64, 64], scale: nil, offset: [0, 0], mask: mask), composite: composite)
    }
    let older = CanvasMask(rects: [CGRect(x: 0, y: 0, width: 10, height: 10)])
    let newer = CanvasMask(rects: [CGRect(x: 20, y: 20, width: 10, height: 10)])
    _ = try await Self.append(project, after: source.tensorId, input: source.tensorId, refined: refined(older))
    _ = try await Self.append(project, after: source.tensorId, input: source.tensorId, refined: refined(newer))
    // A newer child without a mask doesn't hide the one before it.
    _ = try await Self.append(project, after: source.tensorId, input: source.tensorId, refined: refined(nil))
    let items = await project.read { $0.tree().itemsNewestFirst }
    #expect(HistoryStore.childMasks(items)[source.tensorId] == newer)
    await project.close()
  }

  @Test func aMergedResultsRecordMovesWithTheGrownImage() {
    // The frame reached 32 past the left and 10.5 above the top: the source moved right and down.
    let record = RefineRecord(rect: [-32, -10.5, 128, 128], scale: 1, offset: [0, 0], mask: nil)
    let mask = CanvasMask(rects: [CGRect(x: 0, y: 0, width: 4, height: 4)])
    #expect(HistoryStore.resultMask(of: record, mask: mask).strokes[0].points.first == CGPoint(x: 32, y: 11))
    let inside = RefineRecord(rect: [8, 8, 32, 32], scale: 2, offset: [0, 0], mask: nil)
    #expect(HistoryStore.resultMask(of: inside, mask: mask) == mask)
  }

  /// A Draw Things canvas: a layer's mask codes other than 0 and 3 are painted (the brush's 0xF9).
  @Test func aDrawThingsLayerMaskReadsAsTheStepsMask() async throws {
    let source = try CanvasRefineTests.pattern(width: 16, height: 8)
    var codes = [UInt8](repeating: CanvasMask.Stored.opaque, count: 16 * 8)
    for y in 2..<4 { for x in 4..<8 { codes[y * 16 + x] = CanvasMask.Stored.painted } }
    codes[0] = 0
    let layer = Project.CompositeLayer(image: source, mask: codes, maskWidth: 16, maskHeight: 8, x: 0, y: 0, scaleFactorBy120: 120)
    let mask = try #require(Project.paintedMask([layer]))
    let painted = Self.coverage(mask, 16, 8)
    #expect(Self.count(painted) == 8 && painted[2 * 16 + 4] == 255 && painted[0] == 0)
    // A layer without a mask over it leaves the paint, and one past the right edge grows the
    // canvas the mask is laid out on.
    let over = Project.CompositeLayer(image: try CanvasRefineTests.pattern(width: 8, height: 8), mask: nil, maskWidth: 0, maskHeight: 0, x: 12, y: 0, scaleFactorBy120: 120)
    let grown = try #require(Project.paintedMask([layer, over]))
    #expect(grown.strokes.first?.bitmapSize == CGSize(width: 20, height: 8))
    #expect(Self.count(Self.coverage(grown, 20, 8)) == 8)
    #expect(Project.paintedMask([Project.CompositeLayer(image: source, mask: [UInt8](repeating: 3, count: 128), maskWidth: 16, maskHeight: 8, x: 0, y: 0, scaleFactorBy120: 120)]) == nil)

    // Stored in a project: the merged refine's source layer carries its paint as Draw Things does.
    let (project, folder) = try Self.project()
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = try CanvasRefineTests.pattern(width: 64, height: 64)
    let first = try await project.append(
      tensor: try #require(ImageTensor.tensor(from: image)), model: "m", prompt: "", negativePrompt: "", seed: 1, settings: [:],
      createdAt: Date(), duration: 0, reason: .imported, generated: false)
    let paint = CanvasMask(rects: [CGRect(x: 8, y: 8, width: 16, height: 16)])
    let merge = RefineMerge(
      source: image, sourceTensorId: first.tensorId, scale: nil, offset: .zero, frameSize: CGSize(width: 64, height: 64), mask: paint)
    let merged = try #require(CanvasMerge.merge(
      try CanvasRefineTests.solid(width: 64, height: 64, red: 0, green: 255, blue: 0), into: merge, maskBlur: 0, maskBlurOutset: 0))
    let layers = try #require(merged.step.layers)
    let item = try await project.append(
      tensor: try #require(ImageTensor.tensor(from: layers.frame)), model: "m", prompt: "", negativePrompt: "", seed: 1,
      settings: [:], createdAt: Date(), duration: 0, inputTensorId: first.tensorId, after: first.tensorId, refined: merged.step)
    let read = try #require(await project.read { $0.layerMask(tensorId: item.tensorId) })
    #expect(Self.coverage(read, 64, 64) == Self.coverage(paint, 64, 64))
    #expect(await project.read { $0.tree().layerMaskedImages.contains(item.tensorId) })
    await project.close()
  }
}
