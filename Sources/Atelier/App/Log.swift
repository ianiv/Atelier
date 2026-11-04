import Foundation
import os

/// The app's logs, one category per area; read them in Console or with `log stream --predicate
/// 'subsystem == "<bundle id>"'`. For failures nothing else reports, such as a file that couldn't
/// be written. Errors are public so they're readable outside a debugger.
nonisolated enum Log {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "Atelier"

  static let history = Logger(subsystem: subsystem, category: "history")
  static let project = Logger(subsystem: subsystem, category: "project")
  static let styles = Logger(subsystem: subsystem, category: "styles")
  static let queue = Logger(subsystem: subsystem, category: "queue")
  static let library = Logger(subsystem: subsystem, category: "library")
  static let agents = Logger(subsystem: subsystem, category: "agents")
  static let engine = Logger(subsystem: subsystem, category: "engine")
  static let export = Logger(subsystem: subsystem, category: "export")
  static let create = Logger(subsystem: subsystem, category: "create")
  static let inspector = Logger(subsystem: subsystem, category: "inspector")
  static let remote = Logger(subsystem: subsystem, category: "remote")

  /// Runs `body`, logging its error as what failed. Returns the error for callers that also tell
  /// the user; `@discardableResult` for the rest.
  @discardableResult
  static func attempt(_ logger: Logger, _ what: String, _ body: () throws -> Void) -> Error? {
    do {
      try body()
      return nil
    } catch {
      logger.error("\(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      return error
    }
  }
}
