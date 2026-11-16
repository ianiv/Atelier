import Foundation

/// Aspect ratio × megapixel presets, snapped to the 64px grid the engine works in.
nonisolated enum SizePreset {
  struct AspectRatio: Hashable, Identifiable {
    var width: Int
    var height: Int
    var id: String { "\(width):\(height)" }
    var label: String { id }
    var ratio: Double { Double(width) / Double(height) }
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
    size(ratio: aspect.ratio, megapixels: megapixels, maxSide: maxSide)
  }

  /// The size closest to `megapixels` at width / height `ratio`, scaled down to keep the ratio
  /// when its longer side would pass `maxSide`.
  static func size(ratio: Double, megapixels: Double, maxSide: Int = .max) -> (width: Int, height: Int) {
    let pixels = megapixels * 1_048_576
    var height = (pixels / ratio).squareRoot()
    let longest = max(height * ratio, height)
    if longest > Double(maxSide) { height *= Double(maxSide) / longest }
    return (min(snap(height * ratio), maxSide), min(snap(height), maxSide))
  }

  /// The ratio to lock a size to: a preset's exact ratio when the size is one (16:9 is 1.7778,
  /// not 1344 / 768), so later commits aim at the true ratio rather than a snapped one and don't
  /// drift; otherwise the size's own ratio. Nil for a size with no usable ratio (a zero side), which
  /// the lock then leaves alone rather than dividing by zero.
  static func lockRatio(
    width: Int, height: Int, megapixels: [Double] = megapixels, maxSide: Int = .max
  ) -> Double? {
    if let (aspect, _) = match(width: width, height: height, megapixels: megapixels, maxSide: maxSide) {
      return aspect.ratio
    }
    return validRatio(Double(width) / Double(height))
  }

  /// `ratio` if a lock can use it: positive and finite. A zero, infinite or NaN ratio would make
  /// the locked sides infinite or NaN, and `snap` traps converting those to Int.
  static func validRatio(_ ratio: Double?) -> Double? {
    guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
    return ratio
  }

  /// Whether a size is what a locked commit at `ratio` could have made, so a stored ratio still
  /// describes it. A size changed elsewhere (an agent, Match Size to Image) fails this and is
  /// locked afresh. A preset size at its own ratio always fits, though snapping both its sides on
  /// their own can leave it off the side-follows-side rule (3:2 at 2 megapixels is 1792 × 1152,
  /// where 1792 / 1.5 snaps to 1216), so pass the model's `megapixels` and `maxSide` to know it.
  static func fits(
    width: Int, height: Int, ratio: Double, megapixels: [Double] = megapixels, maxSide: Int = .max
  ) -> Bool {
    guard validRatio(ratio) != nil else { return false }
    if let (aspect, _) = match(width: width, height: height, megapixels: megapixels, maxSide: maxSide),
       isRatio(aspect.ratio, ratio)
    {
      return true
    }
    return snap(Double(width) / ratio) == height || snap(Double(height) * ratio) == width
  }

  /// The preset aspect whose ratio `ratio` is, if any. Close rather than equal, since a swapped
  /// lock stores `1 / ratio`, which can be an ulp off the portrait preset's own ratio.
  static func presetAspect(ratio: Double) -> AspectRatio? {
    aspectRatios.first { isRatio($0.ratio, ratio) }
  }

  private static func isRatio(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) <= 1e-9 * max(a, b)
  }

  /// The size for a width typed while the aspect ratio is locked: the width snapped within
  /// 64...`maxSide`, and the height that keeps `ratio`. When that height would leave the range it
  /// stops at the limit and the width follows it instead, so the ratio holds at the extremes.
  static func locked(width: Int, ratio: Double, maxSide: Int) -> (width: Int, height: Int) {
    func clamped(_ side: Double) -> Int {
      snap(min(max(side, 64), Double(maxSide)))
    }
    let width = clamped(Double(width))
    let height = Double(width) / ratio
    if snap(height) > maxSide {
      // The width follows the height's limit instead, and the height is then rederived from that
      // width as a typed width's would be, so typing the result back gives the result again (21:9
      // at 4096: a height of 1728 is 4032 wide, so H 1760 makes 4032 × 1728, not 4096 × 1728). Without that, closing the popover just after
      // a commit, which commits again, moved the other side and made a second undo step.
      var width = clamped(Double(maxSide) * ratio)
      while width > 64, snap(Double(width) / ratio) > maxSide {
        width -= 64
      }
      return (width, min(snap(Double(width) / ratio), maxSide))
    }
    if height < 64 {
      return (clamped(64 * ratio), 64)
    }
    return (width, snap(height))
  }

  /// `locked(width:ratio:maxSide:)` for a typed height.
  static func locked(height: Int, ratio: Double, maxSide: Int) -> (width: Int, height: Int) {
    let size = locked(width: height, ratio: 1 / ratio, maxSide: maxSide)
    return (size.height, size.width)
  }

  /// The size for a Megapixels choice while the aspect ratio is locked. Worked out from the longer
  /// side alone, snapped, with the other side following it as a typed side's would, so the result
  /// always `fits` the ratio; snapping both sides of `size(ratio:megapixels:maxSide:)` on their own
  /// could miss it, and the popover would then lock the size afresh at a different ratio. A
  /// preset's own ratio gives that preset's size as it is, which `fits` accepts and the picker
  /// shows as selected.
  static func locked(ratio: Double, megapixels: Double, maxSide: Int) -> (width: Int, height: Int) {
    if let aspect = presetAspect(ratio: ratio) {
      return size(aspect: aspect, megapixels: megapixels, maxSide: maxSide)
    }
    let size = size(ratio: ratio, megapixels: megapixels, maxSide: maxSide)
    return ratio >= 1
      ? locked(width: size.width, ratio: ratio, maxSide: maxSide)
      : locked(height: size.height, ratio: ratio, maxSide: maxSide)
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
