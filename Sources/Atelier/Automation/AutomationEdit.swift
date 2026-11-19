#if os(macOS)
import Foundation

extension Automation {
  /// Checks the Edit screen end to end (Slice J fills it).
  ///
  ///   Atelier --edit-screen-check --project NAME [--quit]
  static func editScreenCheck(_: CreateModel) {
    print("FAIL --edit-screen-check is not implemented yet")
    fflush(stdout)
    if CommandLine.arguments.contains("--quit") { AppLifecycle.quit() }
  }
}
#endif
