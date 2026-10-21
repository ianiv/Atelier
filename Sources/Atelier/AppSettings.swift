import Foundation

/// User-facing settings persisted in UserDefaults.
enum AppSettings {
  static let defaultModelsDirectory = "/Volumes/External 2TB/DrawThings/Models"
  private static let modelsDirectoryKey = "modelsDirectory"

  /// Models directory: the saved setting, else `DRAWTHINGS_MODELS_DIR`, else the default volume.
  static var modelsDirectory: String {
    get {
      if let saved = UserDefaults.standard.string(forKey: modelsDirectoryKey), !saved.isEmpty {
        return saved
      }
      if let env = ProcessInfo.processInfo.environment["DRAWTHINGS_MODELS_DIR"], !env.isEmpty {
        return env
      }
      return defaultModelsDirectory
    }
    set {
      UserDefaults.standard.set(newValue, forKey: modelsDirectoryKey)
    }
  }

  /// Root of the history folder: one subfolder per day.
  static var historyDirectory: URL {
    FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier", isDirectory: true)
  }
}
