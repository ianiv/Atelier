@testable import Atelier
import Foundation
import Testing

/// 3D LUTs (`CubeLUT`, `Edit.LUTTable`). Slice D adds the .cube cases; for now the table's
/// Float16 storage keeps its values.
struct LUTTests {
  @Test func tableKeepsItsValues() throws {
    let size = 2
    let values: [Float] = (0..<size * size * size * 3).map { Float($0) / 23 }
    let table = Edit.LUTTable(name: "ramp", size: size, values: values)
    #expect(table.data.count == values.count * 2)
    for (got, want) in zip(table.values, values) { #expect(abs(got - want) < 1e-3) }
    let decoded = try JSONDecoder().decode(Edit.LUTTable.self, from: JSONEncoder().encode(table))
    #expect(decoded == table && decoded.digest == table.digest)
  }
}
