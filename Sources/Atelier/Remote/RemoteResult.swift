import CryptoKit
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// A result on disk while it waits for its client, and on the way there: "ATLR", the length of a
/// JSON description, the description, then each tensor in the compressed encoding projects use.
nonisolated enum RemoteResultFile {
  private static let magic = Data("ATLR".utf8)
  private static let codec: DynamicGraph.Store.Codec = [.fpzip, .zip]

  private struct Description: Codable {
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

  @concurrent static func read(_ url: URL) async throws -> GenerationEngine.Output {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let headerSize = magic.count + 4
    guard data.count >= headerSize, data.prefix(magic.count) == magic else { throw RemoteError.corruptResult }
    let length = data[(data.startIndex + magic.count)..<(data.startIndex + headerSize)].reduce(0) { $0 << 8 | Int($1) }
    var position = data.startIndex + headerSize
    guard data.endIndex - position >= length else { throw RemoteError.corruptResult }
    let description = try JSONDecoder().decode(Description.self, from: data[position..<(position + length)])
    position += length

    func next(_ size: Int) throws -> Data {
      guard size >= 0, data.endIndex - position >= size else { throw RemoteError.corruptResult }
      defer { position += size }
      return Data(data[position..<(position + size)])
    }

    var frames: [Tensor<FloatType>] = []
    for size in description.frameSizes {
      guard let tensor = Tensor<FloatType>(data: try next(size), using: codec) else { throw RemoteError.corruptResult }
      frames.append(tensor)
    }
    func audio(_ size: Int?) throws -> Tensor<Float>? {
      guard let size else { return nil }
      guard let tensor = Tensor<Float>(data: try next(size), using: codec) else { throw RemoteError.corruptResult }
      return tensor
    }
    let audioTensor = try audio(description.audioSize)
    let audioInput = try audio(description.audioInputSize)
    return GenerationEngine.Output(
      frames: frames, audio: audioTensor, audioSampleRate: description.audioSampleRate,
      framesPerSecond: description.framesPerSecond, audioInput: audioInput)
  }
}

nonisolated extension Sequence<UInt8> {
  var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
