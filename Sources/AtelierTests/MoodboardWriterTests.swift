@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// The moodboard's files, written off the main actor (`MoodboardWriter`): in order, the index
/// naming only images on disk, an image already written kept rather than written again, and the
/// images the board let go removed.
struct MoodboardWriterTests {
  private struct Entry: Decodable {
    var id: UUID
    var weight: Float
  }

  private static func index(in folder: URL) throws -> [Entry] {
    try JSONDecoder().decode([Entry].self, from: Data(contentsOf: folder.appending(path: "index.json")))
  }

  private static func pngs(in folder: URL) -> Set<UUID> {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return Set(files.filter { $0.pathExtension == "png" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
  }

  @Test func writesInOrderAndKeepsTheIndexConsistent() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "MoodboardWriterTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = MoodboardWriter(folder: folder)
    let a = MoodboardItem(image: try CanvasRefineTests.pattern(width: 64, height: 64), weight: 1)
    let b = MoodboardItem(image: try CanvasRefineTests.pattern(width: 48, height: 48), weight: 0)
    let c = MoodboardItem(image: try CanvasRefineTests.pattern(width: 32, height: 32), weight: 0.5)

    writer.save([a])
    #expect(writer.flush(timeout: 10))
    #expect(try Self.index(in: folder).map(\.id) == [a.id])
    #expect(Self.pngs(in: folder) == [a.id])

    // A burst of saves: the last one is what's on disk, whatever order they ran in.
    var b2 = b
    for weight in stride(from: Float(0), through: 1, by: 0.1) {
      b2.weight = weight
      writer.save([a, b2])
    }
    writer.save([b2, c])
    #expect(writer.flush(timeout: 10))
    let index = try Self.index(in: folder)
    #expect(index.map(\.id) == [b.id, c.id] && index.map(\.weight) == [b2.weight, 0.5])
    #expect(Self.pngs(in: folder) == [b.id, c.id], "the image the board let go is removed")

    // An image already on disk isn't written again.
    writer.save([b2, c, a])
    #expect(writer.flush(timeout: 10))
    writer.save([b2, c])
    writer.save([b2])
    #expect(writer.flush(timeout: 10))
    let bFile = folder.appending(path: "\(b.id).png")
    let bDate = try FileManager.default.attributesOfItem(atPath: bFile.path)[.modificationDate] as? Date
    writer.save([b2, c])
    writer.save([b2])
    #expect(writer.flush(timeout: 10))
    #expect(try FileManager.default.attributesOfItem(atPath: bFile.path)[.modificationDate] as? Date == bDate)
    #expect(try Self.index(in: folder).map(\.id) == [b.id])
    #expect(Self.pngs(in: folder) == [b.id])
  }
}
