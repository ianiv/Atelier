import Foundation

/// Aspect ratio × megapixel presets, snapped to the 64px grid the engine works in.
nonisolated enum SizePreset {
  struct AspectRatio: Hashable, Identifiable {
    var width: Int
    var height: Int
    var id: String { "\(width):\(height)" }
    var label: String { id }
  }

  static let aspectRatios: [AspectRatio] = [
    .init(width: 1, height: 1),
    .init(width: 4, height: 3), .init(width: 3, height: 4),
    .init(width: 3, height: 2), .init(width: 2, height: 3),
    .init(width: 16, height: 9), .init(width: 9, height: 16),
    .init(width: 21, height: 9),
  ]

  static let megapixels: [Double] = [0.5, 1, 1.5, 2, 3, 4]

  /// MiniMax H3 Image works from about 4 to 20 megapixels and is at its best around 16, so it gets
  /// larger choices, up to 24, and a longer side (21:9 at 16 megapixels is 6272 wide). Wide presets
  /// above 16 would pass the side limit, so they stop at it (`size(aspect:megapixels:maxSide:)`).
  static let largeMegapixels: [Double] = [1, 2, 4, 8, 12, 16, 20, 24]
  static let maxSide = 4096
  static let largeMaxSide = 6400

  static func megapixels(for traits: ModelTraits) -> [Double] {
    traits.isMiniMaxH3Image ? largeMegapixels : megapixels
  }

  static func maxSide(for traits: ModelTraits) -> Int {
    traits.isMiniMaxH3Image ? largeMaxSide : maxSide
  }

  static func snap(_ value: Double) -> Int {
    max(64, Int((value / 64).rounded()) * 64)
  }

  static func snap(_ value: Int) -> Int {
    snap(Double(value))
  }

  /// The preset's size, scaled down to keep its aspect when its longer side would pass `maxSide`.
  static func size(aspect: AspectRatio, megapixels: Double, maxSide: Int = .max) -> (width: Int, height: Int) {
    let pixels = megapixels * 1_048_576
    let ratio = Double(aspect.width) / Double(aspect.height)
    var height = (pixels / ratio).squareRoot()
    let longest = max(height * ratio, height)
    if longest > Double(maxSide) { height *= Double(maxSide) / longest }
    return (min(snap(height * ratio), maxSide), min(snap(height), maxSide))
  }

  /// The preset closest to an arbitrary size, for showing which preset (if any) is active.
  static func match(
    width: Int, height: Int, megapixels: [Double] = megapixels, maxSide: Int = .max
  ) -> (AspectRatio, Double)? {
    for aspect in aspectRatios {
      for mp in megapixels where size(aspect: aspect, megapixels: mp, maxSide: maxSide) == (width, height) {
        return (aspect, mp)
      }
    }
    return nil
  }
}
