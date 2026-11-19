import Foundation

extension CreateModel {
  /// Runs an Edit job on this device: renders the step with its look (`EditPipeline`) and saves
  /// the result as a new step after it, recording `Edit.Record`, as `run(_:request:job:)` does
  /// for Match Colors to Original. A stub that fails the job until Slice H fills it.
  func runEdit(_ edit: Edit.Job, request _: GenerationEngine.Request, job: JobQueue.Job) {
    beginRun(job, message: "Rendering…", totalSteps: 1_000)
    finish(job, status: .failed("Saving edits isn't available yet."), inOpenProject: edit.project == history.project.name)
  }
}
