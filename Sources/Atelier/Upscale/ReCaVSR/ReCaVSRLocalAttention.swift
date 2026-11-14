@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// ReCaVSR's local self-attention: each query token reads, on every visible plane (frame), only
/// the keys in a spatial window around it; one softmax over all of them, no mask in time. Two
/// kinds of window:
///
/// - `.clamped`, the DiT's (`paired_attention`, kernels/local_attention.py:98-149): a
///   `windowHeight`×`windowWidth` window centered on the query and clamped inside the grid
///   (start `clamp(y − wh/2, 0, H − wh)`), at most the grid (local_attention.py:213).
/// - `.relative`, FlashDecoder's (`_local_attention`, flashdecoder_wan22.py:93-109): keys at
///   offsets −w/2 ≤ d < w/2 from the query, not clamped, so tokens near an edge read fewer.
///
/// The grid is cut into tiles of query tokens (every frame at once); a tile's keys are the
/// union of its tokens' windows on every plane, and a mask keeps each query to its own window.
/// Tiles run batched, as many per attention call as fit a memory budget: their queries and
/// keys gathered with index selects (padded to the largest tile, the padding masked), one
/// attention, then the outputs put back in token order with another index select. Dispatching
/// ops costs far more here than the arithmetic, so a layer takes a handful of calls, not one per
/// tile. The indices and masks are built once per shape.
final nonisolated class ReCaVSRLocalAttention {
  enum Mode {
    case clamped, relative
  }

  let gridHeight: Int
  let gridWidth: Int
  let windowHeight: Int
  let windowWidth: Int
  let mode: Mode
  /// Query tile size in tokens.
  let tileHeight: Int
  let tileWidth: Int
  private let graph: DynamicGraph
  private let heads: Int
  private let headDimension: Int
  /// Bytes the gathered keys (or values) of one call may take, at float32.
  private let budget: Int

  /// A tile of queries and the key rectangle its windows cover.
  struct Tile {
    var rows: Range<Int>
    var columns: Range<Int>
    var keyRows: Range<Int>
    var keyColumns: Range<Int>
    var queries: Int { rows.count * columns.count }
    var keys: Int { keyRows.count * keyColumns.count }
  }

  private(set) var tiles: [Tile] = []
  /// The largest tile's queries and key rectangle, what every tile is padded to.
  private var maxQueries = 0
  private var maxKeys = 0

  /// Indices and mask for one group of tiles at one shape.
  private struct Group {
    var tiles: Range<Int>
    var queries: DynamicGraph.Tensor<Int32>
    var keys: DynamicGraph.Tensor<Int32>
    /// `[tiles, 1, frames · maxQueries, planes · maxKeys]`: 0 where read, else -inf.
    var mask: DynamicGraph.AnyTensor
  }

  /// The groups for one shape (frames of queries, planes of keys, element type), and each
  /// token's row in their concatenated outputs.
  private struct Plan {
    var groups: [Group]
    var order: DynamicGraph.Tensor<Int32>
  }

  private var plans: [String: Plan] = [:]

  init(
    graph: DynamicGraph, gridHeight: Int, gridWidth: Int, windowHeight: Int, windowWidth: Int,
    mode: Mode = .clamped, tileHeight: Int = 16, tileWidth: Int = 32, heads: Int = ReCaVSRConfig.heads,
    headDimension: Int = ReCaVSRConfig.headDimension, budget: Int = 384 << 20
  ) {
    self.graph = graph
    self.gridHeight = gridHeight
    self.gridWidth = gridWidth
    self.mode = mode
    self.windowHeight = mode == .clamped ? min(gridHeight, windowHeight) : windowHeight
    self.windowWidth = mode == .clamped ? min(gridWidth, windowWidth) : windowWidth
    self.tileHeight = min(gridHeight, tileHeight)
    self.tileWidth = min(gridWidth, tileWidth)
    self.heads = heads
    self.headDimension = headDimension
    self.budget = budget
    var tiles: [Tile] = []
    for y in stride(from: 0, to: gridHeight, by: self.tileHeight) {
      for x in stride(from: 0, to: gridWidth, by: self.tileWidth) {
        let rows = y..<min(gridHeight, y + self.tileHeight)
        let columns = x..<min(gridWidth, x + self.tileWidth)
        // Window starts only grow along a row or column, so the union runs from the first
        // query's start to the last one's end.
        let first = window(row: rows.lowerBound, column: columns.lowerBound)
        let last = window(row: rows.upperBound - 1, column: columns.upperBound - 1)
        tiles.append(
          Tile(
            rows: rows, columns: columns, keyRows: first.rows.lowerBound..<last.rows.upperBound,
            keyColumns: first.columns.lowerBound..<last.columns.upperBound))
      }
    }
    self.tiles = tiles
    maxQueries = tiles.map(\.queries).max() ?? 0
    maxKeys = tiles.map(\.keys).max() ?? 0
  }

  /// The keys the query at (`row`, `column`) reads, inside the grid.
  func window(row: Int, column: Int) -> (rows: Range<Int>, columns: Range<Int>) {
    switch mode {
    case .clamped:
      let top = ReCaVSRRouter.windowStart(row, size: gridHeight, window: windowHeight)
      let left = ReCaVSRRouter.windowStart(column, size: gridWidth, window: windowWidth)
      return (top..<(top + windowHeight), left..<(left + windowWidth))
    case .relative:
      return (
        max(0, row - windowHeight / 2)..<min(gridHeight, row + windowHeight / 2),
        max(0, column - windowWidth / 2)..<min(gridWidth, column + windowWidth / 2)
      )
    }
  }

  private func index(_ values: [Int32]) -> DynamicGraph.Tensor<Int32> {
    graph.variable(Tensor<Int32>(values, .CPU, .C(values.count)).toGPU(0))
  }

  private func plan<T: TensorNumeric & BinaryFloatingPoint>(frames: Int, planes: Int, _: T.Type) -> Plan {
    let key = "\(frames) \(planes) \(T.self)"
    if let plan = plans[key] { return plan }
    let tokens = gridHeight * gridWidth
    let perTile = max(1, planes * maxKeys * heads * headDimension * 4)
    let groupSize = max(1, min(tiles.count, budget / perTile))
    let Q = frames * maxQueries, K = planes * maxKeys
    var groups: [Group] = []
    var order = [Int32](repeating: 0, count: frames * tokens)
    var offset = 0
    for start in stride(from: 0, to: tiles.count, by: groupSize) {
      let range = start..<min(tiles.count, start + groupSize)
      var queryIndex: [Int32] = []
      var keyIndex: [Int32] = []
      var mask = Tensor<T>(.CPU, .NHWC(range.count, 1, Q, K))
      mask.withUnsafeMutableBytes { raw in
        let values = raw.bindMemory(to: T.self)
        values.initialize(repeating: -T.infinity)
        for (slot, t) in range.enumerated() {
          let tile = tiles[t]
          let base = slot * Q * K
          // Queries (frame, row, column), padded with the tile's first; the padding reads one
          // key so its (unused) rows stay finite.
          for f in 0..<frames {
            var q = 0
            for y in tile.rows {
              for x in tile.columns {
                let token = (f * gridHeight + y) * gridWidth + x
                queryIndex.append(Int32(token))
                order[token] = Int32(offset + slot * Q + f * maxQueries + q)
                let window = window(row: y, column: x)
                let row = base + (f * maxQueries + q) * K
                for p in 0..<planes {
                  var k = 0
                  for ky in tile.keyRows {
                    for kx in tile.keyColumns {
                      if window.rows.contains(ky), window.columns.contains(kx) { values[row + p * maxKeys + k] = 0 }
                      k += 1
                    }
                  }
                }
                q += 1
              }
            }
            let first = (f * gridHeight + tile.rows.lowerBound) * gridWidth + tile.columns.lowerBound
            for padded in q..<maxQueries {
              queryIndex.append(Int32(first))
              values[base + (f * maxQueries + padded) * K] = 0
            }
          }
          // Keys (plane, row, column) of the rectangle, padded with its first (masked).
          for p in 0..<planes {
            var k = 0
            for y in tile.keyRows {
              for x in tile.keyColumns {
                keyIndex.append(Int32((p * gridHeight + y) * gridWidth + x))
                k += 1
              }
            }
            let first = (p * gridHeight + tile.keyRows.lowerBound) * gridWidth + tile.keyColumns.lowerBound
            for _ in k..<maxKeys { keyIndex.append(Int32(first)) }
          }
        }
      }
      groups.append(
        Group(tiles: range, queries: index(queryIndex), keys: index(keyIndex), mask: graph.variable(mask.toGPU(0))))
      offset += range.count * Q
    }
    let plan = Plan(groups: groups, order: index(order))
    plans[key] = plan
    return plan
  }

  /// Forgets the indices and masks built for `frames` query frames (the DiT's prefix shape,
  /// used once).
  func forget(frames: Int) {
    plans = plans.filter { !$0.key.hasPrefix("\(frames) ") }
  }

  /// `queries` `[1, frames * tokens, heads, dim]` against `keys`/`values`, each a list of planes
  /// `[1, n * tokens, heads, dim]` (any n). Returns `[1, frames * tokens, heads, dim]`.
  func callAsFunction<T: TensorNumeric & BinaryFloatingPoint>(
    queries: DynamicGraph.Tensor<T>, keys: [DynamicGraph.Tensor<T>], values: [DynamicGraph.Tensor<T>],
    frames: Int
  ) -> DynamicGraph.Tensor<T> {
    let tokens = gridHeight * gridWidth
    let HD = heads * headDimension
    let planes = keys.reduce(0) { $0 + $1.shape[1] / tokens }
    let plan = plan(frames: frames, planes: planes, T.self)
    let queryRows = queries.reshaped(.WC(frames * tokens, HD))
    let keyRows = concatenated(keys, axis: 1).reshaped(.WC(planes * tokens, HD))
    let valueRows = concatenated(values, axis: 1).reshaped(.WC(planes * tokens, HD))
    let scale = 1 / Float(headDimension).squareRoot()
    let Q = frames * maxQueries, K = planes * maxKeys
    var outputs: [DynamicGraph.Tensor<T>] = []
    for group in plan.groups {
      let n = group.tiles.count
      let q = Functional.indexSelect(input: queryRows, index: group.queries).reshaped(.NHWC(n, Q, heads, headDimension))
      let k = Functional.indexSelect(input: keyRows, index: group.keys).reshaped(.NHWC(n, K, heads, headDimension))
      let v = Functional.indexSelect(input: valueRows, index: group.keys).reshaped(.NHWC(n, K, heads, headDimension))
      let result = ScaledDotProductAttention(scale: scale, hasAttentionMask: true)(
        queries: q, keys: k, values: v, attentionMask: group.mask.as(of: T.self))
      outputs.append(result.reshaped(.WC(n * Q, HD)))
    }
    return Functional.indexSelect(input: concatenated(outputs), index: plan.order)
      .reshaped(.NHWC(1, frames * tokens, heads, headDimension))
  }
}
