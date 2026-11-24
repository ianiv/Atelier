@testable import Atelier
import Foundation
import Testing

/// The queue's own bookkeeping (`JobQueue`), nothing run: every job names its project, lines and
/// reused canvas inputs stay within a project, a rename relabels what's listed, `jobs(in:)` is a
/// project's jobs, a deleted project's jobs name it no more, and Run Again keeps the project.
/// A request needs a configuration, which only MGK makes: a model's recommended one from its
/// catalog entry (`RemoteBackend.blankConfiguration`), read without loading any weights.
@MainActor
@Suite(.tags(.smoke))
struct JobQueueTests {
  func request() async throws -> GenerationEngine.Request {
    let configuration = try await RemoteBackend.blankConfiguration(for: "job-queue-tests.ckpt")
    return GenerationEngine.Request(model: "m.ckpt", prompt: "p", negativePrompt: "", seed: 1, configuration: configuration)
  }

  @Test func everyJobNamesItsProjectAndLinesStayInOne() async throws {
    let request = try await request()
    let queue = JobQueue()
    let a = queue.append([request, request], currentTensorId: 5, project: "A")
    let b = queue.append([request], currentTensorId: 5, project: "B")
    #expect(queue.waiting.map(\.project) == ["A", "A", "B"])
    let lines = queue.waiting.map(\.line)
    #expect(lines[0] != nil && lines[0] == lines[1] && lines[2] != lines[0], "a line doesn't continue into another project")
    #expect(queue.jobs(in: "A").map(\.id) == a && queue.jobs(in: "B").map(\.id) == b)
    // A's first saves while another project is open: A's next still follows it.
    let first = try #require(queue.startNext())
    queue.finishRunning(.finished(tensorId: 77), id: first.id, inOpenProject: false)
    let second = try #require(queue.startNext())
    #expect(second.request?.parentTensorId == 77)
    queue.finishRunning(.cancelled, id: second.id)
    let third = try #require(queue.startNext())
    #expect(third.request?.parentTensorId == 5 && third.project == "B", "B's line follows B's step")
  }

  @Test func jobsNamingTheirStepLeaveTheLinesAlone() async throws {
    var request = try await request()
    let queue = JobQueue()
    queue.append([request], currentTensorId: 5, project: "A")
    request.parentTensorId = 40
    queue.append([request], currentTensorId: 99, project: "B")
    request.parentTensorId = nil
    queue.append([request], currentTensorId: 5, project: "A")
    #expect(queue.waiting[0].line == queue.waiting[2].line && queue.waiting[1].line == nil)
  }

  @Test func canvasInputsAreReusedOnlyInTheirProject() async throws {
    var request = try await request()
    request.canvas = smallImage()
    request.canvasKey = "canvas"
    let queue = JobQueue()
    queue.append([request], currentTensorId: 1, project: "A")
    queue.append([request], currentTensorId: 1, project: "B")
    queue.append([request], currentTensorId: 1, project: "A")
    let inA = try #require(queue.startNext())
    queue.finishRunning(.finished(tensorId: 90), id: inA.id, inputTensorId: 88)
    let inB = try #require(queue.startNext())
    #expect(inB.request?.canvasTensorId == nil)
    // Renamed, the project keeps its inputs.
    queue.renameProject(from: "A", to: "A2")
    queue.finishRunning(.cancelled, id: inB.id)
    let again = try #require(queue.startNext())
    #expect(again.request?.canvasTensorId == 88)
  }

  @Test func aRenameRelabelsEveryListedJob() async throws {
    var request = try await request()
    request.placement = TimelinePlacement(project: "A", timeline: UUID(), entry: UUID(), frame: 0, frameTensorId: 1)
    request.referenceVideo = ReferenceVideo(sourceTensorId: 3, project: "A")
    let queue = JobQueue()
    queue.append([request, request, request], currentTensorId: nil, project: "A")
    let done = try #require(queue.startNext())
    queue.finishRunning(.cancelled, id: done.id)
    let running = try #require(queue.startNext())
    queue.renameProject(from: "A", to: "A2")
    for job in [queue.running, queue.waiting.first, queue.recent.first].compactMap(\.self) {
      #expect(job.project == "A2" && job.request?.placement?.project == "A2" && job.request?.referenceVideo?.project == "A2")
    }
    #expect(queue.projectName(of: running.id) == "A2" && queue.jobs(in: "A").isEmpty && queue.jobs(in: "A2").count == 2)
  }

  @Test func runAgainKeepsTheProjectUnlessItWasDeleted() async throws {
    let request = try await request()
    let queue = JobQueue()
    queue.append([request], currentTensorId: nil, project: "A")
    let job = try #require(queue.startNext())
    queue.finishRunning(.cancelled, id: job.id)
    queue.retry(job.id)
    #expect(queue.waiting.last?.project == "A" && queue.waiting.last?.detached == false)
    _ = queue.removeAllWaiting()
    queue.forgetProject("A")
    #expect(queue.recent.allSatisfy { $0.project == nil && $0.projectDeleted })
    let count = queue.waiting.count
    queue.retry(job.id)
    #expect(queue.waiting.count == count, "a deleted project's job isn't run again")
  }

  @Test func noProjectForDevicesAndNoneForAProjectBeingDeleted() async throws {
    let request = try await request()
    let queue = JobQueue()
    let device = queue.append(request, remoteDevice: "Device")
    #expect(queue.waiting.first { $0.id == device }?.project == nil)
    queue.acceptsProject = { $0 != "Doomed" }
    #expect(queue.append([request], currentTensorId: nil, project: "Doomed").isEmpty)
    #expect(queue.jobs(in: "Doomed").isEmpty)
  }
}
