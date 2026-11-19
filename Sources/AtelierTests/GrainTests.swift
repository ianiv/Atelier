@testable import Atelier
import Foundation
import Testing

/// grain.py's port (`Grain`, `Resample`, `GrainProfile`). Slice A adds the statistical parity
/// cases; for now the profile's JSON reads as grain.py writes it.
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
}
