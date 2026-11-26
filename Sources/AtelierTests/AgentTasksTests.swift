@testable import Atelier
import Foundation
import Testing

@Suite(.tags(.smoke))
struct AgentTasksTests {
  private static let created = Date(timeIntervalSince1970: 1_800_000_000)

  private static func snapshot(_ state: AgentTasks.State, finishedAfter seconds: TimeInterval? = nil) -> AgentTasks.Snapshot {
    let finished = seconds.map { created.addingTimeInterval($0) }
    return AgentTasks.Snapshot(id: "job-abc", state: state, createdAt: created, updatedAt: finished ?? created.addingTimeInterval(2), finishedAt: finished)
  }

  @Test func statusPerState() {
    #expect(AgentTasks.status(.waiting(message: "Queued")) == "working")
    #expect(AgentTasks.status(.running(message: "Sampling", step: 3, total: 8)) == "working")
    #expect(AgentTasks.status(.done(result: [:])) == "completed")
    #expect(AgentTasks.status(.toolError("No model")) == "completed", "a tool error is a completed task, not failed")
    #expect(AgentTasks.status(.cancelled) == "cancelled")
  }

  @Test func statusMessages() {
    #expect(AgentTasks.statusMessage(.waiting(message: "Waiting for the current run to finish")) == "Waiting for the current run to finish")
    #expect(AgentTasks.statusMessage(.running(message: "Sampling", step: 3, total: 8)) == "Sampling (step 3 of 8)")
    #expect(AgentTasks.statusMessage(.running(message: "Sampling", step: 3, total: nil)) == "Sampling (step 3)")
    #expect(AgentTasks.statusMessage(.running(message: "Loading", step: 0, total: 8)) == "Loading")
    #expect(AgentTasks.statusMessage(.done(result: [:])) == "Done")
    #expect(AgentTasks.statusMessage(.toolError("No model")) == "No model")
    #expect(AgentTasks.statusMessage(.cancelled) == "Cancelled")
  }

  @Test func ttlAndPolling() {
    #expect(AgentTasks.ttlMs(Self.snapshot(.running(message: "x", step: 1, total: 2))) == nil, "unlimited while working")
    #expect(AgentTasks.ttlMs(Self.snapshot(.done(result: [:]), finishedAfter: 90)) == 90_000 + 3_600_000, "an hour after it ended, from creation")
    #expect(AgentTasks.pollIntervalMs(.waiting(message: "x")) == 5000)
    #expect(AgentTasks.pollIntervalMs(.running(message: "x", step: 1, total: nil)) == 2000)
    #expect(AgentTasks.pollIntervalMs(.done(result: [:])) == nil)
    #expect(AgentTasks.pollIntervalMs(.toolError("x")) == nil)
    #expect(AgentTasks.pollIntervalMs(.cancelled) == nil)
  }

  @Test func createShape() {
    let result = AgentTasks.createResult(Self.snapshot(.waiting(message: "Queued")), isRemote: false)
    #expect(result["resultType"] as? String == "task")
    #expect(result["taskId"] as? String == "job-abc")
    #expect(result["status"] as? String == "working")
    #expect(result["ttlMs"] is NSNull)
    #expect(result["pollIntervalMs"] as? Int == 5000)
    #expect(result["createdAt"] as? String == "2027-01-15T08:00:00Z")
    #expect(result["lastUpdatedAt"] as? String == "2027-01-15T08:00:02Z")
    #expect(result["result"] == nil && result["error"] == nil)
    #expect(JSONSerialization.isValidJSONObject(result))
  }

  @Test func detailedCompleted() {
    let toolResult: [String: Any] = ["content": [["type": "text", "text": "ok"]], "structuredContent": ["history_step": 4, "path": "/Users/x/a.png"]]
    let done = AgentTasks.taskJSON(Self.snapshot(.done(result: toolResult), finishedAfter: 10), detailed: true, isRemote: false)
    #expect(done["status"] as? String == "completed")
    #expect(done["pollIntervalMs"] == nil)
    #expect(done["ttlMs"] as? Int == 3_610_000)
    #expect(((done["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["history_step"] as? Int == 4)
    #expect(done["resultType"] == nil, "the envelope says complete")

    let failed = AgentTasks.taskJSON(Self.snapshot(.toolError("No such step"), finishedAfter: 1), detailed: true, isRemote: false)
    #expect(failed["status"] as? String == "completed")
    let result = failed["result"] as? [String: Any]
    #expect(result?["isError"] as? Bool == true)
    #expect(((result?["content"] as? [[String: Any]])?.first)?["text"] as? String == "No such step")
    #expect(failed["error"] == nil, "error is only for JSON-RPC failures")

    let cancelled = AgentTasks.taskJSON(Self.snapshot(.cancelled, finishedAfter: 1), detailed: true, isRemote: false)
    #expect(cancelled["status"] as? String == "cancelled")
    #expect(cancelled["result"] == nil && cancelled["error"] == nil)

    let summary = AgentTasks.taskJSON(Self.snapshot(.done(result: toolResult), finishedAfter: 10), detailed: false, isRemote: false)
    #expect(summary["result"] == nil)
  }

  @Test func remoteReadersGetNoPaths() {
    let home = NSHomeDirectory()
    let toolResult: [String: Any] = ["content": [["type": "text", "text": "ok"]], "structuredContent": ["history_step": 4, "path": "\(home)/a.png"]]
    let done = AgentTasks.taskJSON(Self.snapshot(.done(result: toolResult), finishedAfter: 1), detailed: true, isRemote: true)
    let structured = (done["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
    #expect(structured?["path"] == nil)
    #expect(structured?["history_step"] as? Int == 4)

    let failed = AgentTasks.taskJSON(Self.snapshot(.toolError("Can't read \(home)/x.png"), finishedAfter: 1), detailed: true, isRemote: true)
    #expect(!(failed["statusMessage"] as? String ?? "").contains(home))
    let text = (((failed["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)?["text"] as? String ?? ""
    #expect(!text.contains(home))
  }

  @Test func iso8601() {
    let text = AgentTasks.iso8601(Self.created)
    #expect(text == "2027-01-15T08:00:00Z")
    #expect((try? Date.ISO8601FormatStyle().parse(text)) == Self.created)
  }

  @Test func jobIDs() {
    let ids = (0..<200).map { _ in AgentTasks.newJobID() }
    #expect(Set(ids).count == ids.count)
    for id in ids.prefix(5) {
      #expect(id.hasPrefix("job-"))
      let uuid = UUID(uuidString: String(id.dropFirst(4)))
      #expect(uuid != nil)
      #expect(id == id.lowercased())
      // Version 4: 122 random bits.
      #expect(String(id.dropFirst(4))[String.Index(utf16Offset: 14, in: String(id.dropFirst(4)))] == "4")
    }
  }

  @Test func retention() {
    let now = Date()
    let old = (id: "old", finishedAt: now.addingTimeInterval(-3601))
    let recent = (id: "recent", finishedAt: now.addingTimeInterval(-60))
    #expect(AgentTasks.expired(finished: [old, recent], now: now) == ["old"])
    let many = (0..<105).map { (id: "j\($0)", finishedAt: now.addingTimeInterval(-Double($0))) }
    let dropped = AgentTasks.expired(finished: many, now: now)
    #expect(dropped == Set((100..<105).map { "j\($0)" }), "the oldest past 100 go")
  }
}
