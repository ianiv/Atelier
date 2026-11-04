import Foundation

/// The job protocol between Atelier clients and a device with Compute turned on. A client keeps
/// the project and sends jobs; the server runs them on its own engine and holds each result until
/// the client has it.
nonisolated enum RemoteProtocol {
  /// Sent in hello; a server refuses a client on another version.
  static let version = 1
  static let serviceType = "_atelier._tcp"
  static let defaultPort: UInt16 = 7863
  /// The TLS identity of a connection that's pairing rather than a paired device's.
  static let pairIdentity = "pair"
  static let chunkSize = 1 << 20
  /// Larger uploads are refused.
  static let maxBlobSize = 1 << 30
  /// How long results nobody collected, and uploads nothing used, stay on the server.
  static let retention: TimeInterval = 7 * 24 * 60 * 60
  static let maxDeviceNameLength = 64
}

nonisolated struct RemoteModelInfo: Codable, Hashable, Sendable {
  var file: String
  var name: String
  var version: String?
  /// What a client without the file needs to know about it.
  var traits: RemoteModelTraits?
}

/// What a server can upscale with.
nonisolated struct RemoteUpscalers: Codable, Hashable, Sendable {
  /// The FlashVSR+ variants it has, by raw value.
  var flashVSR: [FlashVSRFiles.Variant] = []
  var superResolution = false
}

nonisolated struct RemoteLoRAInfo: Codable, Hashable, Sendable {
  var file: String
  var name: String
  var version: String
  var prefix: String
  var modifier: String
}

/// A `GenerationEngine.Request` as it travels: images and audio by SHA-256 of what was uploaded.
/// What only the client's project means (parent and canvas steps, timeline placement) stays there.
nonisolated struct RemoteJobRequest: Codable, Hashable, Sendable {
  struct Reference: Codable, Hashable, Sendable {
    var hash: String
    var weight: Float
  }

  struct Audio: Codable, Hashable, Sendable {
    var hash: String
    var fileExtension: String
  }

  var model: String
  var prompt: String
  var negativePrompt: String
  var seed: UInt32
  /// Every setting, in the history sidecar's dump format.
  var settings: [String: JSONValue]
  /// The canvas as a PNG.
  var canvas: String?
  var canvasIsImported = false
  /// Moodboard images as PNGs.
  var moodboard: [Reference] = []
  var audio: Audio?
  /// An upscale job: how, and its frames, as PNGs, or a clip of this device's the server still has.
  var upscale: ClipUpscale?
  var frames: [String] = []
  var sourceClip: UUID?
}

nonisolated enum RemoteJobState: String, Codable, Sendable {
  case queued, preparing, encodingText, encodingInputs, generating, decoding, postprocessing, cancelling
  /// Generated; being written out for download.
  case packing
  /// Waiting for the client to download it.
  case ready
  case failed, cancelled

  var isFinal: Bool { self == .ready || self == .failed || self == .cancelled }
}

nonisolated struct RemoteJobEvent: Codable, Hashable, Sendable {
  var jobID: UUID
  var state: RemoteJobState
  var step: Int?
  var totalSteps: Int?
  /// JPEGs: one for an image, one per latent frame for a video.
  var previews: [Data]?
  /// `ready`: the result's size and SHA-256, and whether it's a clip, kept a while after it's
  /// collected in case it's upscaled next.
  var resultSize: Int?
  var resultHash: String?
  var resultIsClip: Bool?
  /// `failed`: why.
  var message: String?
}

nonisolated enum RemoteMessage: Codable, Sendable {
  // Opening a connection. `proof` shows the sender holds the key for the identity it claims: TLS
  // only shows it holds some key on the server's list (`RemotePairing.proof`).
  case hello(version: Int, deviceID: UUID, deviceName: String, proof: Data)
  case welcome(version: Int, serverID: UUID, serverName: String)
  case pairRequest(version: Int, deviceID: UUID, deviceName: String, proof: Data, publicKey: Data)
  case pairGranted(serverID: UUID, serverName: String, publicKey: Data, sealedKey: Data)
  case refused(String)

  // What the server has.
  case catalogRequest
  /// `files`: every file name in the server's models folders, which offer refiners and upscalers.
  case catalog(models: [RemoteModelInfo], loras: [RemoteLoRAInfo], files: [String], upscalers: RemoteUpscalers)
  case modelDefaultsRequest(model: String)
  case modelDefaults(settings: [String: JSONValue])

  // Uploads, by SHA-256. `partial` is how much of an interrupted upload the server has.
  case blobCheck(hashes: [String])
  case blobStatus(complete: [String], partial: [String: Int])
  case blobAck(hash: String, offset: Int)
  /// Whether the server still has a clip it made for this device.
  case clipCheck(jobID: UUID)
  case clipStatus(Bool)

  // Jobs. Only the device that submitted a job can see it.
  case submitJob(jobID: UUID, request: RemoteJobRequest)
  case jobAccepted(jobID: UUID)
  case jobEvent(RemoteJobEvent)
  /// Asks for the job's latest state again after reconnecting.
  case subscribe(jobID: UUID)
  case listJobs
  case jobs([RemoteJobEvent])
  case cancel(jobID: UUID)

  // The result, in chunks from any offset, so a dropped download picks up where it stopped.
  case resultRequest(jobID: UUID, offset: Int, length: Int)
  /// Client has the result; the server can delete it.
  case ackResult(jobID: UUID)

  case ok
  case failure(String)
}

/// A message, and the request it belongs to: a reply carries its request's id, and events none.
nonisolated struct RemoteEnvelope: Codable, Sendable {
  var requestID: UUID?
  var message: RemoteMessage
}

nonisolated struct RemoteChunkHeader: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable { case upload, result }

  var requestID: UUID
  var kind: Kind
  /// The blob's hash, or the job's id.
  var id: String
  var offset: Int
  var total: Int
}

/// One frame on the connection.
nonisolated enum RemoteFrame: Sendable {
  case message(RemoteEnvelope)
  case chunk(RemoteChunkHeader, Data)

  enum CodingError: Error { case malformed }

  func encoded() throws -> (kind: RemoteFrameKind, payload: Data) {
    switch self {
    case .message(let envelope):
      return (.message, try JSONEncoder().encode(envelope))
    case .chunk(let header, let bytes):
      let json = try JSONEncoder().encode(header)
      guard json.count <= Int(UInt16.max) else { throw CodingError.malformed }
      var payload = Data([UInt8(json.count >> 8), UInt8(json.count & 0xFF)])
      payload.append(json)
      payload.append(bytes)
      return (.chunk, payload)
    }
  }

  init(kind: RemoteFrameKind, payload: Data) throws {
    switch kind {
    case .message:
      self = .message(try JSONDecoder().decode(RemoteEnvelope.self, from: payload))
    case .chunk:
      let start = payload.startIndex
      guard payload.count >= 2 else { throw CodingError.malformed }
      let length = Int(payload[start]) << 8 | Int(payload[start + 1])
      guard payload.count >= 2 + length else { throw CodingError.malformed }
      let header = try JSONDecoder().decode(RemoteChunkHeader.self, from: payload[(start + 2)..<(start + 2 + length)])
      self = .chunk(header, Data(payload[(start + 2 + length)...]))
    }
  }
}

nonisolated enum RemoteError: LocalizedError, Equatable {
  /// The server turned this device's key down: it was removed there.
  case notPaired(server: String)
  case unreachable(server: String)
  case connectionLost
  case versionMismatch
  case wrongServer
  case unknownServer
  case wrongCode
  case pairingClosed
  case invalidPairingLink
  /// The server's answer.
  case server(String)
  case corruptResult
  /// Upscaling on a server comes with video jobs.
  case unsupported(String)

  var errorDescription: String? {
    switch self {
    case .notPaired(let server): "This device isn't paired with \(server) anymore. Pair it again in Settings ▸ Compute."
    case .unreachable(let server): "Couldn't reach \(server)."
    case .connectionLost: "The connection to the server was lost."
    case .versionMismatch: "This server runs a different version of Atelier. Update both to the same version."
    case .wrongServer: "A different server answered at this address."
    case .unknownServer: "That server isn't paired with this device."
    case .wrongCode: "The pairing code wasn't accepted. Check it, or make a new one on the server."
    case .pairingClosed: "The server isn't pairing right now. Choose Pair a Device… there and try again."
    case .invalidPairingLink: "That isn't an Atelier pairing link."
    case .server(let message): message
    case .corruptResult: "The result didn't arrive intact."
    case .unsupported(let what): "\(what) can't run on a server yet."
    }
  }
}
