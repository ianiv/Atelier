#if os(macOS)
import Foundation

/// The Tasks extension (`io.modelcontextprotocol/tasks`, 2026-07-28): a job tool called by a
/// client that declares it answers with a task handle, and the client polls `tasks/get` for the
/// result. Every task is an agent job (`AgentTools.Job`, task id == job id), so get_job,
/// list_jobs, cancel_job and the Queue see the same run. Kept pure here so the tests can pin the
/// shapes; `AgentTools` builds a `Snapshot` from a job and `AgentServer` answers the methods.
///
/// Not implemented, both optional in the spec: `input_required` (no tool asks for input mid-run)
/// and `subscriptions/listen` / `notifications/tasks` (clients poll at `pollIntervalMs`).
nonisolated enum AgentTasks {
  static let extensionID = "io.modelcontextprotocol/tasks"
  /// Missing Required Client Capability: a tasks/* request from a client that didn't declare
  /// the extension on that request (Tasks: Protocol Errors).
  static let missingCapability = -32021
  static var missingCapabilityData: [String: Any] {
    ["requiredCapabilities": ["extensions": [extensionID: [String: Any]()]]]
  }

  /// How long a finished task stays readable: as long as a finished job always has.
  static let retention: TimeInterval = 3600
  /// Finished jobs kept at most, whatever their age: their results hold inline images.
  static let finishedLimit = 100

  /// A job as a task sees it, taken on the main actor under the reader's `ToolContext`.
  enum State {
    case waiting(message: String)
    case running(message: String, step: Int, total: Int?)
    /// The tool's CallToolResult, as the call itself would have answered.
    case done(result: [String: Any])
    /// The job failed: the call would have answered with this text and `isError`, so the task
    /// is `completed` with that result (`failed` is only for JSON-RPC errors).
    case toolError(String)
    case cancelled
  }

  struct Snapshot {
    var id: String
    var state: State
    var createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?
  }

  /// An opaque, unguessable id (Tasks: Security Considerations): a version 4 UUID's 122 random
  /// bits. Job ids are task ids, so every job gets one, task or not.
  static func newJobID() -> String {
    "job-" + UUID().uuidString.lowercased()
  }

  static func status(_ state: State) -> String {
    switch state {
    case .waiting, .running: "working"
    case .done, .toolError: "completed"
    case .cancelled: "cancelled"
    }
  }

  static func statusMessage(_ state: State) -> String {
    switch state {
    case .waiting(let message): message
    case .running(let message, let step, let total):
      step <= 0 ? message : total.map { "\(message) (step \(step) of \($0))" } ?? "\(message) (step \(step))"
    case .done: "Done"
    case .toolError(let message): message
    case .cancelled: "Cancelled"
    }
  }

  /// From creation, so it grows with the run: unlimited while working (a queued video can
  /// outlast any fixed figure, and a running job is never dropped), then until an hour after it
  /// ended. Nil is JSON null.
  static func ttlMs(_ snapshot: Snapshot) -> Int? {
    guard let finishedAt = snapshot.finishedAt else { return nil }
    return max(0, Int((finishedAt.timeIntervalSince(snapshot.createdAt) * 1000).rounded())) + Int(retention * 1000)
  }

  /// Slower while waiting behind other runs, faster once it runs; none once it's over.
  static func pollIntervalMs(_ state: State) -> Int? {
    switch state {
    case .waiting: 5000
    case .running: 2000
    case .done, .toolError, .cancelled: nil
    }
  }

  /// ISO 8601 in UTC to the second ("2026-07-28T10:30:00Z").
  static func iso8601(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle())
  }

  /// The Task: `detailed` adds what tasks/get carries for a finished one (`result`). A reader
  /// on another device gets no file paths, whoever started the job.
  static func taskJSON(_ snapshot: Snapshot, detailed: Bool, isRemote: Bool) -> [String: Any] {
    let redact: (String) -> String = { isRemote ? AgentPathGuard.redactingPaths($0) : $0 }
    var task: [String: Any] = [
      "taskId": snapshot.id,
      "status": status(snapshot.state),
      "statusMessage": redact(statusMessage(snapshot.state)),
      "createdAt": iso8601(snapshot.createdAt),
      "lastUpdatedAt": iso8601(snapshot.updatedAt),
      "ttlMs": ttlMs(snapshot) ?? NSNull(),
    ]
    if let poll = pollIntervalMs(snapshot.state) { task["pollIntervalMs"] = poll }
    guard detailed else { return task }
    switch snapshot.state {
    case .done(let result):
      task["result"] = isRemote ? AgentPathGuard.strippingPaths(result) : result
    case .toolError(let message):
      task["result"] = ["content": [["type": "text", "text": redact(message)]], "isError": true] as [String: Any]
    case .waiting, .running, .cancelled:
      break
    }
    return task
  }

  /// CreateTaskResult: the Task flat in the result, discriminated by `resultType` (which
  /// `AgentProtocol.envelope` keeps).
  static func createResult(_ snapshot: Snapshot, isRemote: Bool) -> [String: Any] {
    var result = taskJSON(snapshot, detailed: false, isRemote: isRemote)
    result["resultType"] = "task"
    return result
  }

  /// Which finished jobs to drop: any finished over `retention` ago, then the oldest past
  /// `finishedLimit`. Running and waiting jobs are never dropped.
  static func expired(finished: [(id: String, finishedAt: Date)], now: Date = Date()) -> Set<String> {
    let newestFirst = finished.sorted { $0.finishedAt > $1.finishedAt }
    var drop = Set<String>()
    for (index, job) in newestFirst.enumerated() where index >= finishedLimit || now.timeIntervalSince(job.finishedAt) > retention {
      drop.insert(job.id)
    }
    return drop
  }
}
#endif
