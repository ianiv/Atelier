#if os(macOS)
@preconcurrency import _MediaGenerationKit
import Foundation
import SwiftUI
import Synchronization

extension Automation {
  /// Checks remote generation end to end in this one process, as PASS/FAIL lines: a server on
  /// loopback with the filter on Any, a client pairing with it, a real image through `RemoteBackend`
  /// with a frame coming back, a second job cancelled mid-run, and then resuming a download, one
  /// device not seeing another's job, the network filter, and Remove. Keys stay in memory and files
  /// in a temporary folder, so the user's pairings and results are left alone; nothing is saved to
  /// the project.
  ///
  ///   Atelier --remote-check [--model M] [--steps N] [--quit]
  static func remoteCheck(_ model: CreateModel, library: ModelLibrary) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      let root = FileManager.default.temporaryDirectory.appending(path: "atelier-remote-check-\(UUID())", directoryHint: .isDirectory)
      @MainActor func finish() {
        try? FileManager.default.removeItem(at: root)
        print(failures == 0 ? "remote check: all passed" : "remote check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func wait(until condition: () -> Bool, seconds: Double = 600) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
          if Date() > deadline { return false }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return true
      }

      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      let file = value("--model") ?? "flux_2_klein_9b_kv_q8p.ckpt"
      guard model.models.contains(where: { $0.file == file }) else {
        check(false, "\(file) is downloaded")
        return finish()
      }
      model.selectedModel = file
      _ = await wait(until: { !model.isLoadingModel })
      model.resetToModelDefaults(undoManager: nil)
      guard var settings = model.settings else { return finish() }
      settings.steps = value("--steps").flatMap(Int32.init).map(Int.init) ?? 2
      settings.width = 512
      settings.height = 512
      let currentStep = model.history.currentTensorId

      // The server.
      var options = RemoteServer.Options()
      options.store = MemorySecretStore()
      options.root = root.appending(path: "Server", directoryHint: .isDirectory)
      options.isApp = false
      options.loopbackOnly = true
      options.filter = .any
      options.port = 0
      let server = RemoteServer(create: model, library: library, options: options)
      server.isEnabled = true
      await server.settled()
      check(server.isListening && server.boundPort != 0, "the server listens on loopback (port \(server.boundPort))")

      // Pairing.
      @MainActor func newClient(_ name: String) -> RemoteServerList {
        RemoteServerList(
          store: MemorySecretStore(), downloads: root.appending(path: "Downloads-\(name)", directoryHint: .isDirectory),
          identity: RemoteDeviceIdentity(id: UUID(), name: name))
      }
      @MainActor func pairingError(_ list: RemoteServerList, _ link: RemotePairingLink) async -> RemoteError? {
        do {
          try await list.pair(link: link)
          return nil
        } catch {
          return error as? RemoteError ?? .connectionLost
        }
      }
      let clientIdentity = RemoteDeviceIdentity(id: UUID(), name: "Check Client")
      let clients = RemoteServerList(
        store: MemorySecretStore(), downloads: root.appending(path: "Downloads", directoryHint: .isDirectory),
        identity: clientIdentity)
      server.startPairing()
      await server.settled()
      guard let pairing = server.pairing else {
        check(false, "pairing opens")
        return finish()
      }
      check(RemotePairingLink(pairing.link.text) == pairing.link, "the pairing link reads back")
      var wrong = pairing.link
      wrong.secret = pairing.code.first == "0" ? "1" + pairing.code.dropFirst() : "0" + pairing.code.dropFirst()
      let wrongError = await pairingError(clients, wrong)
      check(wrongError == .wrongCode, "a wrong code is refused (\(String(describing: wrongError)))")
      check(clients.servers.isEmpty && server.devices.isEmpty, "a wrong code pairs nothing")
      try? await Task.sleep(for: .seconds(RemotePairing.attemptSpacing + 0.1))
      let pairError = await pairingError(clients, pairing.link)
      check(pairError == nil && clients.servers.count == 1 && server.devices.count == 1, "the right code pairs (\(String(describing: pairError)))")
      check(server.pairing == nil, "the code is used up")
      guard let record = clients.servers.first else { return finish() }
      await server.settled()
      let reused = newClient("Reused Code")
      let reuseError = await pairingError(reused, pairing.link)
      check(reuseError == .pairingClosed, "the code doesn't work twice (\(String(describing: reuseError)))")
      check(record.key == server.devices.first?.key, "both sides hold the same device key")

      // What the server has.
      let backend = clients.backend(for: record.id)
      let served = await backend.downloadedModels()
      check(served.contains { $0.file == file }, "the catalog lists \(file) (\(served.count) models)")
      do {
        let defaults = try await backend.loadPipeline(for: file)
        check(defaults.width > 0, "the model's defaults come from the server (\(defaults.width)×\(defaults.height))")
      } catch {
        check(false, "the model's defaults come from the server: \(error.localizedDescription)")
      }
      do {
        let blank = try await RemoteBackend.blankConfiguration(for: "no_such_model_here.ckpt")
        check(blank.width > 0, "a model only the server knows still gets a configuration")
      } catch {
        check(false, "a model only the server knows still gets a configuration: \(error.localizedDescription)")
      }

      // An image through the backend.
      @MainActor func request(prompt: String, steps: Int) -> GenerationEngine.Request {
        var configuration = settings
        configuration.steps = steps
        return GenerationEngine.Request(
          model: file, prompt: prompt, negativePrompt: "", seed: 42, configuration: configuration)
      }
      let events = ProgressRecorder()
      do {
        let output = try await backend.generate(request(prompt: "a red apple on a table", steps: settings.steps)) { events.note($0) }
        let image = output.frames.first.flatMap(ImageTensor.cgImage(from:))
        check(output.frames.count == 1 && image?.width == 512 && image?.height == 512, "a frame comes back (\(image?.width ?? 0)×\(image?.height ?? 0))")
      } catch {
        check(false, "a frame comes back: \(error.localizedDescription)")
      }
      let seen = events.summary
      check(seen.steps > 0, "progress arrives through the same callbacks (\(seen.steps) steps, \(seen.previews) previews, \(seen.downloads) download updates)")
      check(seen.downloads > 0, "the download reports its progress")
      let ran = model.queue.recent.first
      check(ran?.remoteDevice == "Check Client" && ran?.status == .ranForDevice, "the job ran in this machine's queue, labelled with the device")
      check(model.history.currentTensorId == currentStep, "the result isn't saved to this machine's project")
      let leftover = await server.store.events(device: clientIdentity.id)
      check(leftover.isEmpty, "the acknowledged result is deleted from the server")

      // Cancelling mid-run.
      let started = ProgressRecorder()
      let cancelled = Task { try await backend.generate(request(prompt: "a long run", steps: 30)) { started.note($0) } }
      let reachedStep = await wait(until: { started.summary.steps >= 1 })
      check(reachedStep, "the second job is running")
      cancelled.cancel()
      switch await cancelled.result {
      case .success: check(false, "cancelling stops the job")
      case .failure(let error): check(error is CancellationError, "the client's cancel ends its call (\(error))")
      }
      let stopped = await wait(until: { model.queue.running == nil && model.queue.isEmpty }, seconds: 120)
      check(stopped && model.queue.recent.first?.status == .cancelled, "the server's queue stops the job")

      // Resuming a download, and another device's view of it.
      let other = newClient("Other Client")
      server.startPairing()
      await server.settled()
      if let second = server.pairing {
        try? await Task.sleep(for: .seconds(RemotePairing.attemptSpacing + 0.1))
        let error = await pairingError(other, second.link)
        check(error == nil, "a second device pairs (\(String(describing: error)))")
      }
      await server.settled()
      if let otherRecord = other.servers.first, let client = backend.client,
         let otherClient = other.backend(for: otherRecord.id).client
      {
        do {
          let job = UUID()
          let updates = await client.startUpdates(job: job)
          try await backend.submit(request(prompt: "a blue pear", steps: settings.steps), job: job) { _ in }
          let ready = try await backend.waitForResult(job: job, updates: updates) { _ in }
          await client.endUpdates(job: job)
          let size = ready.resultSize ?? 0
          let hash = ready.resultHash ?? ""
          _ = try await client.download(job: job, size: size, hash: hash, chunkLength: 4096, stopAfter: 2) { _ in }
          let partial = await client.downloadedSize(job: job)
          check(partial == min(size, 8192), "a download can stop partway (\(partial) of \(size) bytes)")
          await client.disconnect()
          let offsets = OffsetRecorder()
          let url = try await client.download(job: job, size: size, hash: hash, chunkLength: 1 << 16) { offsets.note($0) }
          check(url != nil && (offsets.first ?? 0) > partial, "it resumes after a reconnect and checks out (\(offsets.first ?? 0) after the first chunk)")

          // The other device, knowing the job's id, gets nothing.
          let peek = try? await otherClient.request(.subscribe(jobID: job))
          let list = try? await otherClient.request(.listJobs)
          var isEmptyList = false
          if case .jobs(let jobs) = list { isEmptyList = jobs.isEmpty }
          check(peek == nil && isEmptyList, "another device can't see this device's job")
          let stolen = try? await otherClient.download(job: job, size: size, hash: hash) { _ in }
          check(stolen == nil, "another device can't download its result")

          _ = try await client.request(.ackResult(jobID: job))
          await client.removeDownload(job: job)
        } catch {
          check(false, "resuming a download: \(error.localizedDescription)")
        }
      } else {
        check(false, "the second device has a backend")
      }

      // The network filter.
      if let client = backend.client {
        server.filter = .tailscale
        await client.disconnect()
        let refused = try? await client.request(.catalogRequest)
        check(refused == nil, "Tailscale only turns away a loopback connection")
        server.filter = .any
        let allowed = try? await client.request(.catalogRequest)
        check(allowed != nil, "Any network lets it back in")

        // Remove.
        if let device = server.devices.first(where: { $0.id == clientIdentity.id }) {
          server.remove(device.id)
          await server.settled()
          var error: Error?
          for _ in 0..<40 where error == nil {
            do {
              _ = try await client.request(.catalogRequest)
              try? await Task.sleep(for: .milliseconds(50))
            } catch let thrown {
              error = thrown
            }
          }
          // The drop arrives first; the next connection is the one the server turns down.
          if case .connectionLost = error as? RemoteError {
            do {
              _ = try await client.request(.catalogRequest)
              error = nil
            } catch let thrown {
              error = thrown
            }
          }
          check((error as? RemoteError) == .notPaired(server: record.name), "Remove closes the device's connection and refuses its key (\(String(describing: error)))")
        }
      }

      server.isEnabled = false
      await server.settled()
      finish()
    }
  }
}

/// What a job's progress callback saw.
private final nonisolated class ProgressRecorder: Sendable {
  struct Summary: Sendable {
    var steps = 0
    var previews = 0
    var downloads = 0
  }

  private let state = Mutex(Summary())
  var summary: Summary { state.withLock { $0 } }

  func note(_ progress: GenerationEngine.Progress) {
    state.withLock { summary in
      switch progress {
      case .state(.generating(let step, _)): summary.steps = max(summary.steps, step)
      case .state(.downloading): summary.downloads += 1
      case .preview(_, let step, _), .previewFrames(_, let step, _):
        summary.previews += 1
        summary.steps = max(summary.steps, step)
      default: break
      }
    }
  }
}

private final nonisolated class OffsetRecorder: Sendable {
  private let state = Mutex<Int?>(nil)
  var first: Int? { state.withLock { $0 } }

  func note(_ offset: Int) { state.withLock { $0 = $0 ?? offset } }
}
#endif
