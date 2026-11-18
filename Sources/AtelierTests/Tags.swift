import Testing

extension Tag {
  /// Fast pure-logic suites: what bare `Scripts/test.sh` runs, in about ten seconds of test time.
  /// Only suites with no sleeps, fuzzing, pixel loops or heavy file work belong here. xcodebuild
  /// can't filter by tag, so the script finds `@Suite(.tags(.smoke))` on a suite's struct (or the
  /// line above it) and passes the struct's name to `-only-testing`; nested suites come along.
  @Tag static var smoke: Self
}
