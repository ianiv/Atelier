@testable import Atelier
@preconcurrency import Diffusion
import Foundation
import Testing

/// Joining split safetensors: three small parts of mixed dtypes and odd sizes with their index,
/// read back by the engine's own reader with every tensor's bytes in place and the header aligned;
/// and the index checks (a tensor in the wrong part, a tensor twice, a part missing).
@Suite(.tags(.smoke))
struct SafetensorsMergeTests {
  private struct Tensor {
    var name: String
    var dtype: String
    var shape: [Int]
    var bytes: Data
  }

  private static func bytes(_ count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
  }

  /// Writes a safetensors file the way the library does, with an unpadded header (odd length).
  private static func write(_ tensors: [Tensor], metadata: [String: String]? = nil, to url: URL) throws {
    var header: [String: Any] = [:]
    var data = Data()
    for tensor in tensors {
      header[tensor.name] = ["dtype": tensor.dtype, "shape": tensor.shape, "data_offsets": [data.count, data.count + tensor.bytes.count]]
      data.append(tensor.bytes)
    }
    if let metadata { header["__metadata__"] = metadata }
    let json = try JSONSerialization.data(withJSONObject: header)
    var length = UInt64(json.count).littleEndian
    var file = Data(bytes: &length, count: 8)
    file.append(json)
    file.append(data)
    try file.write(to: url)
  }

  private static let parts: [[Tensor]] = [
    [
      Tensor(name: "a.weight", dtype: "F32", shape: [3, 5], bytes: bytes(60, seed: 1)),
      Tensor(name: "a.bias", dtype: "F16", shape: [7], bytes: bytes(14, seed: 2)),
    ],
    [Tensor(name: "b.weight", dtype: "BF16", shape: [9], bytes: bytes(18, seed: 3))],
    [
      Tensor(name: "c.scale", dtype: "U8", shape: [3], bytes: bytes(3, seed: 4)),
      Tensor(name: "c.weight", dtype: "F16", shape: [5, 1], bytes: bytes(10, seed: 5)),
    ],
  ]

  private func makeParts(in folder: URL, index: [String: String]? = nil) throws -> (shards: [URL], index: URL) {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var shards: [URL] = []
    var weightMap: [String: String] = [:]
    for (number, tensors) in Self.parts.enumerated() {
      let name = "model-0000\(number + 1)-of-00003.safetensors"
      let url = folder.appendingPathComponent(name)
      try Self.write(tensors, metadata: number == 0 ? ["format": "pt"] : ["format": "other"], to: url)
      shards.append(url)
      for tensor in tensors { weightMap[tensor.name] = name }
    }
    let indexURL = folder.appendingPathComponent("model.safetensors.index.json")
    try JSONSerialization.data(withJSONObject: ["metadata": ["total_size": 105], "weight_map": index ?? weightMap]).write(to: indexURL)
    return (shards, indexURL)
  }

  private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "SafetensorsMergeTests-\(UUID().uuidString)")
  }

  @Test func joinedFileReadsBackThroughTheEngine() throws {
    let folder = folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (shards, index) = try makeParts(in: folder)
    let output = folder.appendingPathComponent("joined.safetensors")
    try SafetensorsMerge.merge(shards: shards, index: index, into: output, deletingShards: true) { _ in }
    #expect(shards.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    #expect(!FileManager.default.fileExists(atPath: output.path + ".partial"))

    let data = try Data(contentsOf: output)
    let headerLength = data.prefix(8).withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
    #expect((8 + headerLength) % 8 == 0)
    #expect(data.count == 8 + headerLength + 105)
    let header = try #require(try SafetensorsHeader.read(output))
    #expect((header["__metadata__"] as? [String: String]) == ["format": "pt"])

    // The engine's reader (which skips integer dtypes) finds the float tensors at their bytes.
    let archive = try #require(SafeTensors(url: output))
    let tensors = Self.parts.flatMap(\.self)
    #expect(Set(archive.states.keys) == Set(tensors.filter { $0.dtype != "U8" }.map(\.name)))
    for tensor in tensors {
      let offsets = try #require((header[tensor.name] as? [String: Any])?["data_offsets"] as? [Int])
      let start = 8 + headerLength + offsets[0]
      #expect(data.subdata(in: start..<(start + tensor.bytes.count)) == tensor.bytes, "\(tensor.name)")
      #expect(offsets[1] - offsets[0] == tensor.bytes.count)
      if let state = archive.states[tensor.name] {
        let begin = archive.bufferStart + state.storageOffset
        #expect(archive.data.subdata(in: begin..<(begin + tensor.bytes.count)) == tensor.bytes)
        #expect(state.shape == tensor.shape)
      }
    }
  }

  @Test func joinsWithoutAnIndexAndKeepsParts() throws {
    let folder = folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (shards, _) = try makeParts(in: folder)
    let output = folder.appendingPathComponent("joined.safetensors")
    try SafetensorsMerge.merge(shards: shards, index: nil, into: output, deletingShards: false) { _ in }
    #expect(shards.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(try SafetensorsHeader.read(output)?.count == 6)
  }

  @Test func rejectsATensorInThePartTheIndexDoesntName() throws {
    let folder = folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var map = Dictionary(uniqueKeysWithValues: Self.parts.enumerated().flatMap { number, tensors in
      tensors.map { ($0.name, "model-0000\(number + 1)-of-00003.safetensors") }
    })
    map["b.weight"] = "model-00001-of-00003.safetensors"
    let (shards, index) = try makeParts(in: folder, index: map)
    let output = folder.appendingPathComponent("joined.safetensors")
    #expect(throws: SafetensorsMerge.Error.wrongShard(tensor: "b.weight", index: "model-00001-of-00003.safetensors", file: "model-00002-of-00003.safetensors")) {
      try SafetensorsMerge.merge(shards: shards, index: index, into: output, deletingShards: true) { _ in }
    }
    // Nothing is deleted or written when the check fails.
    #expect(shards.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func rejectsADuplicateTensor() throws {
    let folder = folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (shards, _) = try makeParts(in: folder)
    let output = folder.appendingPathComponent("joined.safetensors")
    // The first part's tensors come again in the second; which one is found first can vary.
    let error = #expect(throws: SafetensorsMerge.Error.self) {
      try SafetensorsMerge.merge(shards: [shards[0], shards[0]], index: nil, into: output, deletingShards: false) { _ in }
    }
    #expect(error == .duplicateTensor("a.weight") || error == .duplicateTensor("a.bias"))
  }

  @Test func rejectsAMissingPart() throws {
    let folder = folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (shards, index) = try makeParts(in: folder)
    let output = folder.appendingPathComponent("joined.safetensors")
    #expect(throws: SafetensorsMerge.Error.self) {
      try SafetensorsMerge.merge(shards: Array(shards.prefix(2)), index: index, into: output, deletingShards: false) { _ in }
    }
    let parts = try shards.prefix(2).map(SafetensorsMerge.part(at:))
    let weightMap = try SafetensorsMerge.weightMap(Data(contentsOf: index))
    #expect(throws: SafetensorsMerge.Error.missingShard("model-00003-of-00003.safetensors")) {
      try SafetensorsMerge.mergedHeader(parts, weightMap: weightMap)
    }
  }

  @Test func cancellingStopsTheJoinAndKeepsWhatsLeft() throws {
    let folder = folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (shards, index) = try makeParts(in: folder)
    let output = folder.appendingPathComponent("joined.safetensors")
    #expect(throws: CancellationError.self) {
      try SafetensorsMerge.merge(shards: shards, index: index, into: output, deletingShards: true, isCancelled: { true }) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(shards.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    // Joining again afterwards works.
    try SafetensorsMerge.merge(shards: shards, index: index, into: output, deletingShards: true) { _ in }
    #expect(try SafetensorsHeader.read(output)?.count == 6)
  }

  @Test func sparseStandInHasTheHeaderAndFullLength() throws {
    let folder = folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (shards, index) = try makeParts(in: folder)
    let parts = try shards.map(SafetensorsMerge.part(at:))
    let header = try SafetensorsMerge.mergedHeader(parts, weightMap: SafetensorsMerge.weightMap(Data(contentsOf: index)))
    let standIn = folder.appendingPathComponent("stand-in.safetensors")
    try SafetensorsMerge.writeSparse(header: header, dataLength: 105, to: standIn)
    #expect(ModelLibrary.size(of: standIn) == Int64(8 + header.count + 105))
    #expect(try SafetensorsHeader.read(standIn)?.count == 6)
  }
}
