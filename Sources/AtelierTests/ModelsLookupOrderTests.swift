@testable import Atelier
import Foundation
import Testing

/// The order the engine looks through the models folders for a file already there
/// (`GenerationEngine.lookupOrder`): internal drives first, the person's order kept within each.
struct ModelsLookupOrderTests {
  private static func folder(_ name: String) -> URL {
    URL(fileURLWithPath: "/folders/\(name)", isDirectory: true)
  }

  private static func order(_ names: [String], internal onInternal: Set<String>) -> [String] {
    GenerationEngine.lookupOrder(names.map(folder)) { onInternal.contains($0.lastPathComponent) }
      .map(\.lastPathComponent)
  }

  @Test func internalFoldersComeFirstInTheirOrder() {
    #expect(Self.order(["main", "a", "b", "c"], internal: ["c", "a"]) == ["a", "c", "main", "b"])
  }

  @Test func allOnOneKindKeepsTheOrder() {
    #expect(Self.order(["main", "a", "b"], internal: []) == ["main", "a", "b"])
    #expect(Self.order(["main", "a", "b"], internal: ["main", "a", "b"]) == ["main", "a", "b"])
  }

  /// A folder the system can't answer for counts as external.
  @Test func unknownVolumeIsExternal() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
    #expect(!GenerationEngine.isOnInternalVolume(missing))
  }
}
