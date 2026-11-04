#if os(macOS)
@preconcurrency import _MediaGenerationKit
import Foundation
import Network
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
  /// Then Create's Run on: a real result through the queue into the project (`--project`), Stop,
  /// collecting a job sent before a quit, a job the server lost, and a server going offline.
  ///
  ///   Atelier --remote-check --project NAME [--model M] [--steps N] [--quit]
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

      // Create's Run on. Its server has a queue of its own: this queue holds its slot while a
      // remote job runs, so it can't also be the queue running it.
      let host = CreateModel(history: HistoryStore())
      let hostReady = await wait(until: { !host.models.isEmpty && !host.isBusy }, seconds: 120)
      check(hostReady, "a second engine is ready to be the server")
      var hostOptions = RemoteServer.Options()
      hostOptions.store = MemorySecretStore()
      hostOptions.root = root.appending(path: "Host", directoryHint: .isDirectory)
      hostOptions.isApp = false
      hostOptions.loopbackOnly = true
      hostOptions.filter = .any
      hostOptions.port = 0
      let hostServer = RemoteServer(create: host, library: library, options: hostOptions)
      hostServer.isEnabled = true
      await hostServer.settled()
      hostServer.startPairing()
      await hostServer.settled()
      model.clientJobs = RemoteClientJobs(folder: root.appending(path: "ClientJobs", directoryHint: .isDirectory))
      guard let hostLink = hostServer.pairing?.link else { return finish() }
      let hostPairError = await pairingError(model.remoteServers, hostLink)
      guard hostPairError == nil, let hostRecord = model.remoteServers.servers.first else {
        check(false, "Create's device pairs (\(String(describing: hostPairError)))")
        return finish()
      }
      let target = JobTarget.remote(serverID: hostRecord.id)
      let deviceID = RemoteDeviceIdentity.current.id

      model.runTarget = target
      let onServer = await wait(until: { model.serverCatalog != nil && !model.isLoadingModel }, seconds: 120)
      check(onServer && model.availableModels.contains { $0.file == file }, "Run on loads the server's models (\(model.availableModels.count))")
      check(model.selectedModel == file && model.settings != nil, "the selected model stays, with settings from the server")
      check(model.runTargetProblem == nil, "Generate has no problem with the server")

      model.settings?.steps = settings.steps
      model.settings?.width = 512
      model.settings?.height = 512
      model.count = 1
      model.seedLocked = false
      model.prompt = "a green apple on a table, from a server"
      let parentStep = model.history.currentTensorId
      model.generate()
      check(model.queue.running?.target == target || model.queue.waiting.first?.target == target, "a job takes Run on's target")
      let ranRemotely = await wait(until: { model.queue.isEmpty })
      guard ranRemotely, let remoteJob = model.queue.recent.first else {
        check(false, "the job finishes")
        return finish()
      }
      if case .finished(let tensorId) = remoteJob.status, let item = model.history.item(tensorId: tensorId) {
        check(item.sidecar.model == file, "the result is in this project's history, as \(file)")
        check(model.history.currentTensorId == tensorId, "it's the current step")
        check(model.history.parent(of: item)?.tensorId == parentStep, "after the same step a local run would follow (\(String(describing: parentStep)))")
      } else {
        check(false, "the result is in this project's history: \(remoteJob.status)")
      }
      check(model.clientJobs.all().isEmpty, "the kept job is gone once saved")
      let afterSave = await hostServer.store.events(device: deviceID)
      check(afterSave.isEmpty, "the server's copy goes once it's saved")
      check(host.queue.recent.first?.remoteDevice != nil, "the job ran in the server's queue")

      // Stop.
      model.settings?.steps = 30
      model.prompt = "stopped from the queue"
      model.generate()
      let stepping = await wait(until: { model.step >= 1 && model.queue.running != nil })
      check(stepping, "a long job runs")
      model.cancel()
      let clientStopped = await wait(until: { model.queue.isEmpty }, seconds: 120)
      check(clientStopped && model.queue.recent.first?.status == .cancelled, "Stop ends the job here")
      let hostStopped = await wait(until: { host.queue.isEmpty && host.queue.recent.first?.status == .cancelled }, seconds: 120)
      check(hostStopped, "Stop cancels on the server")
      check(model.clientJobs.all().isEmpty, "nothing's kept for a stopped job")
      model.settings?.steps = settings.steps

      // Coming back after a quit: a job sent earlier, still running at the server. Pause holds new
      // work, not this.
      guard let remainingSettings = model.settings else { return finish() }
      let left = UUID()
      var leftRequest = GenerationEngine.Request(
        model: file, prompt: "sent before a quit", negativePrompt: "", seed: 7, configuration: remainingSettings)
      leftRequest.parentTensorId = model.history.currentTensorId
      let hostBackend = model.remoteServers.backend(for: hostRecord.id)
      await model.clientJobs.add(leftRequest, job: left, server: hostRecord.id, project: model.history.project.name)
      do {
        try await hostBackend.submit(leftRequest, job: left) { _ in }
      } catch {
        check(false, "submitting a job to come back to: \(error.localizedDescription)")
      }
      model.queue.isPaused = true
      await model.recoverRemoteJobs()
      let recovered = await wait(until: { model.queue.isEmpty })
      model.queue.isPaused = false
      if recovered, let job = model.queue.recent.first, job.id == left, case .finished(let tensorId) = job.status {
        check(model.history.item(tensorId: tensorId)?.sidecar.prompt == "sent before a quit", "a job from before a quit is collected into the project")
      } else {
        check(false, "a job from before a quit is collected: \(String(describing: model.queue.recent.first?.status))")
      }
      check(model.clientJobs.all().isEmpty, "and is no longer kept")

      // One the server lost.
      let lost = UUID()
      await model.clientJobs.add(leftRequest, job: lost, server: hostRecord.id, project: model.history.project.name)
      await model.recoverRemoteJobs()
      _ = await wait(until: { model.queue.isEmpty })
      if case .failed(let message) = model.queue.recent.first?.status {
        check(message.contains("no longer has"), "a job the server lost shows as failed (\(message))")
      } else {
        check(false, "a job the server lost shows as failed: \(String(describing: model.queue.recent.first?.status))")
      }
      model.errorMessage = nil
      check(model.clientJobs.all().isEmpty, "and is no longer kept")

      // Offline: Generate holds, and a kept job waits for the server rather than failing.
      hostServer.isEnabled = false
      await hostServer.settled()
      await model.remoteServers.backend(for: hostRecord.id).client?.disconnect()
      await model.remoteServers.checkStatus()
      check(model.remoteServers.status(of: hostRecord.id) == .offline, "a server that's gone shows as offline")
      check(!model.canGenerate && model.runTargetProblem != nil, "Generate waits (\(model.runTargetProblem ?? ""))")
      let waitingJob = UUID()
      await model.clientJobs.add(leftRequest, job: waitingJob, server: hostRecord.id, project: model.history.project.name)
      await model.recoverRemoteJobs()
      check(model.queue.isEmpty && model.clientJobs.all().count == 1, "a kept job waits for its offline server")
      model.clientJobs.remove(waitingJob)

      // Back here.
      model.runTarget = .local
      let backHere = await wait(until: { !model.isLoadingModel }, seconds: 60)
      check(backHere && model.serverCatalog == nil && model.availableModels.count == model.models.count, "This Mac brings back the local models")
      model.remoteServers.remove(hostRecord.id)
      finish()
    }
  }

  /// A real network check on this one Mac: a server on all interfaces with the filter on Tailscale
  /// only, and a client coming in over this Mac's own Tailscale address. Keys stay in memory.
  ///
  ///   Atelier --remote-net-check [--model M] [--quit]
  static func remoteNetCheck(_ model: CreateModel, library: ModelLibrary) {
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
      let root = FileManager.default.temporaryDirectory.appending(path: "atelier-remote-net-\(UUID())", directoryHint: .isDirectory)
      @MainActor func finish() {
        try? FileManager.default.removeItem(at: root)
        print(failures == 0 ? "remote net check: all passed" : "remote net check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      let interfaces = RemoteNetworkInfo.interfaces()
      print("interfaces: \(interfaces.map { "\($0.name)=\($0.address)" }.joined(separator: ", "))")
      let tailscale = RemoteNetworkInfo.tailscaleAddress(in: interfaces)
      let local = interfaces.first(where: { if case .v4 = $0.ip { !$0.ip.isTailscale && $0.ip.isLocalNetwork } else { false } })?.address
      if tailscale == nil { print("NOTE this Mac has no Tailscale address; using the local network instead") }
      guard let address = tailscale ?? local else {
        print("SKIP this Mac has neither a Tailscale nor a local network address")
        return finish()
      }
      var options = RemoteServer.Options()
      options.store = MemorySecretStore()
      options.root = root
      options.isApp = false
      options.loopbackOnly = false
      options.filter = tailscale == nil ? .tailscaleAndLocal : .tailscale
      options.port = 0
      let server = RemoteServer(create: model, library: library, options: options)
      await server.refreshNetworkInfo()
      print("connecting over \(address), Tailscale name \(server.tailscaleName ?? "(none found)")")
      server.isEnabled = true
      await server.settled()
      check(server.isListening, "listening on all interfaces, port \(server.boundPort) (\(server.listenError ?? "no error"))")
      let advertised = await Self.browsedServices(seconds: 4)
      check(!advertised.isEmpty, "Bonjour shows \(RemoteProtocol.serviceType) (\(advertised.joined(separator: ", ")))")
      server.startPairing()
      await server.settled()
      guard let link = server.pairing?.link else { return finish() }
      print("link: \(link.addresses.map(\.description).joined(separator: " "))")
      let clients = RemoteServerList(
        store: MemorySecretStore(), downloads: root.appending(path: "Downloads", directoryHint: .isDirectory),
        identity: RemoteDeviceIdentity(id: UUID(), name: "Net Check Client"))
      let started = Date()
      do {
        try await clients.pair(link: link)
        check(true, "paired through the link's routes in \(Int(Date().timeIntervalSince(started)))s")
      } catch {
        check(false, "pairing: \(error.localizedDescription)")
        return finish()
      }
      guard let record = clients.servers.first else { return finish() }
      await server.settled()

      // Only the Tailscale route: the others are what the filter turns away.
      let tailnetOnly = RemoteServerRecord(
        id: record.id, name: record.name, addresses: [RemoteAddress(host: address, port: server.boundPort)], key: record.key)
      let identity = RemoteDeviceIdentity(id: server.devices[0].id, name: "Net Check Client")
      let tailnet = RemoteBackend(client: RemoteClient(server: tailnetOnly, device: identity, downloads: root.appending(path: "Downloads", directoryHint: .isDirectory)))
      let reached = await tailnet.client?.isReachable() ?? false
      check(reached, "a connection over \(address) gets through")
      if let lan = local {
        let lanOnly = RemoteServerRecord(id: record.id, name: record.name, addresses: [RemoteAddress(host: lan, port: server.boundPort)], key: record.key)
        let lanClient = RemoteClient(server: lanOnly, device: identity, downloads: root)
        let filter = server.filter
        server.filter = .tailscale
        let reachedLAN = await lanClient.isReachable()
        check(!reachedLAN, "with Tailscale only, a connection over the local network (\(lan)) is turned away")
        server.filter = filter
      }
      let file = value("--model") ?? "flux_2_klein_9b_kv_q8p.ckpt"
      if model.models.contains(where: { $0.file == file }) {
        model.selectedModel = file
        while model.isLoadingModel { try? await Task.sleep(for: .milliseconds(100)) }
        model.resetToModelDefaults(undoManager: nil)
        if var settings = model.settings {
          settings.steps = 2
          settings.width = 512
          settings.height = 512
          let request = GenerationEngine.Request(model: file, prompt: "a red apple", negativePrompt: "", seed: 1, configuration: settings)
          do {
            let output = try await tailnet.generate(request) { _ in }
            check(output.frames.first.flatMap(ImageTensor.cgImage(from:))?.width == 512, "a real image comes back over \(address)")
          } catch {
            check(false, "an image over \(address): \(error.localizedDescription)")
          }
        }
      }
      server.isEnabled = false
      await server.settled()
      finish()
    }
  }

  /// The names advertising the Compute service nearby, after browsing for a while.
  private static func browsedServices(seconds: Double) async -> [String] {
    let browser = NWBrowser(for: .bonjour(type: RemoteProtocol.serviceType, domain: nil), using: .tcp)
    let found = Mutex<[String]>([])
    browser.browseResultsChangedHandler = { results, _ in
      let names = results.compactMap { result -> String? in
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
      }
      found.withLock { $0 = names }
    }
    browser.start(queue: .global())
    try? await Task.sleep(for: .seconds(seconds))
    browser.cancel()
    return found.withLock { $0 }
  }

  /// Waits for an `atelier-pair://` link opened from outside, as a scanned QR code does: it should
  /// ask to pair, in the window already up.
  ///
  ///   Atelier --remote-url-check [--quit]   (then: open -a build/Atelier.app 'atelier-pair://…')
  static func remoteURLCheck(_ model: CreateModel) {
    Task { @MainActor in
      var waited = 0
      while AutomationWindows.windowCount == 0, waited < 300 {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
      }
      let before = AutomationWindows.windowCount
      print("ready, \(before) window(s)")
      fflush(stdout)
      waited = 0
      while model.remoteServers.openedLink == nil, waited < 400 {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
      }
      try? await Task.sleep(for: .seconds(1))
      let link = model.remoteServers.openedLink
      print("\(link != nil ? "PASS" : "FAIL") the link opens the pairing sheet (\(link?.addresses.first?.description ?? "no link"))")
      print("\(AutomationWindows.windowCount == before ? "PASS" : "FAIL") in the window already up (\(AutomationWindows.windowCount) window(s))")
      model.remoteServers.openedLink = nil
      fflush(stdout)
      try? await Task.sleep(for: .seconds(1))
      if CommandLine.arguments.contains("--quit") { AppLifecycle.quit() }
    }
  }

  /// Screenshots of the Compute UI, into DIR. Launch with `-AtelierSettingsTab Compute
  /// -AtelierShowPairing YES` for Settings and its pairing sheet. Nothing's kept: keys stay in
  /// memory, and jobs run against a second engine in this process.
  ///
  ///   Atelier --remote-shots DIR --project NAME -AtelierSettingsTab Compute -AtelierShowPairing YES [--quit]
  static func remoteShots(_ model: CreateModel, navigation: Navigation, library: ModelLibrary) {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--remote-shots"), index + 1 < args.count, let server = remoteServer else { return }
    let folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    Task { @MainActor in
      @MainActor func wait(until condition: () -> Bool, seconds: Double = 300) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
      }
      @MainActor func shot(_ name: String) { AutomationWindows.snapshot(to: folder.appending(path: name)) }
      await wait(until: { model.history.isLoaded && !model.models.isEmpty && model.settings != nil && !model.isBusy })

      // A second engine to be the server, and one server that's gone.
      let host = CreateModel(history: HistoryStore())
      await wait(until: { !host.models.isEmpty && !host.isBusy }, seconds: 120)
      var options = RemoteServer.Options()
      options.store = MemorySecretStore()
      options.root = FileManager.default.temporaryDirectory.appending(path: "atelier-remote-shots-\(UUID())", directoryHint: .isDirectory)
      let hostServer = RemoteServer(create: host, library: library, options: options)
      hostServer.isEnabled = true
      await hostServer.settled()
      hostServer.startPairing()
      await hostServer.settled()
      if let link = hostServer.pairing?.link { try? await model.remoteServers.pair(link: link) }
      let gone = RemoteServerRecord(
        id: UUID(), name: "Crowley", addresses: [RemoteAddress(host: "192.0.2.1", port: 7863)], key: RemotePairing.newDeviceKey())
      model.remoteServers.addForCheck(gone)
      await model.remoteServers.checkStatus()

      // Create, on the server.
      navigation.section = .create
      if let record = model.remoteServers.servers.first(where: { $0.id != gone.id }) {
        model.runTarget = .remote(serverID: record.id)
      }
      await wait(until: { model.serverCatalog != nil && !model.isLoadingModel })
      model.prompt = "a green apple on a table"
      try? await Task.sleep(for: .seconds(1))
      shot("create-run-on.png")
      // The window's number, for `screencapture -l`, which shows what the window really looks like.
      print("main window: \(AutomationWindows.mainWindowNumber)")
      fflush(stdout)
      try? await Task.sleep(for: .seconds(6))

      // A link opened from outside.
      model.remoteServers.openedLink = RemotePairingLink(
        addresses: [RemoteAddress(host: "vimes.tail1234.ts.net", port: 7863)], serverID: UUID(), secret: RemotePairing.newCode())
      try? await Task.sleep(for: .seconds(1))
      _ = AutomationWindows.snapshotSheet(to: folder.appending(path: "add-server-from-link.png"))
      model.remoteServers.openedLink = nil
      try? await Task.sleep(for: .seconds(1))

      // The Queue, with a job on the server.
      if let file = model.availableModels.first(where: { $0.file == "flux_2_klein_9b_kv_q8p.ckpt" })?.file {
        model.selectedModel = file
        await wait(until: { !model.isLoadingModel })
      }
      model.settings?.steps = 2
      model.settings?.width = 512
      model.settings?.height = 512
      model.count = 1
      model.generate()
      navigation.section = .queue
      await wait(until: { model.step >= 1 || model.queue.isEmpty })
      try? await Task.sleep(for: .milliseconds(300))
      shot("queue-running.png")
      await wait(until: { model.transfer != nil || model.queue.isEmpty }, seconds: 120)
      shot("queue-transfer.png")
      await wait(until: { model.queue.isEmpty })
      try? await Task.sleep(for: .seconds(1))
      shot("queue-finished.png")

      // Settings ▸ Compute.
      server.isEnabled = true
      await server.settled()
      await server.refreshNetworkInfo()
      server.startPairing()
      await server.settled()
      if let link = server.pairing?.link {
        let other = RemoteServerList(
          store: MemorySecretStore(), downloads: options.root,
          identity: RemoteDeviceIdentity(id: UUID(), name: "Crowley"))
        try? await other.pair(link: link)
      }
      await server.settled()
      openSettingsWindow?()
      try? await Task.sleep(for: .seconds(2))
      let settingsShown = AutomationWindows.snapshotOtherWindow(to: folder.appending(path: "settings-compute.png"))
      print("settings shot: \(settingsShown)")
      try? await Task.sleep(for: .seconds(2))
      let sheetShown = AutomationWindows.snapshotSheet(to: folder.appending(path: "pair-a-device.png"))
      print("pairing sheet shot: \(sheetShown)")
      fflush(stdout)
      hostServer.isEnabled = false
      server.isEnabled = false
      await hostServer.settled()
      await server.settled()
      if args.contains("--quit") { AppLifecycle.quit() }
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
