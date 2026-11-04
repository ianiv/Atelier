import Observation

/// Suspends until `condition`, which reads `@Observable` state, is true or the task is cancelled:
/// the state's changes wake it, so nothing polls. Check the condition again after a cancellation.
@MainActor
func waitUntil(_ condition: @escaping @MainActor @Sendable () -> Bool) async {
  for await met in Observations(condition) where met { return }
}
