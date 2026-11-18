@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// Changing the moodboard as a whole (`Moodboard.move`, `Moodboard.set`): the order is the order
/// the images are sent in, and each change made on the board is reported once so History can
/// record it. Tests keep no session, so nothing is written to the user's board.
@MainActor
@Suite(.tags(.smoke))
struct MoodboardTests {
  private static func board(_ count: Int) throws -> (board: Moodboard, ids: [UUID]) {
    let board = Moodboard()
    for _ in 0..<count { board.add(try CanvasRefineTests.pattern(width: 32, height: 32)) }
    return (board, board.items.map(\.id))
  }

  @Test func moveReordersWhatIsSent() throws {
    let (board, ids) = try Self.board(3)
    var changes = 0
    board.onChange = { changes += 1 }
    board.move(ids[0], to: 2)
    #expect(board.items.map(\.id) == [ids[1], ids[2], ids[0]])
    board.move(ids[0], to: 0)
    #expect(board.items.map(\.id) == ids)
    // Past the end is the end; where it already is, and an image not on the board, change nothing.
    board.move(ids[1], to: 99)
    #expect(board.items.map(\.id) == [ids[0], ids[2], ids[1]])
    #expect(changes == 3)
    board.move(ids[1], to: 2)
    board.move(UUID(), to: 0)
    #expect(changes == 3)
  }

  @Test func setKeepsTheItemsItIsGiven() throws {
    let (board, ids) = try Self.board(2)
    var changes = 0
    board.onChange = { changes += 1 }
    var items = Array(board.items.reversed())
    items[0].weight = 4
    board.set(items)
    #expect(board.items.map(\.id) == [ids[1], ids[0]])
    // A weight is held to 0–1, as `setWeight` holds it.
    #expect(board.items.map(\.weight) == [1, 1])
    #expect(changes == 1)
    // The same board again isn't a change.
    board.set(board.items)
    #expect(changes == 1)
    items[1].weight = 0
    board.set(items)
    #expect(board.references.count == 1)
    board.set([])
    #expect(board.items.isEmpty && changes == 3)
  }
}
