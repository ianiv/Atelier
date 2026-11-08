@testable import Atelier
import Foundation
import Testing

struct ModelMoveTests {
  private func write(_ text: String, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
  }

  private func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
  }

  private func move(
    _ file: String, moved: [String], copied: [String] = [], registry: String? = nil, from source: URL, to destination: URL,
    sameVolume: Bool
  ) -> ModelLibrary.Move {
    ModelLibrary.Move(
      kind: .model, name: file, file: file, source: source, destination: destination, moved: moved, copied: copied,
      registry: registry, movedBytes: 0, copiedBytes: 0, sameVolume: sameVolume)
  }

  @Test func sharedFilesAreCopiedAndTheRestMoves() {
    withTestFolder { root in
      let source = root.appending(path: "A"), destination = root.appending(path: "B")
      for file in ["m_f16.ckpt", "m_f16.ckpt-tensordata", "own_vae.ckpt", "shared_te.ckpt", "there.ckpt"] {
        touch(source.appending(path: file))
      }
      touch(destination.appending(path: "there.ckpt"))
      let (moved, copied) = ModelLibrary.sortFiles(
        own: ["m_f16.ckpt"], needs: ["m_f16.ckpt", "own_vae.ckpt", "shared_te.ckpt", "there.ckpt", "missing.ckpt"],
        neededElsewhere: ["shared_te.ckpt", "there.ckpt"], from: source, to: destination)
      #expect(moved == ["m_f16.ckpt", "m_f16.ckpt-tensordata", "own_vae.ckpt"])
      #expect(copied == ["shared_te.ckpt"])
    }
  }

  @Test func aMoveAcrossDrivesCopiesChecksAndDeletes() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ModelMoveTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "A"), destination = root.appending(path: "B")
    write("weights", source.appending(path: "m.ckpt"))
    write("data", source.appending(path: "m.ckpt-tensordata"))
    write("encoder", source.appending(path: "te.ckpt"))
    write(#"[{"file":"m.ckpt","name":"M","extra":1},{"file":"other.ckpt","name":"O"}]"#, source.appending(path: "custom.json"))
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let plan = move(
      "m.ckpt", moved: ["m.ckpt", "m.ckpt-tensordata"], copied: ["te.ckpt"], registry: "custom.json", from: source,
      to: destination, sameVolume: false)
    try await ModelLibrary.transfer(plan) { _ in }
    #expect(read(destination.appending(path: "m.ckpt")) == "weights")
    #expect(read(destination.appending(path: "m.ckpt-tensordata")) == "data")
    #expect(read(destination.appending(path: "te.ckpt")) == "encoder")
    #expect(read(source.appending(path: "te.ckpt")) == "encoder")
    #expect(!FileManager.default.fileExists(atPath: source.appending(path: "m.ckpt").path))
    #expect(!FileManager.default.fileExists(atPath: source.appending(path: "m.ckpt-tensordata").path))
    let moved = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appending(path: "custom.json"))) as? [[String: Any]]
    let left = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appending(path: "custom.json"))) as? [[String: Any]]
    #expect(moved?.map { $0["file"] as? String } == ["m.ckpt"])
    #expect(moved?.first?["extra"] as? Int == 1)
    #expect(left?.map { $0["file"] as? String } == ["other.ckpt"])
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasSuffix(".part") }
    #expect(leftovers.isEmpty)
  }

  @Test func aMoveOnOneDriveRenames() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ModelMoveTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "A"), destination = root.appending(path: "B")
    write("lora", source.appending(path: "l.ckpt"))
    write(#"[{"file":"z.ckpt","name":"Zed"}]"#, destination.appending(path: "custom_lora.json"))
    write(#"[{"file":"l.ckpt","name":"Alpha"}]"#, source.appending(path: "custom_lora.json"))
    let plan = move("l.ckpt", moved: ["l.ckpt"], registry: "custom_lora.json", from: source, to: destination, sameVolume: true)
    try await ModelLibrary.transfer(plan) { _ in }
    #expect(read(destination.appending(path: "l.ckpt")) == "lora")
    #expect(!FileManager.default.fileExists(atPath: source.appending(path: "l.ckpt").path))
    let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appending(path: "custom_lora.json"))) as? [[String: Any]]
    #expect(entries?.map { $0["name"] as? String } == ["Alpha", "Zed"])
  }

  @Test func anUnreadableRegistryStopsTheMoveBeforeAnythingIsDeleted() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ModelMoveTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "A"), destination = root.appending(path: "B")
    write("weights", source.appending(path: "m.ckpt"))
    write(#"[{"file":"m.ckpt"}]"#, source.appending(path: "custom.json"))
    write("not json", destination.appending(path: "custom.json"))
    let plan = move("m.ckpt", moved: ["m.ckpt"], registry: "custom.json", from: source, to: destination, sameVolume: false)
    await #expect(throws: ModelLibrary.MoveFailure.self) { try await ModelLibrary.transfer(plan) { _ in } }
    #expect(read(source.appending(path: "m.ckpt")) == "weights")
    #expect(read(destination.appending(path: "custom.json")) == "not json")
  }

  @Test func aCancelledMoveLeavesTheSourceAndNoPartFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ModelMoveTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "A"), destination = root.appending(path: "B")
    write("weights", source.appending(path: "m.ckpt"))
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let plan = move("m.ckpt", moved: ["m.ckpt"], from: source, to: destination, sameVolume: false)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await ModelLibrary.transfer(plan) { _ in }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(read(source.appending(path: "m.ckpt")) == "weights")
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }
}
