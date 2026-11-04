@testable import Atelier
import Testing

@MainActor struct HistoryGraphTests {
  /// A graph from "image: the image it follows", newest first.
  func graph(_ steps: [(Int64, Int64?)]) -> HistoryGraph {
    let parents = Dictionary(uniqueKeysWithValues: steps.map { ($0.0, $0.1) })
    return HistoryGraph(items: steps.map { makeItem($0.0) }) { item in
      parents[item.tensorId].flatMap(\.self).map { makeItem($0) }
    }
  }

  @Test func aLineStaysInOneLane() {
    let layout = graph([(3, 2), (2, 1), (1, nil)])
    #expect(layout.lanes == 1)
    #expect(layout.rows.map(\.column) == [0, 0, 0])
    #expect(layout.rows.map(\.continues) == [true, true, false])
    #expect(layout.rows.map(\.incoming) == [[], [0], [0]])
  }

  @Test func branchesMeetAtTheImageTheyFollow() {
    let layout = graph([(4, 2), (3, 2), (2, 1), (1, nil)])
    #expect(layout.lanes == 2)
    #expect(layout.rows.map(\.column) == [0, 1, 0, 0])
    #expect(layout.rows[1].through == [0])
    #expect(layout.rows[2].incoming == [0, 1])
    #expect(layout.rows[3].incoming == [0])
  }

  @Test func aFreedLaneIsUsedAgain() {
    // 5 follows 1 and 4 follows 2; 3 and 2 close their lanes before 1.
    let layout = graph([(5, 2), (4, 3), (3, 1), (2, 1), (1, nil)])
    #expect(layout.rows.map(\.column) == [0, 1, 1, 0, 0])
    #expect(layout.lanes == 2)
  }

  @Test func unrelatedImagesEachStartFresh() {
    let layout = graph([(2, nil), (1, nil)])
    #expect(layout.rows.map(\.column) == [0, 0])
    #expect(layout.rows.map(\.continues) == [false, false])
    #expect(layout.lanes == 1)
  }

  @Test func aParentNotListedLeavesItsLaneOpenBelow() {
    let layout = graph([(3, 99), (2, nil)])
    #expect(layout.rows[0].continues)
    #expect(layout.rows[1].column == 1)
    #expect(layout.rows[1].through == [0])
  }

  @Test func noImagesIsOneEmptyLane() {
    let layout = graph([])
    #expect(layout.rows.isEmpty && layout.lanes == 1)
  }
}
