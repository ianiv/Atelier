@testable import Atelier
import CryptoKit
import Foundation
import ImageIO
import Testing

/// grain.py's port (`Grain`, `Resample`, `GrainProfile`). Fixtures are small and made here; the
/// expected numbers were computed with grain.py, numpy 2.5 and Pillow 13.
///
/// `grainPyFixture` checks Match Reference against grain.py's own numbers on a committed
/// reference (`Fixtures/grain-parity`, read from the source tree: tests run on the Mac that built
/// them). `grainPyParity` compares against grain.py itself on real reference photos. It runs only when
/// `GRAIN_PARITY_DIR` names a folder of inputs (pass it as `TEST_RUNNER_GRAIN_PARITY_DIR` to
/// xcodebuild): a `manifest.json` with raw RGB references, a test picture and profile cases. It
/// writes Swift's measurements, profiles and renders there for a script to compare.
struct GrainTests {
  /// A profile as grain.py's `save_profile` writes one (indent 1, nulls for what it lacks, floats
  /// for every setting) reads with its values, and a missing seed as 7.
  @Test func readsGrainPyProfile() throws {
    let json = """
    {
     "type": "grain-profile",
     "version": 1,
     "name": "night",
     "source": "ref.jpg",
     "created": "2026-11-19",
     "refWidth": 1440,
     "settings": {"blur": 2.0, "motion": 0.0, "angle": 0.0, "lum": 11.0, "chroma": 3.5, "size": 1.3,
      "csize": 2.4, "colour": 0.6, "tint": 0.0, "expo": 0.0, "real": 0.0},
     "curve": [0.8, 1.0, 0.9, 0.7],
     "refStats": {"m": [100.0, 90.0, 80.0], "s": [40.0, 41.0, 42.0]},
     "real": null,
     "extra": "ignored"
    }
    """
    let profile = try GrainProfile.decoded(from: Data(json.utf8))
    #expect(profile.name == "night" && profile.refWidth == 1440 && profile.real == nil)
    #expect(profile.settings.lum == 11 && profile.settings.csize == 2.4 && profile.settings.seed == nil)
    let options = profile.settings.applied(to: EditOptions())
    #expect(options.grain.lum == 11 && options.lens.blur == 2 && options.match.colour == 0.6 && options.grain.seed == 7)
  }

  /// Atelier writes a profile as `json.dump(indent=1)` does, and reads back what it wrote.
  @Test func writesGrainPyJSON() throws {
    var settings = GrainProfile.Settings()
    settings.lum = 7.9
    settings.tint = 1e-5
    let real = GrainProfile.RealNoise(patch: 2, count: 1, enc: 24, curve: [1, 2.5, 3, 4], data: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]))
    let profile = GrainProfile(
      name: "Nuit \"é\"", source: nil, created: "2026-11-19", refWidth: 1440, settings: settings, curve: [0.1, 1, 1, 1], refStats: nil,
      real: real)
    let text = try String(decoding: profile.encoded(), as: UTF8.self)
    let expected = """
    {
     "type": "grain-profile",
     "version": 1,
     "name": "Nuit \\"\\u00e9\\"",
     "source": null,
     "created": "2026-11-19",
     "refWidth": 1440,
     "settings": {
      "blur": 3.0,
      "motion": 0.0,
      "angle": 0.0,
      "lum": 7.9,
      "chroma": 3.0,
      "size": 1.0,
      "csize": 1.0,
      "colour": 0.0,
      "tint": 1e-05,
      "expo": 0.0,
      "real": 0.0
     },
     "curve": [
      0.1,
      1.0,
      1.0,
      1.0
     ],
     "refStats": null,
     "real": {
      "patch": 2,
      "count": 1,
      "enc": 24,
      "curve": [
       1.0,
       2.5,
       3.0,
       4.0
      ],
      "data": "AQIDBAUGBwgJCgsM"
     }
    }
    """
    #expect(text == expected)
    let back = try GrainProfile.decoded(from: profile.encoded())
    #expect(back == profile)
    #expect(try back.encoded() == profile.encoded())
    #expect(PythonJSON.float(1e16) == "1e+16" && PythonJSON.float(123_456.789) == "123456.789" && PythonJSON.float(-0.0) == "-0.0")
  }

  /// The library saves, lists, numbers a copy, opens a file from anywhere, and trashes.
  @MainActor
  @Test func profileLibrary() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "GrainTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = GrainProfileStore(directory: folder)
    #expect(store.profiles.isEmpty)
    let profile = GrainProfile(name: "Night", created: "2026-11-19", curve: [1, 1, 1, 1])
    let url = try store.save(profile)
    #expect(url.lastPathComponent == "Night.grain.json")
    let copy = try store.add(contentsOf: url)
    #expect(copy.name == "Night 2")
    #expect(GrainProfileStore(directory: folder).profiles.map(\.name) == ["Night", "Night 2"])
    let elsewhere = FileManager.default.temporaryDirectory.appending(path: "elsewhere-\(UUID().uuidString).grain.json")
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    var unnamed = profile
    unnamed.name = ""
    try unnamed.write(to: elsewhere)
    #expect(try GrainProfile.load(from: elsewhere).name.hasPrefix("elsewhere-"))
    try store.delete(copy)
    #expect(store.profiles.map(\.name) == ["Night"])
    store.reload()
    #expect(store.profiles.map(\.name) == ["Night"])
  }

  /// Names that make the same file name get their own files, a Finder copy of a profile is
  /// listed numbered, and deleting either removes only its own file.
  @MainActor
  @Test func profileLibraryNameCollisions() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "GrainTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = GrainProfileStore(directory: folder)
    let slash = try store.save(GrainProfile(name: "Day/Night", created: "2026-11-19"))
    let dash = try store.save(GrainProfile(name: "Day-Night", created: "2026-11-19"))
    #expect(slash != dash)
    #expect(try GrainProfile.load(from: slash).name == "Day/Night" && GrainProfile.load(from: dash).name == "Day-Night")
    let night = try store.save(GrainProfile(name: "Night", created: "2026-11-19"))
    try FileManager.default.copyItem(at: night, to: folder.appending(path: "Night copy.grain.json"))
    store.reload()
    #expect(Set(store.profiles.map(\.name)) == ["Day-Night", "Day/Night", "Night", "Night 2"])
    try store.delete(try #require(store.profile(named: "Night 2")))
    #expect(FileManager.default.fileExists(atPath: night.path))
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Night copy.grain.json").path))
    try store.delete(try #require(store.profile(named: "Day/Night")))
    #expect(FileManager.default.fileExists(atPath: dash.path) && !FileManager.default.fileExists(atPath: slash.path))
    #expect(Set(GrainProfileStore(directory: folder).profiles.map(\.name)) == ["Day-Night", "Night"])
  }

  /// Renaming moves the profile to a file named after it, refuses a listed name, and a
  /// case-only rename keeps one file.
  @MainActor
  @Test func profileLibraryRename() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "GrainTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = GrainProfileStore(directory: folder)
    let old = try store.save(GrainProfile(name: "Night", created: "2026-11-19"))
    try store.save(GrainProfile(name: "Day", created: "2026-11-19"))
    #expect(throws: GrainProfileStore.RenameError.self) { try store.rename("Night", to: "Day") }
    try store.rename("Night", to: "Dusk")
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(try GrainProfile.load(from: folder.appending(path: "Dusk.grain.json")).name == "Dusk")
    try store.rename("Dusk", to: "dusk")
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(files == ["Day.grain.json", "dusk.grain.json"])
    #expect(GrainProfileStore(directory: folder).profiles.map(\.name) == ["Day", "dusk"])
  }

  /// Pillow's mode "F" bicubic, enlarging and shrinking, matches bit for bit; a region is exactly
  /// that part of the whole resize.
  @Test func pillowBicubicFloat() {
    // `np.arange(15, dtype=np.float32).reshape(3, 5) * 7.3 % 11`.
    let input: [Float] = (0..<15).map { (Float($0) * Float(7.3)).truncatingRemainder(dividingBy: 11) }
    let source: [Float] = [
      0.0, 7.300000190734863, 3.6000003814697266, 10.900001525878906, 7.200000762939453, 3.5, 10.800003051757812,
      7.100002288818359, 3.4000015258789062, 10.700004577636719, 7.0, 3.3000030517578125, 10.600006103515625, 6.900001525878906,
      3.2000045776367188,
    ].map { Float($0) }
    #expect(input == source)
    let shrunk = Resample.resize(source, width: 5, height: 3, toWidth: 3, height: 2)
    let expectedShrunk: [Double] = [4.321180820465088, 6.539434909820557, 8.459139823913574, 5.99891996383667, 7.910224437713623, 5.698306560516357]
    #expect(shrunk == expectedShrunk.map { Float($0) })
    let grown = Resample.resize(source, width: 5, height: 3, toWidth: 8, height: 7)
    #expect(Array(grown.prefix(8)) == [-0.8618152141571045, 2.731745481491089, 7.0122575759887695, 3.8984832763671875, 5.425024509429932, 11.436945915222168, 9.162565231323242, 6.521118640899658].map { Float($0) })
    #expect(Array(grown.suffix(4)) == [10.706291198730469, 7.518918991088867, 4.17086935043335, 2.136507987976074].map { Float($0) })
    // Only the height changes: one pass.
    let taller = Resample.resize(source, width: 5, height: 3, toWidth: 5, height: 6)
    #expect(Array(taller.prefix(5)) == [-0.30882352590560913, 6.991176605224609, 3.2911767959594727, 11.561766624450684, 6.891176700592041].map { Float($0) })
    let region = Resample.Region(x: 2, y: 3, width: 4, height: 3)
    let part = Resample.resize(source, width: 5, height: 3, toWidth: 8, height: 7, region: region)
    let cut = (3..<6).flatMap { row in grown[row * 8 + 2..<row * 8 + 6] }
    #expect(part == cut)
  }

  /// Pillow's 8-bit RGB bicubic (fixed-point weights, clipped per pass) matches bit for bit.
  @Test func pillowBicubicRGB8() {
    let pixels = (0..<7 * 5 * 3).map { UInt8($0 * 37 % 256) }
    let out = Resample.resizeRGB8(pixels, width: 7, height: 5, toWidth: 4, height: 3)
    #expect(
      out == [57, 87, 124, 169, 64, 105, 129, 170, 65, 110, 147, 177, 72, 102, 139, 189, 79, 120, 144, 190, 80, 125, 162, 197, 83, 117, 154, 116, 96, 135, 161, 117, 100, 140, 173, 124])
  }

  /// grain.py's helpers: `autocorr`, `interp_curve`, `box_sizes`.
  @Test func grainPyHelpers() {
    // `np.arange(64, dtype=np.float32).reshape(8, 8) * 5.1 % 3.7`, in float32.
    let exact: [Float] = (0..<64).map { (Float($0) * Float(5.1)).truncatingRemainder(dividingBy: Float(3.7)) }
    let ac = [1, 2, 4].map { Grain.autocorr(exact, width: 8, height: 8, lag: $0) }
    #expect(ac == [0.25765731930732727, 0.18256492912769318, -0.0012643561931326985].map { Float($0) })
    let curve = [0.5, 1, 0.8, 0.9]
    let values = [0, 0.1, 0.2, 0.5, 0.9].map { Grain.interp($0, curve: curve) }
    let expected = [0.5, 0.5182926829268293, 0.8292682926829269, 0.8034722222222223, 0.9]
    #expect(zip(values, expected).allSatisfy { abs($0 - $1) < 1e-15 })
    #expect(Blur.boxSizes(sigma: 3) == [5, 5, 7] && Blur.boxSizes(sigma: 8) == [15, 15, 17])
    #expect(Grain.round1(7.85) == 7.8 && Grain.round1(0.25) == 0.2 && Grain.round(2.5) == 2)
  }

  /// With the blur, grain and colour off, grain.py's pipeline gives back the image.
  @Test func zeroSettingsIdentity() {
    let planes = Self.picture(width: 96, height: 64)
    var settings = GrainProfile.Settings()
    settings.blur = 0
    settings.lum = 0
    settings.chroma = 0
    let out = Grain.process(planes, settings: settings)
    #expect(out.rgba == planes.rgba)
  }

  /// A grain render of a window is that part of the full render (the 100% view's grain).
  @Test func grainWindowMatchesFull() {
    let width = 160, height = 120
    var full = Self.picture(width: width, height: height)
    let l = Grain.luminance(full)
    let curve = [0.4, 1, 0.8, 0.9]
    Grain.addGrain(
      &full, luminance: l, lum: 9, chroma: 3, size: 1.3, csize: 2, seed: 7, refWidth: 200, curve: curve, layout: .whole(width: width, height: height))
    let region = Resample.Region(x: 37, y: 21, width: 50, height: 40)
    var part = Self.picture(width: width, height: height).cropped(x: region.x, y: region.y, width: region.width, height: region.height)
    let partL = Grain.luminance(part)
    Grain.addGrain(
      &part, luminance: partL, lum: 9, chroma: 3, size: 1.3, csize: 2, seed: 7, refWidth: 200, curve: curve,
      layout: Grain.Layout(width: width, height: height, region: region))
    let expected = full.cropped(x: region.x, y: region.y, width: region.width, height: region.height)
    #expect(part.r == expected.r && part.g == expected.g && part.b == expected.b)
  }

  /// The noise field is unit Gaussian clipped at ±4, and the same for the same seed.
  @Test func noiseFieldStatistics() {
    let field = Grain.noiseField(width: 400, height: 300, seed: 7)
    #expect(field == Grain.noiseField(width: 400, height: 300, seed: 7))
    #expect(field != Grain.noiseField(width: 400, height: 300, seed: 8))
    let mean = field.reduce(0.0) { $0 + Double($1) } / Double(field.count)
    let variance = field.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(field.count)
    #expect(abs(mean) < 0.01 && abs(variance.squareRoot() - 1) < 0.01)
    #expect(field.allSatisfy { abs($0) <= 4 })
  }

  /// Match Reference finds Atelier's own grain: on flat grey with grain of size 2.4 and strength
  /// 10 laid at the reference's width, it fits a size within one `SIZES` step and recovers the
  /// strength, and the real noise is 120 patches of 48 px.
  @Test func matchRecoversSyntheticGrain() throws {
    let width = 720, height = 720
    let count = width * height
    var planes = EditPipeline.Planes(
      width: width, height: height, r: [Float](repeating: 120, count: count), g: [Float](repeating: 120, count: count),
      b: [Float](repeating: 120, count: count), alpha: [UInt8](repeating: 255, count: count))
    let l = Grain.luminance(planes)
    Grain.addGrain(
      &planes, luminance: l, lum: 10, chroma: 0, size: 2.4, csize: 1, seed: 3, refWidth: width, curve: [1, 1, 1, 1],
      layout: .whole(width: width, height: height))
    // grain.py measures bytes.
    planes = EditPipeline.Planes(rgba: planes.rgba, width: width, height: height)
    let match = try #require(Grain.matchReference(planes))
    let sizes = EditOptions.Grain.sizes
    let index = try #require(sizes.firstIndex(of: match.size))
    let target = try #require(sizes.firstIndex(of: 2.4))
    #expect(abs(index - target) <= 1)
    #expect(abs(match.lum - 10) <= 1.5)
    #expect(match.real.patch == 48 && match.real.count == 120 && match.real.data.count == 120 * 48 * 48 * 3)
    let profile = try #require(GrainProfile(measuring: planes, name: "synthetic", source: "synthetic.png"))
    #expect(profile.refWidth == width && profile.settings.colour == 0.6 && profile.curve?.max() == 1)
  }

  /// `Blur.boxBlur`, which sums lines side by side, gives exactly a line-at-a-time cumulative sum
  /// (grain.py's `box_blur_axis`), at sizes that leave short groups and chunks and radii past the
  /// plane's size.
  @Test func boxBlurMatchesScalarSums() {
    func scalar(_ plane: [Float], width: Int, height: Int, radius r: Int, horizontal: Bool) -> [Float] {
      var out = plane
      let (lines, length) = horizontal ? (height, width) : (width, height)
      for line in 0..<lines {
        func index(_ i: Int) -> Int { horizontal ? line * width + i : i * width + line }
        var sums: [Double] = []
        var total = 0.0
        for k in 0..<length + 2 * r + 1 {
          total += Double(plane[index(min(max(k - (r + 1), 0), length - 1))])
          sums.append(total)
        }
        for i in 0..<length { out[index(i)] = Float((sums[i + 2 * r + 1] - sums[i]) / Double(2 * r + 1)) }
      }
      return out
    }
    var state: UInt64 = 9
    for (width, height) in [(1, 1), (5, 3), (37, 11), (70, 9), (33, 100), (130, 17)] {
      let plane = (0..<width * height).map { _ -> Float in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24) * 255
      }
      for r in [1, 2, 7, 60] {
        for horizontal in [true, false] {
          let fast = Blur.boxBlur(plane, width: width, height: height, radius: r, horizontal: horizontal)
          let slow = scalar(plane, width: width, height: height, radius: r, horizontal: horizontal)
          #expect(fast.map(\.bitPattern) == slow.map(\.bitPattern), "\(width)x\(height) r \(r) \(horizontal ? "across" : "down")")
        }
      }
    }
  }

  // MARK: - Parity with grain.py

  private struct Manifest: Decodable {
    struct Raw: Decodable {
      var raw: String
      var width: Int
      var height: Int
      var name: String?
      var source: String?
    }

    struct Case: Decodable {
      var name: String
      var profile: String?
      var settings: [String: Double]
    }

    var refs: [Raw]
    var input: Raw
    var cases: [Case]
  }

  private struct Measured: Encodable {
    var refStats: GrainProfile.ChannelStats
    var y_ac: [Double]
    var c_ac: [Double]
    var c_sd: Double
    var curve: [Double]
    var patches: Int
    var sds: [Double]
    var size: Double
    var csize: Double
    var lum: Double
    var chroma: Double
    var matched_curve: [Double]
    var seconds: Double
  }

  /// What grain.py measured on `Fixtures/grain-parity/reference.png` (a synthetic grainy
  /// picture, 256 × 192), written by the fixture script with grain.py, numpy and Pillow.
  private struct Fixture: Decodable {
    struct Real: Decodable {
      var patch: Int
      var count: Int
      var enc: Double
      var curve: [Double]
      var sha256: String
      var bytes: Int
    }

    var width: Int
    var height: Int
    var refStats: GrainProfile.ChannelStats
    var yAC: [Double]
    var cAC: [Double]
    var cSD: Double
    var curve: [Double]
    var patches: Int
    var sds: [Double]
    var size: Double
    var csize: Double
    var lum: Double
    var chroma: Double
    var settings: [String: Double]
    var refWidth: Int
    var real: Real
  }

  /// Match Reference on a committed reference measures what grain.py measured: the RGB
  /// statistics, the flat patches and their spreads, grain shape, colour blotches and curve, and
  /// the same real-noise bytes (by SHA-256). The fitted sizes compare against Atelier's own random
  /// grain, so they may land one `SIZES` step from grain.py's.
  @Test func grainPyFixture() throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/grain-parity")
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: folder.appending(path: "grain-py.json")))
    let source = try #require(CGImageSourceCreateWithURL(folder.appending(path: "reference.png") as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let ref = try #require(EditPipeline.Planes(image))
    #expect(ref.width == fixture.width && ref.height == fixture.height)
    func close(_ a: [Double], _ b: [Double], _ tolerance: Double = 1e-6) -> Bool {
      a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance * max(1, abs($1)) }
    }
    let stats = Grain.channelStats(ref)
    #expect(stats == fixture.refStats)
    let extraction = try #require(Grain.extractRealNoise(ref))
    #expect(extraction.patches.count == fixture.patches)
    #expect(close(extraction.patches.map(\.sd), fixture.sds))
    let match = try #require(Grain.matchReference(ref))
    #expect(close(match.reference.yAC, fixture.yAC) && close(match.reference.cAC, fixture.cAC))
    #expect(close([match.reference.cSD], [fixture.cSD]) && close(match.reference.curve, fixture.curve))
    let sizes = EditOptions.Grain.sizes
    func steps(_ a: Double, _ b: Double) -> Int { abs((sizes.firstIndex(of: a) ?? -9) - (sizes.firstIndex(of: b) ?? 99)) }
    #expect(steps(match.size, fixture.size) <= 1 && steps(match.csize, fixture.csize) <= 1)
    let profile = try #require(GrainProfile(measuring: ref, name: "Fixture"))
    let real = try #require(profile.real)
    #expect(real.patch == fixture.real.patch && real.count == fixture.real.count && real.enc == fixture.real.enc)
    #expect(close(real.curve, fixture.real.curve))
    #expect(real.data.count == fixture.real.bytes)
    #expect(SHA256.hash(data: real.data).map { String(format: "%02x", $0) }.joined() == fixture.real.sha256)
    #expect(profile.refWidth == fixture.refWidth && profile.refStats == fixture.refStats)
    #expect(profile.settings.colour == fixture.settings["colour"] && profile.settings.blur == fixture.settings["blur"])
    // grain.py's profile has no seed.
    #expect(fixture.settings["seed"] == nil)
    let written = try JSONSerialization.jsonObject(with: profile.encoded()) as? [String: Any]
    #expect((written?["settings"] as? [String: Any])?["seed"] == nil)
  }

  @Test func grainPyParity() throws {
    guard let path = ProcessInfo.processInfo.environment["GRAIN_PARITY_DIR"] else { return }
    let folder = URL(fileURLWithPath: path)
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json")))
    func planes(_ raw: Manifest.Raw) throws -> EditPipeline.Planes {
      let bytes = [UInt8](try Data(contentsOf: folder.appending(path: raw.raw)))
      var rgba = [UInt8](repeating: 255, count: raw.width * raw.height * 4)
      for i in 0..<raw.width * raw.height {
        rgba[i * 4] = bytes[i * 3]
        rgba[i * 4 + 1] = bytes[i * 3 + 1]
        rgba[i * 4 + 2] = bytes[i * 3 + 2]
      }
      return EditPipeline.Planes(rgba: rgba, width: raw.width, height: raw.height)
    }
    func write(_ planes: EditPipeline.Planes, _ name: String) throws {
      let rgba = planes.rgba
      var rgb = [UInt8](repeating: 0, count: planes.width * planes.height * 3)
      for i in 0..<planes.width * planes.height {
        rgb[i * 3] = rgba[i * 4]
        rgb[i * 3 + 1] = rgba[i * 4 + 1]
        rgb[i * 3 + 2] = rgba[i * 4 + 2]
      }
      try Data(rgb).write(to: folder.appending(path: name))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var timings: [String: Double] = [:]
    _ = Grain.synthTable
    for raw in manifest.refs {
      let ref = try planes(raw)
      let name = raw.name ?? raw.raw
      let start = Date()
      let match = try #require(Grain.matchReference(ref))
      let seconds = Date().timeIntervalSince(start)
      let extraction = try #require(Grain.extractRealNoise(ref))
      let stats = Grain.channelStats(ref)
      let measured = Measured(
        refStats: stats, y_ac: match.reference.yAC, c_ac: match.reference.cAC, c_sd: match.reference.cSD, curve: match.reference.curve,
        patches: extraction.patches.count, sds: extraction.patches.prefix(200).map(\.sd), size: match.size, csize: match.csize,
        lum: match.lum, chroma: match.chroma, matched_curve: match.curve, seconds: seconds)
      try encoder.encode(measured).write(to: folder.appending(path: "swift-\(name).json"))
      let profileStart = Date()
      var profile = try #require(GrainProfile(measuring: ref, name: "swift-\(name)", source: raw.source))
      timings["profile \(name)"] = Date().timeIntervalSince(profileStart)
      profile.created = "2026-11-19"
      try profile.write(to: folder.appending(path: "swift-\(name).grain.json"))
      timings["match \(name)"] = seconds
    }
    let input = try planes(manifest.input)
    for item in manifest.cases {
      var settings = GrainProfile.Settings()
      var context = EditPipeline.Context.empty
      if let path = item.profile {
        let url = URL(fileURLWithPath: path)
        let profile = try GrainProfile.load(from: url)
        settings = profile.settings
        context = EditPipeline.Context(refWidth: profile.refWidth, curve: profile.curve, refStats: profile.refStats, realNoise: profile.real)
        // Round trip: the file written back byte for byte.
        try profile.encoded().write(to: folder.appending(path: "rt-\(url.lastPathComponent)"))
      }
      let s = item.settings
      settings.blur = s["blur"] ?? settings.blur
      settings.motion = s["motion"] ?? settings.motion
      settings.angle = s["angle"] ?? settings.angle
      settings.lum = s["lum"] ?? settings.lum
      settings.chroma = s["chroma"] ?? settings.chroma
      settings.size = s["size"] ?? settings.size
      settings.csize = s["csize"] ?? settings.csize
      settings.colour = s["colour"] ?? settings.colour
      settings.tint = s["tint"] ?? settings.tint
      settings.expo = s["expo"] ?? settings.expo
      settings.real = s["real"] ?? settings.real
      settings.seed = s["seed"].map { Int($0) } ?? 7
      let start = Date()
      let out = Grain.process(input, settings: settings, context: context)
      timings["render \(item.name)"] = Date().timeIntervalSince(start)
      try write(out, "swift-out-\(item.name).rgb")
      if item.name == "zero" { #expect(out.rgba == input.rgba) }
    }
    try encoder.encode(timings).write(to: folder.appending(path: "swift-timings.json"))
  }

  // MARK: - Fixtures

  /// Smooth gradients, dark to bright.
  static func picture(width: Int, height: Int) -> EditPipeline.Planes {
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        rgba[i] = UInt8(255 * x / max(width - 1, 1))
        rgba[i + 1] = UInt8(255 * y / max(height - 1, 1))
        rgba[i + 2] = UInt8((x * 7 + y * 3) % 256)
      }
    }
    return EditPipeline.Planes(rgba: rgba, width: width, height: height)
  }
}
