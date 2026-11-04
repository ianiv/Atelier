import CryptoKit
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// A result on disk while it waits for its client, and on the way there: "ATLR", the length of a
/// JSON description, the description, then each tensor in the compressed encoding projects use.
nonisolated enum RemoteResultFile {
  private static let magic = Data("ATLR".utf8)
  private static let codec: DynamicGraph.Store.Codec = [.fpzip, .zip]

  fileprivate struct Description: Codable, Sendable {
    var frameSizes: [Int]
    var audioSize: Int?
    var audioInputSize: Int?
    var audioSampleRate: Int
    var framesPerSecond: Double?
  }

  /// Writes `output` to `url`; returns the file's size and SHA-256.
  @concurrent static func write(_ output: GenerationEngine.Output, to url: URL) async throws -> (size: Int, hash: String) {
    let frames = output.frames.map { $0.data(using: codec) }
    let audio = output.audio?.data(using: codec)
    let audioInput = output.audioInput?.data(using: codec)
    let description = Description(
      frameSizes: frames.map(\.count), audioSize: audio?.count, audioInputSize: audioInput?.count,
      audioSampleRate: output.audioSampleRate, framesPerSecond: output.framesPerSecond)
    let json = try JSONEncoder().encode(description)
    var length = UInt32(json.count).bigEndian
    var file = magic
    withUnsafeBytes(of: &length) { file.append(contentsOf: $0) }
    file.append(json)
    for part in frames { file.append(part) }
    if let audio { file.append(audio) }
    if let audioInput { file.append(audioInput) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try file.write(to: url, options: .atomic)
    return (file.count, SHA256.hash(data: file).hexString)
  }

  /// A result opened for its parts, decoded one at a time: a long clip's frames needn't all be in
  /// memory at once.
  struct Reader: Sendable {
    private let data: Data
    private let description: Description
    private let start: Int
    var frameCount: Int { description.frameSizes.count }
    var framesPerSecond: Double? { description.framesPerSecond }

    init(url: URL) throws {
      data = try Data(contentsOf: url, options: .mappedIfSafe)
      let headerSize = magic.count + 4
      guard data.count >= headerSize, data.prefix(magic.count) == magic else { throw RemoteError.corruptResult }
      let length = data[(data.startIndex + magic.count)..<(data.startIndex + headerSize)].reduce(0) { $0 << 8 | Int($1) }
      let position = data.startIndex + headerSize
      guard data.endIndex - position >= length else { throw RemoteError.corruptResult }
      description = try JSONDecoder().decode(Description.self, from: data[position..<(position + length)])
      start = position + length
      let total = description.frameSizes.reduce(0, +) + (description.audioSize ?? 0) + (description.audioInputSize ?? 0)
      guard description.frameSizes.allSatisfy({ $0 >= 0 }), data.endIndex - start >= total else { throw RemoteError.corruptResult }
    }

    func frame(_ index: Int) throws -> Tensor<FloatType> {
      let offset = start + description.frameSizes.prefix(index).reduce(0, +)
      guard let tensor = Tensor<FloatType>(data: Data(data[offset..<(offset + description.frameSizes[index])]), using: codec) else {
        throw RemoteError.corruptResult
      }
      return tensor
    }

    private func audio(at offset: Int, size: Int?) throws -> Tensor<Float>? {
      guard let size else { return nil }
      guard let tensor = Tensor<Float>(data: Data(data[offset..<(offset + size)]), using: codec) else { throw RemoteError.corruptResult }
      return tensor
    }

    func output() throws -> GenerationEngine.Output {
      let framesEnd = start + description.frameSizes.reduce(0, +)
      return try GenerationEngine.Output(
        frames: (0..<frameCount).map(frame), audio: audio(at: framesEnd, size: description.audioSize),
        audioSampleRate: description.audioSampleRate, framesPerSecond: description.framesPerSecond,
        audioInput: audio(at: framesEnd + (description.audioSize ?? 0), size: description.audioInputSize))
    }
  }

  @concurrent static func read(_ url: URL) async throws -> GenerationEngine.Output {
    try Reader(url: url).output()
  }
}

nonisolated extension Sequence<UInt8> {
  var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
