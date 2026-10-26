#if os(macOS)
import Sparkle
import SwiftUI

/// Sparkle's updater for the Mac app. It checks the feed in Info.plist (`SUFeedURL`, written by
/// Scripts/release.sh) once a day, and asks before installing; Atelier ▸ Check for Updates… checks
/// now. Debug builds don't start it, so runs from Xcode and scripted checks never offer to replace
/// themselves with a release.
@MainActor
@Observable
final class Updater {
  #if DEBUG
    private static let starts = false
  #else
    private static let starts = true
  #endif
  @ObservationIgnored private let controller = SPUStandardUpdaterController(
    startingUpdater: starts, updaterDelegate: nil, userDriverDelegate: nil)
  @ObservationIgnored private var observation: NSKeyValueObservation?
  /// False while a check is already under way.
  private(set) var canCheckForUpdates = false

  init() {
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] updater, _ in
      let canCheck = updater.canCheckForUpdates
      Task { @MainActor in self?.canCheckForUpdates = canCheck }
    }
  }

  func checkForUpdates() {
    controller.updater.checkForUpdates()
  }
}

/// Atelier ▸ Check for Updates…, under About.
struct UpdateCommands: Commands {
  let updater: Updater

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") { updater.checkForUpdates() }
        .disabled(!updater.canCheckForUpdates)
    }
  }
}
#endif
