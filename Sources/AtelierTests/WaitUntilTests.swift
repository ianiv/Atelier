@testable import Atelier
import Observation
import Testing

@MainActor @Observable private final class Flag {
  var isSet = false
}

@MainActor struct WaitUntilTests {
  @Test func aConditionAlreadyTrueReturnsAtOnce() async {
    await waitUntil { true }
  }

  @Test func aChangeWakesIt() async {
    let flag = Flag()
    let waiter = Task { await waitUntil { flag.isSet } }
    await Task.yield()
    flag.isSet = true
    await waiter.value
    #expect(flag.isSet)
  }

  @Test func aChangeThatLeavesItFalseKeepsWaiting() async throws {
    let flag = Flag()
    let other = Flag()
    let waiter = Task {
      await waitUntil { flag.isSet && other.isSet }
      return flag.isSet && other.isSet
    }
    flag.isSet = true
    try await Task.sleep(for: .milliseconds(50))
    other.isSet = true
    #expect(await waiter.value)
  }

  @Test(.timeLimit(.minutes(1))) func cancellingEndsTheWait() async {
    let flag = Flag()
    let waiter = Task { await waitUntil { flag.isSet } }
    await Task.yield()
    waiter.cancel()
    await waiter.value
    #expect(!flag.isSet)
  }
}
