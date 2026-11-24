import Foundation

/// What Delete Project's confirmation says about the project's jobs (`CreateModel.jobs(in:)`):
/// deleting it cancels them, since each reads from and saves into that project alone. Pure, so
/// the wording is tested without the dialog.
nonisolated enum ProjectDeletion {
  /// The sentence about `running` (here or on a server) and `waiting` jobs for `project`; nil
  /// when there are none.
  static func jobsMessage(project: String, running: Int, waiting: Int) -> String? {
    let total = running + waiting
    guard total > 0 else { return nil }
    func jobs(_ count: Int) -> String { count == 1 ? "1 job" : "\(count) jobs" }
    func verb(_ count: Int, _ state: String) -> String { count == 1 ? "is \(state)" : "are \(state)" }
    let them = total == 1 ? "it" : "them"
    let state: String
    switch (running, waiting) {
    case (0, _): state = "\(jobs(waiting)) for “\(project)” \(verb(waiting, "waiting"))"
    case (_, 0): state = "\(jobs(running)) for “\(project)” \(verb(running, "running"))"
    default: state = "\(jobs(running)) for “\(project)” \(verb(running, "running")) and \(waiting) \(verb(waiting, "waiting"))"
    }
    return "\(state). Deleting the project cancels \(them)."
  }

  /// The destructive button's title: it says the jobs go too when there are any. The dialog
  /// always has the same two buttons, this and Cancel.
  static func confirmTitle(jobCount: Int) -> String {
    jobCount > 0 ? "Cancel Jobs and Delete" : "Delete Project"
  }
}
