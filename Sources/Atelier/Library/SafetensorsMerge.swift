import Foundation

/// Joins split (sharded) safetensors into one file, which is what the importers take
/// (`ModelImporter` and the engine's `SafeTensors(url:)` read one file). Hugging Face splits large
/// checkpoints into `<name>-0000N-of-0000M.safetensors` with a `<name>.safetensors.index.json`
/// whose `weight_map` names the part each tensor is in.
///
/// The joined file is the parts' data back to back under one header whose offsets are shifted by
/// where each part's data starts. The header is padded with spaces to a multiple of 8 bytes, as
/// the safetensors library writes it, and must stay under the engine reader's 10 MiB limit.
nonisolated enum SafetensorsMerge {
  /// `SafeTensors(url:)` turns away a longer header.
  static let maxHeaderLength = 10 * 1024 * 1024
  static let chunkSize = 64 * 1024 * 1024

  enum Error: LocalizedError, Equatable {
    case notSafetensors(String)
    case duplicateTensor(String)
    case wrongShard(tensor: String, index: String, file: String)
    case missingShard(String)
    case missingTensor(String)
    case badOffsets(String)
    case headerTooLarge

    var errorDescription: String? {
      switch self {
      case .notSafetensors(let file): "\(file) isn't a safetensors file."
      case .duplicateTensor(let name): "The parts both have the tensor \(name)."
      case .wrongShard(let tensor, let index, let file): "The index puts \(tensor) in \(index), but it's in \(file)."
      case .missingShard(let file): "The index names \(file), which isn't among the parts."
      case .missingTensor(let name): "The index lists \(name), which none of the parts has."
      case .badOffsets(let name): "\(name)'s data offsets are outside its file."
      case .headerTooLarge: "The joined header would be larger than the importer reads."
      }
    }
  }

  /// One part's header: its tensors and how long its data is.
  struct Part {
    var name: String
    var header: [String: Any]
    /// Bytes of tensor data after the header.
    var dataLength: Int64
  }

  /// The `weight_map` of a shard index file.
  static func weightMap(_ data: Data) throws -> [String: String] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let map = object["weight_map"] as? [String: String]
    else { throw Error.notSafetensors("The index") }
    return map
  }

  /// The joined header's bytes (padded, without the 8-byte length), checked against `weightMap`
  /// when there is one: every tensor once, in the part the index names, and every part the
  /// index names present. The first part's `__metadata__` is kept.
  static func mergedHeader(_ parts: [Part], weightMap: [String: String]?) throws -> Data {
    var merged: [String: Any] = [:]
    var metadata: Any?
    var base: Int64 = 0
    var seen = Set<String>()
    for part in parts {
      for (name, value) in part.header {
        if name == "__metadata__" {
          if metadata == nil { metadata = value }
          continue
        }
        guard var tensor = value as? [String: Any],
              let offsets = (tensor["data_offsets"] as? [NSNumber])?.map(\.int64Value), offsets.count == 2,
              offsets[0] >= 0, offsets[0] <= offsets[1], offsets[1] <= part.dataLength
        else { throw Error.badOffsets(name) }
        guard seen.insert(name).inserted else { throw Error.duplicateTensor(name) }
        if let weightMap {
          guard let expected = weightMap[name] else { throw Error.wrongShard(tensor: name, index: "no part", file: part.name) }
          guard expected == part.name else { throw Error.wrongShard(tensor: name, index: expected, file: part.name) }
        }
        tensor["data_offsets"] = [base + offsets[0], base + offsets[1]]
        merged[name] = tensor
      }
      base += part.dataLength
    }
    if let weightMap {
      let names = Set(parts.map(\.name))
      if let missing = Set(weightMap.values).subtracting(names).sorted().first { throw Error.missingShard(missing) }
      if let missing = Set(weightMap.keys).subtracting(seen).sorted().first { throw Error.missingTensor(missing) }
    }
    if let metadata { merged["__metadata__"] = metadata }
    var json = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    // 8 + header a multiple of 8, so tensor data starts aligned.
    let padding = (8 - json.count % 8) % 8
    json.append(contentsOf: [UInt8](repeating: 0x20, count: padding))
    guard json.count < maxHeaderLength else { throw Error.headerTooLarge }
    return json
  }

  /// A part's header and data length from its file.
  static func part(at url: URL) throws -> Part {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let header = try SafetensorsHeader.read(from: handle) else { throw Error.notSafetensors(url.lastPathComponent) }
    let dataStart = try handle.offset()
    let end = try handle.seekToEnd()
    return Part(name: url.lastPathComponent, header: header, dataLength: Int64(end - dataStart))
  }

  /// Writes the parts at `shards`, in order, as one file at `output`, checking them against the
  /// index at `index` when given. Written beside it as `.partial` and renamed when complete, so an
  /// interrupted join leaves nothing under the real name. With `deletingShards`, each part is
  /// deleted once copied, so the join needs only one part's worth of extra disk space.
  static func merge(
    shards: [URL], index: URL?, into output: URL, deletingShards: Bool,
    progress: @Sendable (Double) -> Void
  ) throws {
    let weightMap = try index.map { try Self.weightMap(Data(contentsOf: $0)) }
    let parts = try shards.map(part(at:))
    let header = try mergedHeader(parts, weightMap: weightMap)
    let partial = output.appendingPathExtension("partial")
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: partial)
    guard fileManager.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    let out = try FileHandle(forWritingTo: partial)
    var closed = false
    defer { if !closed { try? out.close() } }
    var length = UInt64(header.count).littleEndian
    try out.write(contentsOf: Data(bytes: &length, count: 8))
    try out.write(contentsOf: header)
    let total = max(1, parts.reduce(Int64(0)) { $0 + $1.dataLength })
    var copied: Int64 = 0
    for (url, part) in zip(shards, parts) {
      let input = try FileHandle(forReadingFrom: url)
      let end = try input.seekToEnd()
      try input.seek(toOffset: end - UInt64(part.dataLength))
      var remaining = part.dataLength
      while remaining > 0 {
        try autoreleasepool {
          let count = Int(min(Int64(chunkSize), remaining))
          guard let data = try input.read(upToCount: count), data.count == count else {
            throw CocoaError(.fileReadCorruptFile)
          }
          try out.write(contentsOf: data)
          remaining -= Int64(count)
          copied += Int64(count)
          progress(Double(copied) / Double(total))
        }
      }
      try input.close()
      if deletingShards { try fileManager.removeItem(at: url) }
    }
    try out.close()
    closed = true
    try? fileManager.removeItem(at: output)
    try fileManager.moveItem(at: partial, to: output)
  }

  /// A stand-in for the joined file with the real header and length but no data: a sparse file,
  /// so the importer's inspection can read the header before anything is downloaded.
  static func writeSparse(header: Data, dataLength: Int64, to url: URL) throws {
    var length = UInt64(header.count).littleEndian
    var data = Data(bytes: &length, count: 8)
    data.append(header)
    try data.write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(data.count) + UInt64(dataLength))
  }
}
