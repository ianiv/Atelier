import Foundation
import Network

/// What a frame's payload is.
nonisolated enum RemoteFrameKind: UInt8, Sendable {
  /// A JSON `RemoteEnvelope`.
  case message = 1
  /// A chunk of a file: a short JSON header, then raw bytes.
  case chunk = 2
}

/// The five bytes in front of every frame: its kind, and its payload's length (big endian).
nonisolated struct RemoteFrameHeader: Equatable, Sendable {
  static let size = 5
  /// Larger frames are refused before anything is read. A video's previews are the largest thing
  /// sent as one frame; files go in chunks.
  static let maxPayload = 64 << 20

  var kind: RemoteFrameKind
  var length: UInt32

  init(kind: RemoteFrameKind, length: UInt32) {
    self.kind = kind
    self.length = length
  }

  /// Nil for an unknown kind or a payload over the limit: the peer isn't speaking this protocol.
  init?(_ bytes: some Collection<UInt8>) {
    let bytes = Array(bytes.prefix(Self.size))
    guard bytes.count == Self.size, let kind = RemoteFrameKind(rawValue: bytes[0]) else { return nil }
    let length = bytes[1...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    guard length <= Self.maxPayload else { return nil }
    self.init(kind: kind, length: length)
  }

  var encoded: Data {
    Data([kind.rawValue, UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
  }
}

/// Splits a connection's byte stream into frames, so JSON messages and binary chunks can share it.
/// Follows the framer in Apple's "Building a custom peer-to-peer protocol" sample.
final nonisolated class RemoteFramer: NWProtocolFramerImplementation {
  static let label = "Atelier"
  static let definition = NWProtocolFramer.Definition(implementation: RemoteFramer.self)
  private static let kindKey = "kind"

  required init(framer _: NWProtocolFramer.Instance) {}
  func start(framer _: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
  func wakeup(framer _: NWProtocolFramer.Instance) {}
  func stop(framer _: NWProtocolFramer.Instance) -> Bool { true }
  func cleanup(framer _: NWProtocolFramer.Instance) {}

  func handleOutput(
    framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete _: Bool
  ) {
    guard let kind = message[Self.kindKey] as? RemoteFrameKind, messageLength <= RemoteFrameHeader.maxPayload else {
      framer.markFailed(error: .posix(.EMSGSIZE))
      return
    }
    framer.writeOutput(data: RemoteFrameHeader(kind: kind, length: UInt32(messageLength)).encoded)
    do {
      try framer.writeOutputNoCopy(length: messageLength)
    } catch {
      framer.markFailed(error: .posix(.EIO))
    }
  }

  func handleInput(framer: NWProtocolFramer.Instance) -> Int {
    while true {
      var header: RemoteFrameHeader?
      var isValid = true
      let parsed = framer.parseInput(
        minimumIncompleteLength: RemoteFrameHeader.size, maximumLength: RemoteFrameHeader.size
      ) { buffer, _ -> Int in
        guard let buffer, buffer.count >= RemoteFrameHeader.size else { return 0 }
        header = RemoteFrameHeader(buffer)
        isValid = header != nil
        return RemoteFrameHeader.size
      }
      guard isValid else {
        framer.markFailed(error: .posix(.EBADMSG))
        return 0
      }
      guard parsed, let header else { return RemoteFrameHeader.size }
      let message = NWProtocolFramer.Message(definition: Self.definition)
      message[Self.kindKey] = header.kind
      guard framer.deliverInputNoCopy(length: Int(header.length), message: message, isComplete: true) else {
        return 0
      }
    }
  }

  static func context(for kind: RemoteFrameKind) -> NWConnection.ContentContext {
    let message = NWProtocolFramer.Message(definition: definition)
    message[kindKey] = kind
    return NWConnection.ContentContext(identifier: "AtelierFrame", metadata: [message])
  }

  static func kind(in context: NWConnection.ContentContext?) -> RemoteFrameKind? {
    (context?.protocolMetadata(definition: definition) as? NWProtocolFramer.Message)?[kindKey] as? RemoteFrameKind
  }
}
