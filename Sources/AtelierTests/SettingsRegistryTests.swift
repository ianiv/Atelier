@testable import Atelier
import Testing

/// What the registry does to values however they arrive (typed, presets, saved steps and images,
/// agents): they all go through a descriptor's `set`.
@MainActor @Suite(.tags(.smoke))
struct SettingsRegistryTests {
  /// Shift 0 makes every flow model's run NaN, so the slider starts above it and a 0 (or a
  /// negative, or not-a-number) from a saved step, preset or agent is raised to the minimum.
  @Test func shiftNeverGoesToZero() throws {
    let shift = try #require(SettingsRegistry.byID["shift"])
    guard case .slider(let range, _, _) = shift.control else {
      Issue.record("Shift isn't a slider")
      return
    }
    #expect(range.lowerBound == SettingsRegistry.minimumShift && SettingsRegistry.minimumShift > 0)
    #expect(SettingsRegistry.raised(0, to: SettingsRegistry.minimumShift) == SettingsRegistry.minimumShift)
    #expect(SettingsRegistry.raised(-2, to: SettingsRegistry.minimumShift) == SettingsRegistry.minimumShift)
    #expect(SettingsRegistry.raised(.nan, to: SettingsRegistry.minimumShift) == SettingsRegistry.minimumShift)
    #expect(SettingsRegistry.raised(3, to: SettingsRegistry.minimumShift) == 3)
    #expect(SettingsRegistry.raised(0, to: nil) == 0)
  }
}
