@testable import Atelier
import CryptoKit
@preconcurrency import Diffusion
import Foundation
@preconcurrency import ModelZoo
import Network
@preconcurrency import NNC
import Testing

struct RemoteFramingTests {
  @Test func headersRoundTrip() {
    let header = RemoteFrameHeader(kind: .chunk, length: 0x0102_0304)
    #expect(Array(header.encoded) == [2, 1, 2, 3, 4])
    #expect(RemoteFrameHeader(Array(header.encoded)) == header)
    #expect(RemoteFrameHeader(Array(RemoteFrameHeader(kind: .chunk, length: 0x0400_0001).encoded)) == nil, "over the size limit")
    let small = RemoteFrameHeader(kind: .message, length: 70000)
    #expect(RemoteFrameHeader(Array(small.encoded)) == small)
    #expect(RemoteFrameHeader([9, 0, 0, 0, 1]) == nil, "unknown kind")
    #expect(RemoteFrameHeader([1, 0, 0]) == nil, "too short")
  }

  @Test func messagesRoundTrip() throws {
    let id = UUID()
    let (kind, payload) = try RemoteFrame.message(RemoteEnvelope(requestID: id, message: .cancel(jobID: id))).encoded()
    #expect(kind == .message)
    guard case .message(let envelope) = try RemoteFrame(kind: kind, payload: payload),
          case .cancel(let job) = envelope.message
    else { Issue.record("wrong frame"); return }
    #expect(envelope.requestID == id && job == id)
  }

  @Test func chunksRoundTrip() throws {
    let header = RemoteChunkHeader(requestID: UUID(), kind: .upload, id: "abc", offset: 5, total: 10)
    let (kind, payload) = try RemoteFrame.chunk(header, Data([1, 2, 3])).encoded()
    #expect(kind == .chunk)
    guard case .chunk(let decoded, let bytes) = try RemoteFrame(kind: kind, payload: payload) else {
      Issue.record("wrong frame")
      return
    }
    #expect(decoded == header && bytes == Data([1, 2, 3]))
    #expect(throws: (any Error).self) { try RemoteFrame(kind: .chunk, payload: Data([0xFF])) }
    #expect(throws: (any Error).self) { try RemoteFrame(kind: .chunk, payload: Data([0xFF, 0xFF, 1])) }
  }

  /// Through a real connection (no TLS, which `--remote-check` covers): frames in both kinds, sent
  /// back to back, come out whole and in order.
  @Test func framesCrossAConnection() async throws {
    func parameters() -> NWParameters {
      let parameters = NWParameters.tcp
      parameters.defaultProtocolStack.applicationProtocols.insert(
        NWProtocolFramer.Options(definition: RemoteFramer.definition), at: 0)
      return parameters
    }
    let listener = try NWListener(using: parameters(), on: .any)
    let received = AsyncStream<RemoteConnection>.makeStream()
    listener.newConnectionHandler = { connection in
      let remote = RemoteConnection(connection)
      remote.startAccepted()
      received.continuation.yield(remote)
    }
    let ready = AsyncStream<UInt16>.makeStream()
    listener.stateUpdateHandler = { state in
      if case .ready = state, let port = listener.port { ready.continuation.yield(port.rawValue) }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }
    var ports = ready.stream.makeAsyncIterator()
    let port = try #require(await ports.next())
    let client = RemoteConnection(NWConnection(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: parameters()))
    defer { client.cancel() }
    try await client.start()
    var connections = received.stream.makeAsyncIterator()
    let server = try #require(await connections.next())

    let job = UUID()
    let big = Data((0..<(3 << 20)).map { UInt8($0 & 0xFF) })
    let header = RemoteChunkHeader(requestID: job, kind: .result, id: "x", offset: 0, total: big.count)
    client.sendNow(.message(RemoteEnvelope(message: .ackResult(jobID: job))))
    client.sendNow(.chunk(header, big))
    client.sendNow(.message(RemoteEnvelope(message: .ok)))

    guard case .message(let first) = try await server.receive(), case .ackResult(let id) = first.message else {
      Issue.record("wrong first frame")
      return
    }
    #expect(id == job)
    guard case .chunk(let second, let bytes) = try await server.receive() else {
      Issue.record("wrong second frame")
      return
    }
    #expect(second == header && bytes == big)
    guard case .message(let third) = try await server.receive(), case .ok = third.message else {
      Issue.record("wrong third frame")
      return
    }
  }
}

struct RemotePairingTests {
  @Test func codesUseCrockfordAlphabet() {
    let codes = (0..<200).map { _ in RemotePairing.newCode() }
    for code in codes {
      #expect(code.count == 10)
      #expect(code.allSatisfy { RemotePairing.alphabet.contains($0) })
      #expect(!code.contains { "ILOU".contains($0) })
      #expect(RemotePairing.normalizedCode(code) == code)
    }
    #expect(Set(codes).count == codes.count)
  }

  @Test func typedCodesAreForgiving() {
    #expect(RemotePairing.normalizedCode("abcde-fghjk") == "ABCDEFGHJK")
    #expect(RemotePairing.normalizedCode(" o1il0 23456 ") == "01110" + "23456")
    #expect(RemotePairing.normalizedCode("ABCDE") == nil, "too short")
    #expect(RemotePairing.normalizedCode("ABCDEFGHJKM") == nil, "too long")
    #expect(RemotePairing.normalizedCode("ABCDEFGHJU") == nil, "U isn't in the alphabet")
  }

  @Test func linksReadBack() {
    let id = UUID()
    let link = RemotePairingLink(
      addresses: [
        RemoteAddress(host: "vimes.tail1234.ts.net", port: 7863), RemoteAddress(host: "100.100.1.2", port: 7863),
        RemoteAddress(host: "fd7a:115c:a1e0::1", port: 7863),
      ],
      serverID: id, secret: "ABCDE12345")
    #expect(link.text.hasPrefix("atelier-pair://vimes.tail1234.ts.net:7863?id=\(id.uuidString)&s=ABCDE12345&a="))
    #expect(RemotePairingLink(link.text) == link)
  }

  @Test func ipv6HostsAndDefaultPortsParse() throws {
    let id = UUID()
    let v6 = try #require(RemotePairingLink("atelier-pair://[fd7a:115c:a1e0::1]:9000?id=\(id)&s=ABCDE12345"))
    #expect(v6.addresses == [RemoteAddress(host: "fd7a:115c:a1e0::1", port: 9000)])
    #expect(v6.text.contains("[fd7a:115c:a1e0::1]:9000"))
    let bare = try #require(RemotePairingLink("atelier-pair://mac.local?id=\(id)&s=abcde-12345&a=10.0.0.2,10.0.0.3:99"))
    #expect(bare.addresses.map(\.port) == [7863, 7863, 99])
    #expect(bare.secret == "ABCDE12345")
  }

  @Test func badLinksAreRefused() {
    let id = UUID()
    #expect(RemotePairingLink("https://mac.local:1?id=\(id)&s=ABCDE12345") == nil, "scheme")
    #expect(RemotePairingLink("atelier-pair://mac.local?s=ABCDE12345") == nil, "no id")
    #expect(RemotePairingLink("atelier-pair://mac.local?id=nope&s=ABCDE12345") == nil, "bad id")
    #expect(RemotePairingLink("atelier-pair://mac.local?id=\(id)") == nil, "no secret")
    #expect(RemotePairingLink("atelier-pair://mac.local?id=\(id)&s=short") == nil, "bad secret")
    #expect(RemotePairingLink("") == nil)
  }

  @Test func addressesParse() {
    #expect(RemoteAddress("mac.local") == RemoteAddress(host: "mac.local", port: 7863))
    #expect(RemoteAddress("mac.local:99") == RemoteAddress(host: "mac.local", port: 99))
    #expect(RemoteAddress("[::1]:99") == RemoteAddress(host: "::1", port: 99))
    #expect(RemoteAddress("fd7a::1") == RemoteAddress(host: "fd7a::1", port: 7863))
    #expect(RemoteAddress("mac.local:0") == nil)
    #expect(RemoteAddress("mac.local:port") == nil)
    #expect(RemoteAddress("  ") == nil)
    #expect(RemoteAddress("has space") == nil)
  }

  @Test func routesPreferTheLocalNetwork() {
    let addresses = ["100.100.1.2", "vimes.tail1234.ts.net", "192.168.1.5", "vimes.local", "example.com"]
    let ranks = addresses.compactMap { RemoteAddress($0)?.routeRank }
    #expect(ranks == [2, 1, 0, 0, 3])
  }

  @Test func theDeviceKeyCrossesSealed() throws {
    let deviceKey = RemotePairing.newDeviceKey()
    #expect(deviceKey.count == 32)
    let client = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try RemotePairing.seal(deviceKey: deviceKey, clientKey: client.publicKey.rawRepresentation, code: "ABCDE12345")
    #expect(!sealed.sealed.isEmpty && sealed.sealed.range(of: deviceKey) == nil)
    #expect(try RemotePairing.open(sealed: sealed.sealed, serverKey: sealed.publicKey, privateKey: client, code: "ABCDE12345") == deviceKey)
    // The code alone doesn't open it: someone without the client's private key can't.
    let eavesdropper = Curve25519.KeyAgreement.PrivateKey()
    #expect(throws: (any Error).self) {
      try RemotePairing.open(sealed: sealed.sealed, serverKey: sealed.publicKey, privateKey: eavesdropper, code: "ABCDE12345")
    }
  }

  @Test func proofsBindKeyAndDevice() {
    let key = RemotePairing.newDeviceKey()
    let device = UUID()
    let proof = RemotePairing.proof(key: key, deviceID: device, purpose: "hello")
    #expect(RemotePairing.isValidProof(proof, key: key, deviceID: device, purpose: "hello"))
    #expect(!RemotePairing.isValidProof(proof, key: key, deviceID: UUID(), purpose: "hello"))
    #expect(!RemotePairing.isValidProof(proof, key: RemotePairing.newDeviceKey(), deviceID: device, purpose: "hello"))
    #expect(!RemotePairing.isValidProof(proof, key: key, deviceID: device, purpose: "pair"))
  }
}

struct RemoteFilterTests {
  func allowed(_ filter: RemoteAddressFilter, _ address: String) -> Bool { filter.allows(RemoteIP(address)) }

  @Test(arguments: [
    "100.64.0.0", "100.100.100.100", "100.127.255.255", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ffff::1", "::ffff:100.64.0.1",
  ])
  func tailscaleAddresses(_ address: String) {
    #expect(allowed(.tailscale, address))
    #expect(allowed(.tailscaleAndLocal, address))
    #expect(allowed(.any, address))
  }

  @Test(arguments: ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.1.1", "127.0.0.1", "::1", "fe80::1", "fe80::1%en0", "fc00::1", "fd00::1", "fd7a:115c:a1e1::1", "::ffff:192.168.1.1"])
  func localAddresses(_ address: String) {
    #expect(!allowed(.tailscale, address))
    #expect(allowed(.tailscaleAndLocal, address))
    #expect(allowed(.any, address))
  }

  @Test(arguments: ["100.63.255.255", "100.128.0.0", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.167.1.1", "2001:4860:4860::8888", "::ffff:8.8.8.8"])
  func publicAddresses(_ address: String) {
    #expect(!allowed(.tailscale, address))
    #expect(!allowed(.tailscaleAndLocal, address))
    #expect(allowed(.any, address))
  }

  @Test func onlyAnyAllowsWhatIsNotAnAddress() {
    #expect(RemoteIP("mac.local") == nil)
    #expect(!RemoteAddressFilter.tailscale.allows(nil))
    #expect(!RemoteAddressFilter.tailscaleAndLocal.allows(nil))
    #expect(RemoteAddressFilter.any.allows(nil))
  }
}

struct RemoteStoreTests {
  /// The real Keychain, under a service of its own that's removed again.
  @Test func theKeychainKeepsLists() {
    let store = KeychainSecretStore(service: "Atelier Compute Tests \(UUID())")
    let account = RemoteAccounts.servers
    defer { store.save(nil, account: account) }
    #expect(store.load(account) == nil)
    let server = RemoteServerRecord(id: UUID(), name: "Vimes", addresses: [RemoteAddress(host: "100.100.1.2", port: 7863)], key: RemotePairing.newDeviceKey())
    store.saveList([server], account: account)
    #expect(store.loadList(account) == [server])
    var renamed = server
    renamed.name = "Crowley"
    store.saveList([renamed, server], account: account)
    #expect(store.loadList(account) == [renamed, server], "saving again replaces it")
    store.save(nil, account: account)
    #expect(store.load(account) == nil)
  }

  @Test func resultsSurviveTheirFile() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-tests-\(UUID())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    var frame = Tensor<FloatType>(.CPU, .NHWC(1, 2, 2, 3))
    for y in 0..<2 {
      for x in 0..<2 {
        for c in 0..<3 { frame[0, y, x, c] = FloatType(Float(y + x + c) / 8) }
      }
    }
    var audio = Tensor<Float>(.CPU, .NC(2, 4))
    for c in 0..<2 {
      for i in 0..<4 { audio[c, i] = Float(c + i) / 10 }
    }
    let output = GenerationEngine.Output(frames: [frame, frame], audio: audio, audioSampleRate: 44100, framesPerSecond: 24, audioInput: nil)
    let url = folder.appending(path: "job.result")
    let written = try await RemoteResultFile.write(output, to: url)
    let data = try Data(contentsOf: url)
    #expect(written.size == data.count)
    #expect(written.hash == SHA256.hash(data: data).hexString)
    let read = try await RemoteResultFile.read(url)
    #expect(read.frames.count == 2)
    #expect(read.frames[1][0, 1, 1, 2] == frame[0, 1, 1, 2])
    #expect(read.audio?[1, 3] == audio[1, 3])
    #expect(read.audioSampleRate == 44100 && read.framesPerSecond == 24 && read.audioInput == nil)
    try Data("not a result".utf8).write(to: url)
    await #expect(throws: RemoteError.corruptResult) { try await RemoteResultFile.read(url) }
  }

  @Test func uploadsResumeAndAreChecked() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-tests-\(UUID())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RemoteJobStore(root: folder)
    let device = UUID()
    let blob = RemoteBlob(Data(repeating: 7, count: 10))
    let first = blob.data.prefix(4)
    #expect(try await store.appendBlob(device: device, hash: blob.hash, offset: 0, total: 10, bytes: Data(first)) == 4)
    let status = await store.blobStatus(device: device, hashes: [blob.hash])
    #expect(status.partial[blob.hash] == 4 && status.complete.isEmpty)
    // A chunk at the wrong offset isn't written, and the answer says where to go on.
    #expect(try await store.appendBlob(device: device, hash: blob.hash, offset: 8, total: 10, bytes: Data([7, 7])) == 4)
    #expect(try await store.appendBlob(device: device, hash: blob.hash, offset: 4, total: 10, bytes: Data(blob.data.dropFirst(4))) == 10)
    #expect(await store.blobStatus(device: device, hashes: [blob.hash]).complete == [blob.hash])
    #expect(await store.blobURL(device: device, hash: blob.hash) != nil)
    // Another device can't tell this one uploaded it.
    #expect(await store.blobStatus(device: UUID(), hashes: [blob.hash]).complete.isEmpty)
    // Damaged uploads, oversized ones, and names that aren't hashes are refused.
    let other = RemoteBlob(Data([1, 2, 3]))
    await #expect(throws: RemoteError.self) {
      try await store.appendBlob(device: device, hash: other.hash, offset: 0, total: 3, bytes: Data([9, 9, 9]))
    }
    #expect(await store.blobStatus(device: device, hashes: [other.hash]).partial.isEmpty)
    await #expect(throws: RemoteError.self) {
      try await store.appendBlob(device: device, hash: other.hash, offset: 0, total: RemoteProtocol.maxBlobSize + 1, bytes: Data([1]))
    }
    await #expect(throws: RemoteError.self) {
      try await store.appendBlob(device: device, hash: "../../evil", offset: 0, total: 1, bytes: Data([1]))
    }
  }

  @Test func jobsBelongToTheirDevice() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-tests-\(UUID())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RemoteJobStore(root: folder)
    let (mine, theirs, job) = (UUID(), UUID(), UUID())
    #expect(try await store.registerJob(job, device: mine))
    #expect(try await !store.registerJob(job, device: mine), "sending it again leaves the one taken")
    await #expect(throws: RemoteError.self) { try await store.registerJob(job, device: theirs) }
    #expect(await store.latestEvent(of: job, device: mine)?.state == .queued)
    #expect(await store.latestEvent(of: job, device: theirs) == nil)
    #expect(await store.events(device: theirs).isEmpty)
    await store.acknowledge(job: job, device: theirs)
    #expect(await store.events(device: mine).count == 1, "another device's ack does nothing")
    // Previews aren't kept, and a job that ended stays ended.
    await store.post(RemoteJobEvent(jobID: job, state: .generating, step: 1, totalSteps: 2, previews: [Data([1])]))
    #expect(await store.latestEvent(of: job, device: mine)?.previews == nil)
    await store.post(RemoteJobEvent(jobID: job, state: .cancelled))
    await store.post(RemoteJobEvent(jobID: job, state: .generating, step: 2, totalSteps: 2))
    #expect(await store.latestEvent(of: job, device: mine)?.state == .cancelled)
  }

  @Test func oldJobsArePurgedAndUnfinishedOnesFail() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-tests-\(UUID())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    let device = UUID()
    let (old, recent, running) = (UUID(), UUID(), UUID())
    do {
      let store = RemoteJobStore(root: folder)
      for job in [old, recent] {
        _ = try await store.registerJob(job, device: device)
        await store.post(RemoteJobEvent(jobID: job, state: .cancelled))
      }
      _ = try await store.registerJob(running, device: device)
    }
    // Reopened, as after a relaunch: the job that was running can't finish now.
    let store = RemoteJobStore(root: folder)
    #expect(await store.latestEvent(of: running, device: device)?.state == .failed)
    await store.purge(now: Date().addingTimeInterval(RemoteProtocol.retention + 60))
    #expect(await store.events(device: device).isEmpty)
    #expect(RemoteProtocol.retention == 7 * 24 * 60 * 60)
  }
}

struct RemoteClientJobsTests {
  @Test func keptJobsComeBackUntilRemoved() throws {
    try withTestFolder { folder in
      let jobs = RemoteClientJobs(folder: folder)
      #expect(jobs.all().isEmpty)
      let record = RemoteClientJob(
        jobID: UUID(), serverID: UUID(), project: "P", model: "m.ckpt", prompt: "p", negativePrompt: "n", seed: 3,
        settings: ["steps": .number(4)], parentTensorId: 9, hasCanvas: true, canvasTensorId: 8,
        moodboardWeights: [0.5], placement: nil)
      try JSONEncoder().encode(record).write(to: folder.appending(path: "\(record.jobID.uuidString).json"))
      try #require(ImageTensor.png(smallImage())).write(to: folder.appending(path: "\(record.jobID.uuidString)-canvas.png"))
      try #require(ImageTensor.png(smallImage())).write(to: folder.appending(path: "\(record.jobID.uuidString)-moodboard-0.png"))
      #expect(jobs.all() == [record])
      #expect(jobs.canvas(of: record)?.width == 4)
      #expect(jobs.moodboard(of: record).map(\.weight) == [0.5])
      let other = RemoteClientJob(jobID: UUID(), serverID: UUID(), project: "P", model: "m", prompt: "", negativePrompt: "", seed: 0, settings: [:])
      #expect(jobs.canvas(of: other) == nil, "no canvas was sent")
      jobs.remove(record.jobID)
      #expect(jobs.all().isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "its images go too")
    }
  }
}

struct RemoteTraitsTests {
  /// A community model this device's ModelZoo has never heard of, as a server describes it.
  @Test func aClientLearnsAModelsTraitsFromItsServer() throws {
    let file = "check_only_custom_h3_\(UUID().uuidString).ckpt"
    #expect(VideoModel(model: file) == nil, "unknown here, it looks like an image model")
    RemoteModelTraits.remember(
      models: [file: RemoteModelTraits(version: "minimax_h3", modifier: "ref2va", framesPerSecond: 24, audioSampleRate: 48000)],
      loras: [:])
    let video = try #require(VideoModel(model: file))
    #expect(video.framesPerSecond == 24 && video.audioSampleRate == 48000)
    #expect(video.makesAudio && video.takesAudio && video.takesReferences)
  }

  @Test func theZooStillAnswersForModelsItKnows() throws {
    let known = try #require(ModelZoo.availableSpecifications.first?.file)
    let real = RemoteModelTraits.version(of: known)
    RemoteModelTraits.remember(
      models: [known: RemoteModelTraits(version: "minimax_h3", modifier: "ref2va", framesPerSecond: 1, audioSampleRate: 1)],
      loras: [:])
    #expect(RemoteModelTraits.version(of: known) == real)
  }

  @Test func aLoRAsModifierCountsWhenTheModelHasNone() {
    let lora = "check_only_lora_\(UUID().uuidString).ckpt"
    RemoteModelTraits.remember(models: [:], loras: [lora: "kontext"])
    #expect(RemoteModelTraits.modifier(ofLoRA: lora) == .kontext)
    #expect(RemoteModelTraits.modifier(of: "check_only_nothing.ckpt", loras: [lora]) == .kontext)
  }
}

struct RemoteClipTests {
  @Test func aCollectedClipStaysForUpscalingButOtherResultsGo() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-tests-\(UUID())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RemoteJobStore(root: folder)
    let (device, other, clip, image) = (UUID(), UUID(), UUID(), UUID())
    for (job, isClip) in [(clip, true), (image, false)] {
      _ = try await store.registerJob(job, device: device)
      let url = try #require(await store.resultDestination(job))
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data([1, 2, 3]).write(to: url)
      await store.post(RemoteJobEvent(jobID: job, state: .ready, resultSize: 3, resultHash: "x", resultIsClip: isClip))
      await store.acknowledge(job: job, device: device)
    }
    #expect(await store.clip(device: device, job: clip) != nil)
    #expect(await store.clip(device: device, job: image) == nil)
    #expect(await store.clip(device: other, job: clip) == nil, "only for the device it was made for")
    #expect(await store.events(device: device).isEmpty)
    // Kept while used, gone after its time.
    await store.purge(now: Date().addingTimeInterval(RemoteProtocol.retention - 60))
    #expect(await store.clip(device: device, job: clip) != nil)
    await store.purge(now: Date().addingTimeInterval(RemoteProtocol.retention + 60))
    #expect(await store.clip(device: device, job: clip) == nil)
  }

  @Test func clipsAreRememberedByServer() throws {
    try withTestFolder { folder in
      let jobs = RemoteClientJobs(folder: folder.appending(path: "ClientJobs", directoryHint: .isDirectory))
      let (server, job) = (UUID(), UUID())
      #expect(jobs.clip(tensorId: 5, project: "P", server: server) == nil)
      jobs.rememberClip(tensorId: 5, project: "P", server: server, job: job)
      #expect(jobs.clip(tensorId: 5, project: "P", server: server) == job)
      #expect(jobs.clip(tensorId: 5, project: "Q", server: server) == nil)
      #expect(jobs.clip(tensorId: 5, project: "P", server: UUID()) == nil)
    }
  }
}

struct RemoteTailnetTests {
  @Test func bridgesCarryBothWaysAndEnd() {
    // Client ↔ [a b] ↔ server, the way a tailnet socket meets a loopback one.
    var left: [Int32] = [0, 0]
    var right: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &left) == 0)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &right) == 0)
    RemoteSocketBridge.pump(left[1], right[0])
    let big = [UInt8]((0..<(1 << 20)).map { UInt8($0 & 0xFF) })
    func send(_ bytes: [UInt8], to fd: Int32) {
      Thread.detachNewThread {
        var sent = 0
        while sent < bytes.count {
          let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
          guard count > 0 else { return }
          sent += count
        }
      }
    }
    func receive(_ count: Int, from fd: Int32) -> [UInt8] {
      var all: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 65536)
      while all.count < count {
        let got = read(fd, &buffer, min(buffer.count, count - all.count))
        guard got > 0 else { break }
        all += buffer[0..<got]
      }
      return all
    }
    send(big, to: left[0])
    #expect(receive(big.count, from: right[1]) == big)
    send(Array(big.prefix(1000)), to: right[1])
    #expect(receive(1000, from: left[0]) == Array(big.prefix(1000)))
    // One side closing reaches the other.
    close(left[0])
    var byte: UInt8 = 0
    #expect(read(right[1], &byte, 1) == 0)
    close(right[1])
  }

  @Test func loopbackHelpersConnect() throws {
    let listening = try #require(RemoteSocketBridge.listenLoopback())
    #expect(listening.port != 0)
    let client = try #require(RemoteSocketBridge.connectLoopback(port: listening.port))
    defer { close(client) }
    let accepted = try #require(RemoteSocketBridge.acceptOne(listening.fd, timeout: 2000))
    close(accepted)
    let quiet = try #require(RemoteSocketBridge.listenLoopback())
    #expect(RemoteSocketBridge.acceptOne(quiet.fd, timeout: 10) == nil)
  }

  private let statusJSON = Data("""
  {"BackendState":"Running","AuthURL":"","TailscaleIPs":["100.100.1.1"],
   "Self":{"DNSName":"vimes-atelier.tail1234.ts.net.","UserID":1,"TailscaleIPs":["100.100.1.1","fd7a:115c:a1e0::1"]},
   "CurrentTailnet":{"MagicDNSSuffix":"tail1234.ts.net"},
   "Peer":{"a":{"TailscaleIPs":["100.100.1.2","fd7a:115c:a1e0::2"],"UserID":1},"b":{"TailscaleIPs":["100.100.1.3"],"UserID":2}},
   "User":{"1":{"LoginName":"ianiv@github"},"2":{"LoginName":"someone@else"}}}
  """.utf8)

  @Test func statusReadsTheNode() throws {
    let status = try #require(RemoteTailnetStatus(json: statusJSON))
    #expect(status.backendState == "Running" && status.authURL == nil)
    #expect(status.dnsName == "vimes-atelier.tail1234.ts.net")
    #expect(status.login == "ianiv@github")
    #expect(status.peerLogins["100.100.1.3"] == "someone@else")
    let login = try #require(RemoteTailnetStatus(json: Data(#"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/x"}"#.utf8)))
    #expect(login.authURL == "https://login.tailscale.com/a/x")
    #expect(RemoteTailnetStatus(json: Data("nope".utf8)) == nil)
  }

  @Test func theAccountLimitChecksTheCaller() throws {
    let status = try #require(RemoteTailnetStatus(json: statusJSON))
    #expect(status.admits(caller: "100.100.1.2:5000", limitToAccount: true))
    #expect(status.admits(caller: "[fd7a:115c:a1e0::2]:5000", limitToAccount: true))
    #expect(!status.admits(caller: "100.100.1.3:5000", limitToAccount: true), "another account")
    #expect(!status.admits(caller: "100.100.9.9:5000", limitToAccount: true), "nobody it knows")
    #expect(!status.admits(caller: "", limitToAccount: true))
    #expect(status.admits(caller: "100.100.1.3:5000", limitToAccount: false))
    #expect(!RemoteTailnetStatus().admits(caller: "100.100.1.2:5000", limitToAccount: true), "before it knows who it is")
  }

  @Test func tailnetHostsGoThroughTheNode() throws {
    let status = try #require(RemoteTailnetStatus(json: statusJSON))
    #expect(status.isTailnetHost("vimes.tail1234.ts.net"))
    #expect(status.isTailnetHost("100.100.1.2"))
    #expect(status.isTailnetHost("fd7a:115c:a1e0::2"))
    #expect(!status.isTailnetHost("192.168.1.5"))
    #expect(!status.isTailnetHost("vimes.local"))
    var headscale = RemoteTailnetStatus()
    headscale.magicDNSSuffix = "tail.example.com"
    #expect(headscale.isTailnetHost("vimes.tail.example.com"))
    #expect(!headscale.isTailnetHost("tail.example.com.evil.net"))
  }

  @Test(arguments: [
    ("Ianiv’s MacBook Pro", "ianivs-macbook-pro-atelier"), ("Crowley", "crowley-atelier"), ("iPad (2)", "ipad-2-atelier"),
    ("---", "atelier"), ("Café Mac", "caf-mac-atelier"),
  ])
  func hostnamesComeFromTheDeviceName(_ device: String, _ expected: String) {
    #expect(RemoteTailnet.defaultHostname(for: device) == expected)
  }

  @MainActor @Test func settingsDefaults() {
    var options = RemoteTailnet.Options()
    options.persists = false
    options.folder = FileManager.default.temporaryDirectory.appending(path: "atelier-tests-\(UUID())", directoryHint: .isDirectory)
    let tailnet = RemoteTailnet(options: options)
    #expect(tailnet.serves && tailnet.limitsToAccount)
    #expect(tailnet.controlURL.isEmpty && tailnet.hostname.hasSuffix("-atelier"))
    #expect(!tailnet.isSignedIn && tailnet.addresses.isEmpty)
    #expect(tailnet.bridge(to: RemoteAddress(host: "100.100.1.2", port: 7863)) == nil, "not signed in")
  }
}
