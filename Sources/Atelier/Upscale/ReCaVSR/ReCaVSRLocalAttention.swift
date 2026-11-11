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
/// Runs a tile of query tokens at a time (every frame at once): the tile's keys are the union of
/// its tokens' windows, sliced from each plane, and a mask keeps each query to its own window.
/// The mask depends only on where the tile sits, so each tile's is built once and spread over
/// the planes on the GPU; a tile whose queries all read the whole rectangle runs unmasked.
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
  /// Per tile, `[queries, keys]` float32: 0 where the query's window holds the key, else -inf;
  /// nil when nothing is masked.
  private var masks: [DynamicGraph.Tensor<Float>?] = []

  init(
    graph: DynamicGraph, gridHeight: Int, gridWidth: Int, windowHeight: Int, windowWidth: Int,
    mode: Mode = .clamped, tileHeight: Int = 8, tileWidth: Int = 16, heads: Int = ReCaVSRConfig.heads,
    headDimension: Int = ReCaVSRConfig.headDimension
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
    masks = tiles.map(mask)
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

  private func mask(_ tile: Tile) -> DynamicGraph.Tensor<Float>? {
    var mask = Tensor<Float>(.CPU, .WC(tile.queries, tile.keys))
    var masked = false
    for (qi, qy) in tile.rows.enumerated() {
      for (qj, qx) in tile.columns.enumerated() {
        let window = window(row: qy, column: qx)
        let q = qi * tile.columns.count + qj
        for (ki, ky) in tile.keyRows.enumerated() {
          for (kj, kx) in tile.keyColumns.enumerated() {
            let inside = window.rows.contains(ky) && window.columns.contains(kx)
            if !inside { masked = true }
            mask[q, ki * tile.keyColumns.count + kj] = inside ? 0 : -Float.infinity
          }
        }
      }
    }
    return masked ? graph.variable(mask.toGPU(0)) : nil
  }

  /// Gather indices, cached: the rows of `[n * tokens, dim]` a tile reads on an n-frame plane,
  /// a tile's queries over `frames` frames, and the order that puts the tiles' outputs back.
  private var keyIndices: [Int: DynamicGraph.Tensor<Int32>] = [:]
  private var queryIndices: [Int: DynamicGraph.Tensor<Int32>] = [:]
  private var outputOrder: [Int: DynamicGraph.Tensor<Int32>] = [:]

  private func index(_ values: [Int]) -> DynamicGraph.Tensor<Int32> {
    graph.variable(Tensor<Int32>(values.map(Int32.init), .CPU, .C(values.count)).toGPU(0))
  }

  /// Token rows of `tile`'s key rectangle (or its own queries) on frames 0 ..< `frames`.
  private func rows(_ tile: Tile, frames: Int, keys: Bool) -> [Int] {
    let rows = keys ? tile.keyRows : tile.rows
    let columns = keys ? tile.keyColumns : tile.columns
    var list: [Int] = []
    for f in 0..<frames {
      for y in rows {
        for x in columns { list.append((f * gridHeight + y) * gridWidth + x) }
      }
    }
    return list
  }

  private func keyIndex(_ tile: Int, frames: Int) -> DynamicGraph.Tensor<Int32> {
    let key = tile * 1024 + frames
    if let cached = keyIndices[key] { return cached }
    let value = index(rows(tiles[tile], frames: frames, keys: true))
    keyIndices[key] = value
    return value
  }

  private func queryIndex(_ tile: Int, frames: Int) -> DynamicGraph.Tensor<Int32> {
    let key = tile * 1024 + frames
    if let cached = queryIndices[key] { return cached }
    let value = index(rows(tiles[tile], frames: frames, keys: false))
    queryIndices[key] = value
    return value
  }

  private func order(frames: Int) -> DynamicGraph.Tensor<Int32> {
    if let cached = outputOrder[frames] { return cached }
    // Where each token landed in the tiles' outputs, concatenated in tile order.
    var position = [Int](repeating: 0, count: frames * gridHeight * gridWidth)
    var next = 0
    for tile in tiles {
      for token in rows(tile, frames: frames, keys: false) {
        position[token] = next
        next += 1
      }
    }
    let value = index(position)
    outputOrder[frames] = value
    return value
  }

  /// `queries` `[1, frames * tokens, heads, dim]` against `keys`/`values`, each a list of planes
  /// `[1, n * tokens, heads, dim]` (any n). Returns `[1, frames * tokens, heads, dim]`. Tiles are
  /// gathered and put back with index selects rather than strided views.
  func callAsFunction<T: TensorNumeric & BinaryFloatingPoint>(
    queries: DynamicGraph.Tensor<T>, keys: [DynamicGraph.Tensor<T>], values: [DynamicGraph.Tensor<T>],
    frames: Int
  ) -> DynamicGraph.Tensor<T> {
    let tokens = gridHeight * gridWidth
    let HD = heads * headDimension
    let planes = keys.map { $0.shape[1] / tokens }
    let totalPlanes = planes.reduce(0, +)
    let queryRows = queries.reshaped(.WC(frames * tokens, HD))
    let keyRows = zip(keys, planes).map { $0.reshaped(.WC($1 * tokens, HD)) }
    let valueRows = zip(values, planes).map { $0.reshaped(.WC($1 * tokens, HD)) }
    let scale = 1 / Float(headDimension).squareRoot()
    var outputs: [DynamicGraph.Tensor<T>] = []
    for (index, tile) in tiles.enumerated() {
      func gather(_ rows: [DynamicGraph.Tensor<T>]) -> DynamicGraph.Tensor<T> {
        concatenated(zip(rows, planes).map { Functional.indexSelect(input: $0, index: keyIndex(index, frames: $1)) })
          .reshaped(.NHWC(1, totalPlanes * tile.keys, heads, headDimension))
      }
      let tileKeys = gather(keyRows)
      let tileValues = gather(valueRows)
      let tileQueries = Functional.indexSelect(input: queryRows, index: queryIndex(index, frames: frames))
        .reshaped(.NHWC(1, frames * tile.queries, heads, headDimension))
      let result: DynamicGraph.Tensor<T>
      if let spatial = masks[index] {
        // Spread [queries, keys] to [frames * queries, planes * keys].
        let rowIndex = graph.variable(
          Tensor<Int32>((0..<(frames * tile.queries)).map { Int32($0 % tile.queries) }, .CPU, .C(frames * tile.queries))
            .toGPU(0))
        let columnIndex = graph.variable(
          Tensor<Int32>((0..<(totalPlanes * tile.keys)).map { Int32($0 % tile.keys) }, .CPU, .C(totalPlanes * tile.keys))
            .toGPU(0))
        let byRow = Functional.indexSelect(input: DynamicGraph.Tensor<T>(from: spatial), index: rowIndex)
        let tokenMask = Functional.indexSelect(input: byRow.transposed(0, 1).copied(), index: columnIndex)
          .transposed(0, 1).copied().reshaped(.NHWC(1, 1, frames * tile.queries, totalPlanes * tile.keys))
        result = ScaledDotProductAttention(scale: scale, hasAttentionMask: true)(
          queries: tileQueries, keys: tileKeys, values: tileValues, attentionMask: tokenMask)
      } else {
        result = ScaledDotProductAttention(scale: scale)(
          queries: tileQueries, keys: tileKeys, values: tileValues)
      }
      outputs.append(result.reshaped(.WC(frames * tile.queries, HD)))
    }
    return Functional.indexSelect(input: concatenated(outputs), index: order(frames: frames))
      .reshaped(.NHWC(1, frames * tokens, heads, headDimension))
  }
}
