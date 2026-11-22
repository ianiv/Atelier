@testable import Atelier
import Testing

@Suite(.tags(.smoke))
struct InspectorLoRAsTests {
  typealias Item = LoRAEditor.Item

  private func item(_ file: String, _ weight: Double = 1, _ mode: String = "all") -> Item {
    Item(file: file, weight: weight, mode: .string(mode))
  }

  @Test func keepsIndexModeAndOtherEntries() {
    let list = [item("a", 1, "base"), item("b", 0.4, "refiner"), item("c")]
    let result = LoRAEditor.replacing(list, at: 1, with: "z", newDefault: 1, oldDefault: 1)
    #expect(result.map(\.file) == ["a", "z", "c"])
    #expect(result[1].mode == .string("refiner"))
    #expect(result[0] == list[0] && result[2] == list[2])
  }

  @Test func weightRule() {
    // Untouched (still the old default): takes the new default.
    var result = LoRAEditor.replacing([item("a", 0.8)], at: 0, with: "b", newDefault: 1.2, oldDefault: 0.8)
    #expect(result[0].weight == 1.2)
    // Changed by the user: kept.
    result = LoRAEditor.replacing([item("a", 0.9)], at: 0, with: "b", newDefault: 1.2, oldDefault: 0.8)
    #expect(result[0].weight == 0.9)
  }

  @Test func sameFileAndBadIndexAreNoOps() {
    let list = [item("a", 0.3), item("b")]
    #expect(LoRAEditor.replacing(list, at: 0, with: "a", newDefault: 2, oldDefault: 0.3) == list)
    #expect(LoRAEditor.replacing(list, at: 5, with: "x", newDefault: 2, oldDefault: 1) == list)
  }

  @Test func pickerHidesOtherEntriesButKeepsItsOwn() {
    let list = [item("a"), item("b"), item("c")]
    let catalog = ["a", "b", "c", "d"]
    let shown = LoRAEditor.filteredForReplacing(catalog, file: { $0 }, items: list, at: 1)
    #expect(shown == ["b", "d"])
  }

  @Test func descriptorJSON() {
    let value = LoRAEditor.json([item("a", 0.5, "base")])
    guard case .array(let entries) = value, case .object(let fields) = entries[0] else {
      Issue.record("not an array of objects")
      return
    }
    #expect(fields["file"] == .string("a") && fields["weight"]?.doubleValue == 0.5 && fields["mode"] == .string("base"))
  }
}
