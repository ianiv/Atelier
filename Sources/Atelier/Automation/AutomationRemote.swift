#if os(macOS)
@preconcurrency import _MediaGenerationKit
import AVFoundation
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
  /// Then Create's Run on: a real result through the queue into the project, Stop, a local job
  /// running alongside a remote one, collecting a job sent before a quit, a job the server lost, a
  /// video with references and audio, upscaling and exporting on the server, a server going
  /// offline, and a device paired with itself. A project named remote-check… is deleted afterwards.
  ///
  ///   Atelier --remote-check --project remote-check-NAME [--model M] [--steps N]
  ///           [--video-model M] [--quit]
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
        removeScratchFiles()
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

      // Results get saved, so never into the project you were working in.
      guard value("--project") != nil else {
        check(false, "--project NAME is given")
        return finish()
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
      check(model.queue.runningRemote.first?.target == target, "a job takes Run on's target, and starts at once")
      check(model.queue.running == nil, "without taking this device's slot")
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
      let stepping = await wait(until: { model.step >= 1 && !model.queue.runningRemote.isEmpty })
      check(stepping, "a long job runs")
      model.cancel()
      let clientStopped = await wait(until: { model.queue.isEmpty }, seconds: 120)
      check(clientStopped && model.queue.recent.first?.status == .cancelled, "Stop ends the job here")
      let hostStopped = await wait(until: { host.queue.isEmpty && host.queue.recent.first?.status == .cancelled }, seconds: 120)
      check(hostStopped, "Stop cancels on the server")
      check(model.clientJobs.all().isEmpty, "nothing's kept for a stopped job")
      model.settings?.steps = settings.steps

      // Alongside: a job on the server doesn't hold up one on this device, however long it takes.
      // It's held there, waiting its turn, so this doesn't depend on which finishes first.
      if let current = model.settings {
        host.setQueuePaused(true)
        model.prompt = "a job held at the server"
        model.generate()
        let remoteRunning = await wait(until: { !model.queue.runningRemote.isEmpty && !host.queue.waiting.isEmpty }, seconds: 60)
        check(remoteRunning, "a job waits at the server")
        var quick = current
        quick.steps = settings.steps
        model.queueForCheck(
          GenerationEngine.Request(model: file, prompt: "a quick local job", negativePrompt: "", seed: 3, configuration: quick),
          target: .local)
        check(model.queue.running != nil && !model.queue.runningRemote.isEmpty, "a job on this device runs alongside it")
        let quickDone = await wait(until: { model.queue.running == nil })
        check(quickDone && !model.queue.runningRemote.isEmpty, "and finishes while the server's job goes on")
        check(model.isRunning, "the status bar goes back to the server's job")
        if let running = model.queue.runningRemote.first { model.cancel(running.id) }
        let bothDone = await wait(until: { model.queue.isEmpty && host.queue.isEmpty }, seconds: 120)
        check(bothDone, "cancelling it takes it out of the server's queue too")
        host.setQueuePaused(false)
        model.settings?.steps = settings.steps
      }

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

      // Video, on the shortest and smallest the model takes, with a reference image and audio.
      let blobFolder = hostOptions.root.appending(path: "Blobs/\(deviceID.uuidString)", directoryHint: .isDirectory)
      func uploads() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: blobFolder.path).count) ?? 0 }
      let videoFile = value("--video-model") ?? model.availableModels.first { $0.file.hasPrefix("fasth3_omni_") }?.file
        ?? model.availableModels.first { VideoModel(model: $0.file)?.makesAudio == true }?.file
      var clipItem: HistoryItem?
      if let videoFile, let video = VideoModel(model: videoFile) {
        model.selectedModel = videoFile
        _ = await wait(until: { !model.isLoadingModel }, seconds: 120)
        print("video model: \(videoFile), \(video.minimumFrames) frames")
        fflush(stdout)
        let served = try? await hostBackend.catalog().models.first { $0.file == videoFile }
        check(served?.traits == RemoteModelTraits(file: videoFile), "the catalog sends the model's traits")
        if var configuration = model.settings {
          configuration.numFrames = video.minimumFrames
          configuration.width = 256
          configuration.height = 256
          configuration.steps = 2
          var request = GenerationEngine.Request(
            model: videoFile, prompt: "a small red ball rolling", negativePrompt: "", seed: 11, configuration: configuration)
          request.parentTensorId = model.history.currentTensorId
          if video.takesReferences || model.usesReferences { request.moodboard = [GenerationEngine.Reference(image: Self.checkImage(), weight: 1)] }
          if video.takesAudio {
            let audio = AudioClip.newSnapshotFile(extension: "wav")
            try? Self.checkAudio().write(to: audio)
            request.audio = audio
          }
          let before = uploads()
          model.queueForCheck(request, target: target)
          _ = await wait(until: { model.queue.isEmpty }, seconds: 1800)
          if case .finished(let tensorId) = model.queue.recent.first?.status, let item = model.history.item(tensorId: tensorId) {
            clipItem = item
            check(item.clip?.frames.count == video.minimumFrames, "a video comes back with its frames (\(item.clip?.frames.count ?? 0))")
            check(item.clip?.framesPerSecond == video.framesPerSecond, "and its frame rate (\(item.clip?.framesPerSecond ?? 0))")
            if video.makesAudio {
              let sound = await model.history.audio(of: item)
              check(sound != nil, "and its soundtrack")
            }
            check((request.moodboard.isEmpty && request.audio == nil) || uploads() > before, "its references and audio went up by hash (\(uploads() - before) uploads)")
          } else {
            check(false, "a video comes back: \(String(describing: model.queue.recent.first?.status))")
          }
        }
      } else {
        print("SKIP no video model here")
      }

      // Upscaling that clip on the server, without sending its frames, then with.
      let upscalers = model.runTargetUpscalers?.upscalers ?? RemoteUpscalers()
      @MainActor func upscaleOnServer(
        _ item: HistoryItem, method: ClipUpscale.Method, scale: Int = 2, variant: FlashVSRFiles.Variant,
        weights: ReCaVSRFiles.Weights = .full, label: String
      ) async {
        let framesBefore = item.clip?.frames.count ?? 0
        await model.upscale(item, method: method, scale: scale, variant: variant, weights: weights)
        check(model.queue.runningRemote.first?.target == target, "\(label) runs on the server")
        _ = await wait(until: { model.queue.isEmpty }, seconds: 1800)
        if case .finished(let tensorId) = model.queue.recent.first?.status, let result = model.history.item(tensorId: tensorId) {
          check(result.clip?.frames.count == framesBefore && result.sidecar.width > item.sidecar.width, "\(label) makes a larger clip (\(result.sidecar.width)×\(result.sidecar.height), \(result.clip?.frames.count ?? 0) frames)")
        } else {
          check(false, "\(label): \(String(describing: model.queue.recent.first?.status))")
        }
      }
      if let clipItem {
        if let flashVariant = upscalers.flashVSR.first {
          let before = uploads()
          await upscaleOnServer(clipItem, method: .flashVSR, variant: flashVariant, label: "FlashVSR+ \(flashVariant.title)")
          check(uploads() == before, "the server's own copy of the clip saves sending its frames")
        } else {
          print("SKIP the server has no FlashVSR+")
        }
        if let weights = upscalers.recaVSR?.last {
          await upscaleOnServer(clipItem, method: .recaVSR, variant: .turbo, weights: weights, label: "ReCaVSR \(weights.title)")
        } else {
          print("SKIP the server has no ReCaVSR")
        }
        // The scales Apple's model offers depend on the size.
        let fastScale = SystemSuperResolution.scaleFactors(width: clipItem.sidecar.width, height: clipItem.sidecar.height).first
        if upscalers.superResolution, let fastScale {
          // Without that copy, the frames go up.
          try? FileManager.default.removeItem(at: hostOptions.root.appending(path: "Clips", directoryHint: .isDirectory))
          let before = uploads()
          await upscaleOnServer(clipItem, method: .system, scale: fastScale, variant: .turbo, label: "Fast (\(fastScale)×)")
          check(uploads() > before, "without it, the clip's frames go up (\(uploads() - before))")
        } else {
          print("SKIP the server has no Apple Super Resolution")
        }

        // Export: only the upscaling runs there.
        if let method = upscalers.superResolution && fastScale != nil ? ClipUpscale.Method.system : upscalers.flashVSR.isEmpty ? nil : .flashVSR,
           let composition = try? await TimelineComposition.make(clip: clipItem, history: model.history)
        {
          let upscale = TimelineUpscale(method: method, scale: method == .system ? fastScale ?? 2 : 2, variant: upscalers.flashVSR.first ?? .turbo)
          let url = root.appending(path: "export.mp4")
          try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          model.queue(TimelineExportJob(composition: composition, upscale: upscale, title: "Check", destination: url))
          check(model.queue.runningRemote.first?.export != nil, "an upscaled export runs on the server")
          _ = await wait(until: { model.queue.isEmpty }, seconds: 1800)
          if case .exported = model.queue.recent.first?.status,
             let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
             let size = try? await track.load(.naturalSize)
          {
            let expected = upscale.outputSize(width: composition.width, height: composition.height)
            check(Int(size.width) == expected.width && Int(size.height) == expected.height, "the export is encoded here at the upscaled size (\(Int(size.width))×\(Int(size.height)))")
          } else {
            check(false, "the export: \(String(describing: model.queue.recent.first?.status))")
          }
        }
      }
      model.selectedModel = file
      _ = await wait(until: { !model.isLoadingModel }, seconds: 120)
      model.errorMessage = nil

      // The server's styles.
      let serverStyles = StyleStore(persists: false)
      let serverStyle = Style(name: "Check Style", category: "Checks", template: "{{SUBJECT}}, in the style of {{ARTIST:nobody}}", negative: "blurry")
      serverStyles.save(serverStyle)
      serverStyles.setThumbnail(Self.checkImage(), for: serverStyle.id, source: ThumbnailSource(prompt: "p", negativePrompt: "", model: "no_such_model.ckpt", seed: 1, settings: [:]))
      host.styles = serverStyles
      let localStylesBefore = model.styles?.styles ?? []
      model.remoteStyles.remove(server: hostRecord.id)
      await model.refreshRemoteStyles(server: hostRecord.id)
      let fetched = model.remoteStyles.styles(of: hostRecord.id).first { $0.id == serverStyle.id }
      check(fetched?.style.template == serverStyle.template, "a server's styles come over")
      check(fetched?.libraryName == serverStyles.currentLibrary.name, "they say which library they're in")
      check(model.styles?.styles == localStylesBefore, "and don't touch this device's own")
      if let fetched {
        let thumbnail = await model.remoteStyles.thumbnail(of: fetched, server: hostRecord.id, backend: hostBackend)
        check(thumbnail != nil, "its thumbnail comes by hash (\(fetched.thumbnailHash?.prefix(8) ?? "none"))")
        let again = await model.remoteStyles.thumbnail(of: fetched, server: hostRecord.id, backend: RemoteBackend(client: nil))
        check(again != nil, "and is kept, with no server needed")
        model.styleID = fetched.id
        model.prompt = "a fox"
        check(model.style?.id == fetched.id, "one can be used like a local one")
        check(model.styledPrompts.prompt == "a fox, in the style of nobody" && model.styledPrompts.negativePrompt.contains("blurry"), "and writes the prompt (\(model.styledPrompts.prompt))")
        // A scripted run keeps thumbnails in memory, without what they were made with, so this one's
        // model is set here.
        var missing = fetched
        missing.thumbnailModel = "no_such_model.ckpt"
        check(model.remoteStyleProblem(missing) != nil, "a thumbnail whose model isn't there can't open (\(model.remoteStyleProblem(missing) ?? ""))")
        missing.thumbnailModel = file
        check(model.remoteStyleProblem(missing) == nil, "one whose model is there can")
        let copy = await model.copyRemoteStyle(fetched, server: hostRecord.id)
        check(copy != nil && copy?.id != fetched.id && model.styles?.style(id: copy?.id) != nil, "copying keeps it here, under a new id")
        if let copy { model.styles?.delete([copy.id]) }
        model.styleID = nil
      }

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
      await model.refreshRemoteStyles(server: hostRecord.id)
      check(model.remoteStyles.styles(of: hostRecord.id).contains { $0.id == serverStyle.id }, "an offline server's styles stay")
      model.clientJobs.remove(waitingJob)

      // Back here.
      model.runTarget = .local
      let backHere = await wait(until: { !model.isLoadingModel }, seconds: 60)
      check(backHere && model.serverCatalog == nil && model.availableModels.count == model.models.count, "This Mac brings back the local models")
      model.remoteServers.remove(hostRecord.id)
      model.remoteStyles.remove(server: hostRecord.id)

      // A device paired with itself: its own server's job can't wait on its own remote job.
      server.isEnabled = true
      await server.settled()
      server.startPairing()
      await server.settled()
      try? await Task.sleep(for: .seconds(RemotePairing.attemptSpacing + 0.1))
      var selfPairError: RemoteError? = .connectionLost
      if let selfLink = server.pairing?.link { selfPairError = await pairingError(model.remoteServers, selfLink) }
      if selfPairError == nil, let selfRecord = model.remoteServers.servers.first {
        model.runTarget = .remote(serverID: selfRecord.id)
        _ = await wait(until: { model.serverCatalog != nil && !model.isLoadingModel }, seconds: 60)
        model.settings?.steps = settings.steps
        model.settings?.width = 512
        model.settings?.height = 512
        model.prompt = "paired with itself"
        model.generate()
        let selfDone = await wait(until: { model.queue.isEmpty }, seconds: 600)
        let jobs = model.queue.recent.prefix(2)
        check(selfDone && jobs.contains { if case .finished = $0.status { true } else { false } } && jobs.contains { $0.status == .ranForDevice }, "a device paired with itself runs its own job")
        model.runTarget = .local
        model.remoteServers.remove(selfRecord.id)
      } else {
        check(false, "a device pairs with itself (\(String(describing: selfPairError)))")
      }
      server.isEnabled = false
      await server.settled()
      finish()
    }
  }

  /// A small image for a job's inputs.
  private static func checkImage() -> CGImage {
    let context = CGContext(
      data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 40, y: 40, width: 176, height: 176))
    return context.makeImage()!
  }

  /// A second of a tone, as a WAV file.
  private static func checkAudio() -> Data {
    let rate = 44100
    let samples = (0..<rate).map { Int16(sin(Double($0) * 2 * .pi * 440 / Double(rate)) * 8000) }
    func bytes<T>(_ value: T) -> Data { withUnsafeBytes(of: value) { Data($0) } }
    var data = Data("RIFF".utf8)
    data += bytes(UInt32(36 + samples.count * 2).littleEndian) + Data("WAVEfmt ".utf8)
    data += bytes(UInt32(16).littleEndian) + bytes(UInt16(1).littleEndian) + bytes(UInt16(1).littleEndian)
    data += bytes(UInt32(rate).littleEndian) + bytes(UInt32(rate * 2).littleEndian)
    data += bytes(UInt16(2).littleEndian) + bytes(UInt16(16).littleEndian)
    data += Data("data".utf8) + bytes(UInt32(samples.count * 2).littleEndian)
    for sample in samples { data += bytes(sample.littleEndian) }
    return data
  }

  /// What a check leaves behind: a scratch project (only one named for these checks, so a mistyped
  /// `--project` can't take a real one) and the temporary Compute folder.
  private static func removeScratchFiles() {
    try? FileManager.default.removeItem(at: RemotePaths.root)
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--project"), index + 1 < args.count, args[index + 1].hasPrefix("remote-check") else { return }
    let project = HistoryStore.projectsDirectory.appendingPathComponent(args[index + 1]).appendingPathExtension("sqlite3")
    for suffix in ["", "-shm", "-wal"] {
      try? FileManager.default.removeItem(atPath: project.path + suffix)
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
      // Nearby. The record names the port only once it's known, after the first listener.
      clients.startBrowsing()
      for _ in 0..<100 where !clients.unpairedNearby.contains(where: { $0.id == server.serverID }) {
        try? await Task.sleep(for: .milliseconds(100))
      }
      let found = clients.unpairedNearby.first { $0.id == server.serverID }
      check(found != nil, "an unpaired server shows under Add Server (\(found?.address.description ?? "not found"))")
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
      for _ in 0..<100 where clients.status(of: record.id) != .online || !clients.nearby.contains(where: { $0.id == record.id }) {
        try? await Task.sleep(for: .milliseconds(100))
      }
      check(clients.unpairedNearby.allSatisfy { $0.id != record.id } && clients.status(of: record.id) == .online, "once paired, it shows as online")
      if local != nil {
        let client = clients.backend(for: record.id).client
        try? await Task.sleep(for: .milliseconds(200))
        let route = await client?.firstRoute
        check(route?.routeRank == 0, "and the local network is its first route (\(route?.description ?? "none"))")
        if tailscale == nil {
          let reachable = await client?.isReachable() ?? false
          check(reachable, "which works")
        }
      }
      clients.stopBrowsing()

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

  /// Real tailnet connections on this one Mac, with no real sign-in: Tailscale's test control server
  /// stands in for theirs, and two nodes in this process play server and client. Pairing and a real
  /// image go through the embedded nodes, then the account limit. Needs
  /// `Scripts/build-tailscale.sh --with-test-control`.
  ///
  ///   Atelier --remote-tailnet-check [--model M] [--quit]
  static func remoteTailnetCheck(_ model: CreateModel, library: ModelLibrary) {
    let args = CommandLine.arguments
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      let root = FileManager.default.temporaryDirectory.appending(path: "atelier-remote-tailnet-\(UUID())", directoryHint: .isDirectory)
      @MainActor func finish() {
        try? FileManager.default.removeItem(at: root)
        removeScratchFiles()
        print(failures == 0 ? "remote tailnet check: all passed" : "remote tailnet check: \(failures) failed")
        fflush(stdout)
        // Go's runtime and the nodes' threads don't wind down for a normal quit.
        exit(failures == 0 ? 0 : 1)
      }
      @MainActor func wait(until condition: () -> Bool, seconds: Double = 120) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
          if Date() > deadline { return false }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return true
      }
      if RemoteTailnet().state == .unavailable {
        check(false, "this build has TailscaleKit (run Scripts/build-tailscale.sh and build again)")
        return finish()
      }
      guard let controlURL = Self.startTestControl() else {
        check(false, "the test control server starts (run Scripts/build-tailscale.sh --with-test-control)")
        return finish()
      }
      print("control: \(controlURL)")
      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }

      @MainActor func tailnet(_ name: String) -> RemoteTailnet {
        var options = RemoteTailnet.Options()
        options.folder = root.appending(path: name, directoryHint: .isDirectory)
        options.persists = false
        options.controlURL = controlURL
        options.hostname = name
        return RemoteTailnet(options: options)
      }
      let serverNode = tailnet("check-server")
      let clientNode = tailnet("check-client")
      serverNode.signIn()
      clientNode.signIn()
      let up = await wait(until: { serverNode.isSignedIn && clientNode.isSignedIn })
      check(up, "both nodes join the tailnet (\(serverNode.state), \(clientNode.state))")
      guard up else { return finish() }
      print("server \(serverNode.status.login ?? "?") at \(serverNode.addresses); client \(clientNode.status.login ?? "?") at \(clientNode.addresses)")

      // A server that only takes the tailnet's connections: Tailscale only, and nothing but loopback
      // to arrive on otherwise, which that filter turns away.
      var options = RemoteServer.Options()
      options.store = MemorySecretStore()
      options.root = root.appending(path: "Server", directoryHint: .isDirectory)
      options.isApp = false
      options.loopbackOnly = true
      options.filter = .tailscale
      options.port = 0
      options.tailnet = serverNode
      serverNode.limitsToAccount = false
      let server = RemoteServer(create: model, library: library, options: options)
      server.isEnabled = true
      await server.settled()
      server.startPairing()
      await server.settled()
      guard let link = server.pairing?.link else {
        check(false, "pairing opens")
        return finish()
      }
      print("link: \(link.addresses.map(\.description).joined(separator: " "))")
      check(link.addresses.first.map { RemoteIP($0.host)?.isTailscale == true || $0.host.hasSuffix(".ts.net") || !$0.host.hasPrefix("127.") } ?? false, "the pairing link starts with the tailnet address")

      // Wait for the two nodes to see each other.
      for _ in 0..<100 where clientNode.status.peerLogins.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
      check(!clientNode.status.peerLogins.isEmpty, "the client's node sees the server's")

      let clients = RemoteServerList(
        store: MemorySecretStore(), downloads: root.appending(path: "Downloads", directoryHint: .isDirectory),
        identity: RemoteDeviceIdentity(id: UUID(), name: "Tailnet Client"))
      clients.router = { [clientNode] in clientNode.bridge(to: $0) }
      // The link's addresses without the loopback one, which the filter refuses anyway.
      var tailnetLink = link
      tailnetLink.addresses = link.addresses.filter { !$0.host.hasPrefix("127.") }
      do {
        try await clients.pair(link: tailnetLink)
        check(clients.servers.count == 1, "pairing works over the tailnet, TLS-PSK inside it")
      } catch {
        check(false, "pairing over the tailnet: \(error.localizedDescription)")
        return finish()
      }
      guard let record = clients.servers.first else { return finish() }
      await server.settled()
      let backend = clients.backend(for: record.id)
      let reachable = await backend.client?.isReachable() ?? false
      check(reachable, "a paired device connects over it, past the Tailscale only filter")

      let file = args.firstIndex(of: "--model").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "flux_2_klein_9b_kv_q8p.ckpt"
      model.selectedModel = file
      _ = await wait(until: { !model.isLoadingModel })
      model.resetToModelDefaults(undoManager: nil)
      if var settings = model.settings {
        settings.steps = 2
        settings.width = 512
        settings.height = 512
        do {
          let output = try await backend.generate(
            GenerationEngine.Request(model: file, prompt: "a red apple", negativePrompt: "", seed: 1, configuration: settings)
          ) { _ in }
          check(output.frames.first.flatMap(ImageTensor.cgImage(from:))?.width == 512, "a real image comes back over it")
        } catch {
          check(false, "an image over the tailnet: \(error.localizedDescription)")
        }
      }

      // The account limit, as far as the test server's users allow.
      let clientAddress = clientNode.status.addresses.first ?? ""
      let sameUser = serverNode.status.peerLogins[clientAddress] == serverNode.status.login
      print("users: server \(serverNode.status.login ?? "?"), client \(serverNode.status.peerLogins[clientAddress] ?? "unknown")")
      await backend.client?.disconnect()
      serverNode.limitsToAccount = true
      let allowed = await backend.client?.isReachable() ?? false
      if sameUser {
        check(allowed, "the same account gets through the limit")
      } else {
        check(!allowed, "another account is turned away by the limit")
        await backend.client?.disconnect()
        serverNode.limitsToAccount = false
        let allowedAgain = await backend.client?.isReachable() ?? false
        check(allowedAgain, "and gets through with the limit off")
      }

      // Signing out stops the route.
      await backend.client?.disconnect()
      await clientNode.signOut()
      let afterSignOut = await backend.client?.isReachable() ?? false
      check(!afterSignOut && clientNode.state == .signedOut, "signing out ends it")
      finish()
    }
  }

  /// Starts Tailscale's test control server, from the library the build script can make; its address.
  private static func startTestControl() -> String? {
    let library = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appending(path: "build/Tailscale/libtstestcontrol.dylib")
    guard let handle = dlopen(library.path, RTLD_NOW) else {
      print("couldn't load \(library.path): \(String(cString: dlerror()))")
      return nil
    }
    guard let symbol = dlsym(handle, "RunControl") else { return nil }
    typealias Run = @convention(c) (UnsafeMutablePointer<CChar>, Int) -> Int32
    var buffer = [CChar](repeating: 0, count: 1024)
    guard unsafeBitCast(symbol, to: Run.self)(&buffer, buffer.count) == 0 else { return nil }
    let url = String(cString: buffer)
    return url.isEmpty ? nil : url
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

  /// Screenshots of the Compute UI, into DIR. Each also prints `capture NAME WINDOW` and holds for
  /// a moment, for `screencapture -l WINDOW`, which shows materials the renders here can't. Launch with `-AtelierSettingsTab Compute
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
      @MainActor func capture(_ name: String, window: Int) async {
        print("capture \(name) \(window)")
        fflush(stdout)
        try? await Task.sleep(for: .seconds(2))
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
      await capture("create-window", window: AutomationWindows.mainWindowNumber)

      // A link opened from outside.
      model.remoteServers.openedLink = RemotePairingLink(
        addresses: [RemoteAddress(host: "vimes.tail1234.ts.net", port: 7863)], serverID: UUID(), secret: RemotePairing.newCode())
      try? await Task.sleep(for: .seconds(1))
      _ = AutomationWindows.snapshotSheet(to: folder.appending(path: "add-server-from-link.png"))
      await capture("add-server-window", window: AutomationWindows.sheetWindowNumber)
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
      await capture("queue-window", window: AutomationWindows.mainWindowNumber)

      // The Styles screen, on the server's styles. The picker's choice is a real setting, so it's
      // put back afterwards.
      if let record = model.remoteServers.servers.first(where: { $0.id != gone.id }) {
        let hostStyles = StyleStore(persists: false)
        for (name, category) in [("Oil Painting", "Painting"), ("Watercolor", "Painting"), ("Film Noir", "Photo")] {
          let style = Style(name: name, category: category, template: "{{SUBJECT}}, in the manner of \(name), {{MOOD:quiet}}", negative: "blurry")
          hostStyles.save(style)
          hostStyles.setThumbnail(Self.checkImage(), for: style.id)
        }
        host.styles = hostStyles
        let saved = UserDefaults.standard.string(forKey: "stylesSource")
        await model.refreshRemoteStyles(server: record.id)
        UserDefaults.standard.set(record.id.uuidString, forKey: "stylesSource")
        navigation.section = .styles
        try? await Task.sleep(for: .seconds(2))
        shot("styles-server.png")
        await capture("styles-server-window", window: AutomationWindows.mainWindowNumber)
        UserDefaults.standard.set(saved, forKey: "stylesSource")
        navigation.section = .create
      }

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
      if !AutomationWindows.isSheetUp { await capture("settings-window", window: AutomationWindows.otherWindowNumber) }
      try? await Task.sleep(for: .seconds(2))
      let sheetShown = AutomationWindows.snapshotSheet(to: folder.appending(path: "pair-a-device.png"))
      print("pairing sheet shot: \(sheetShown)")
      await capture("pair-a-device-window", window: AutomationWindows.sheetWindowNumber)
      fflush(stdout)
      hostServer.isEnabled = false
      server.isEnabled = false
      await hostServer.settled()
      await server.settled()
      removeScratchFiles()
      // The pairing sheet left open would hold up a normal quit.
      exit(0)
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
