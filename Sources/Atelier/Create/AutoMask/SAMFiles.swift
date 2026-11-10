import Foundation

/// Apple's Core ML conversion of Meta's SAM 2.1 (huggingface.co/apple/coreml-sam2.1-*, Apache-2.0),
/// in a "SAM 2.1" folder of the models directory, one folder per size. Each size is three
/// `.mlpackage` folders: the image encoder (run once per image), the prompt encoder and the mask
/// decoder (run per click). Packages are compiled once into the caches folder (`compiled`).
nonisolated struct SAMFiles: Sendable {
  enum Size: String, CaseIterable, Codable, Sendable {
    case tiny, small, large

    var title: String {
      switch self {
      case .tiny: "Tiny"
      case .small: "Small"
      case .large: "Large"
      }
    }

    /// The Hugging Face repository.
    var repository: String { "apple/coreml-sam2.1-\(rawValue)" }

    /// The commit downloaded, so the files listed and fetched never mix two versions.
    var revision: String {
      switch self {
      case .tiny: "39ae0a8a83e5e6cd196e804bf7cccc5f8171f306"
      case .small: "883f5787eb0be35ce6965907a8bc1f5320a5a02e"
      case .large: "e830c0874326be7ada2bdc9dff23b7073f884a83"
      }
    }

    /// Every file of the three packages at `revision`, in bytes: for the Download button before
    /// the listing is fetched.
    var bytes: Int64 {
      switch self {
      case .tiny: 79_644_968
      case .small: 93_893_011
      case .large: 457_300_992
      }
    }

    /// The packages' file names start with this (`SAM2_1SmallImageEncoderFLOAT16.mlpackage`).
    var packagePrefix: String { "SAM2_1\(title)" }
  }

  enum Part: String, CaseIterable, Sendable {
    case imageEncoder = "ImageEncoder"
    case promptEncoder = "PromptEncoder"
    case maskDecoder = "MaskDecoder"
  }

  enum Failure: LocalizedError {
    case missing

    var errorDescription: String? { "SAM 2.1 isn't downloaded." }
  }

  static let folderName = "SAM 2.1"
  /// The listing a finished download writes: each file's path in the size's folder and size. A
  /// download stopped partway leaves none, so the size doesn't count as installed.
  static let listingName = "files.json"

  struct ListedFile: Codable, Sendable, Equatable {
    var path: String
    var size: Int64
  }

  let root: URL
  let size: Size

  func package(_ part: Part) -> URL {
    root.appending(path: "\(size.packagePrefix)\(part.rawValue)FLOAT16.mlpackage", directoryHint: .isDirectory)
  }

  /// Where `part` is kept compiled. Keyed by revision, so a newer download compiles again.
  func compiled(_ part: Part) -> URL {
    URL.cachesDirectory.appending(
      path: "Atelier/\(Self.folderName)/\(size.revision)/\(size.packagePrefix)\(part.rawValue).mlmodelc",
      directoryHint: .isDirectory)
  }

  /// The models folders that can be read now (`AppSettings.availableModelsDirectories`): the
  /// main one, then the additional ones; an unmounted drive's is left out.
  static var modelFolders: [URL] {
    AppSettings.availableModelsDirectories(primary: AppSettings.modelsDirectory, additional: AppSettings.additionalModelsDirectories)
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  /// A models folder's SAM folder for `size`.
  static func folder(_ size: Size, in modelsFolder: URL) -> URL {
    modelsFolder.appending(path: folderName, directoryHint: .isDirectory).appending(path: size.title, directoryHint: .isDirectory)
  }

  /// Where a download of SAM goes, nil when no folder can take it (`downloadFolder(primary:...)`).
  static var downloadFolder: URL? {
    downloadFolder(primary: AppSettings.modelsDirectory, additional: AppSettings.additionalModelsDirectories)
  }

  /// The models folder SAM downloads into: one that already has a SAM folder; else the main
  /// models folder; else the first additional one, leaving out folders inside another app's
  /// container (Draw Things' own models folder, added to read its models, isn't Atelier's to
  /// write in). Only folders that are there now and writable, so one on an unmounted drive is
  /// skipped, never made; except the default models folder (~/Documents/Models), which Atelier
  /// makes on first use, so it's taken while missing when the folder it goes in is there.
  static func downloadFolder(
    primary: String, additional: [String], defaultPrimary: String = AppSettings.defaultModelsDirectory,
    ownBundleID: String? = Bundle.main.bundleIdentifier, ownHome: String = NSHomeDirectory(),
    isReachable: (String) -> Bool = FolderBookmarks.isReachable
  ) -> URL? {
    let manager = FileManager.default
    func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    // The default folder, not made yet: usable when its parent is there and writable.
    let makesDefault = !primary.isEmpty && key(primary) == key(defaultPrimary) && !manager.fileExists(atPath: primary)
      && manager.isWritableFile(atPath: URL(fileURLWithPath: primary).deletingLastPathComponent().path)
    var seen = Set<String>()
    let usable = ([primary] + additional).enumerated().filter { index, path in
      guard !path.isEmpty, seen.insert(key(path)).inserted else { return false }
      if index == 0, makesDefault { return true }
      return isReachable(path) && manager.isWritableFile(atPath: path)
        && !isInOtherAppsContainer(path, ownBundleID: ownBundleID, ownHome: ownHome)
    }.map(\.element)
    let chosen = usable.first { manager.fileExists(atPath: URL(fileURLWithPath: $0).appending(path: folderName).path) }
      ?? usable.first
    return chosen.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  /// Whether `path` is inside another app's sandbox container, which Atelier may read from but
  /// shouldn't fill with its own files: on the Mac `~/Library/Containers/<bundle id>` or
  /// `Group Containers/<id>` other than Atelier's own; on iPad another app's
  /// `Containers/Data/Application/<UUID>` or `Containers/Shared/AppGroup/<UUID>` (Atelier's own is
  /// its home folder). Symlinks resolved (`/var` is `/private/var`), compared ignoring case as the
  /// file system does.
  static func isInOtherAppsContainer(_ path: String, ownBundleID: String?, ownHome: String = NSHomeDirectory()) -> Bool {
    func components(_ path: String) -> [String] {
      var parts = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
      // `/private/var` and `/var` are one folder; resolving only strips `/private` from paths
      // that exist.
      if parts.count > 2, parts[1] == "private", ["var", "tmp", "etc"].contains(parts[2]) { parts.remove(at: 1) }
      return parts
    }
    let parts = components(path)
    for index in parts.indices.dropFirst() where parts[index - 1] == "library" {
      guard parts[index] == "containers" || parts[index] == "group containers", index + 1 < parts.count else { continue }
      return parts[index + 1] != ownBundleID?.lowercased()
    }
    for index in parts.indices where parts[index] == "containers" && index + 3 < parts.count {
      let kind = (parts[index + 1], parts[index + 2])
      guard kind == ("data", "application") || kind == ("shared", "appgroup") else { continue }
      let container = Array(parts[...(index + 3)])
      let home = components(ownHome)
      return !(home.count >= container.count && Array(home[..<container.count]) == container)
    }
    return false
  }

  /// The size, in the first models folder where its download finished and every file it listed is
  /// still there at its size.
  static func installed(_ size: Size, in folders: [URL] = modelFolders) -> SAMFiles? {
    folders.lazy.compactMap { installed(size, root: folder(size, in: $0)) }.first
  }

  private static func installed(_ size: Size, root: URL) -> SAMFiles? {
    guard let data = try? Data(contentsOf: root.appending(path: listingName)),
          let files = try? JSONDecoder().decode([ListedFile].self, from: data), !files.isEmpty
    else { return nil }
    let manager = FileManager.default
    for file in files {
      let size = (try? manager.attributesOfItem(atPath: root.appending(path: file.path).path)[.size] as? Int64) ?? nil
      guard size == file.size else { return nil }
    }
    let installed = SAMFiles(root: root, size: size)
    guard Part.allCases.allSatisfy({ manager.fileExists(atPath: installed.package($0).path) }) else { return nil }
    return installed
  }

  /// The repository's file listing at the pinned revision (the Hugging Face API's tree).
  static func listingURL(_ size: Size) -> URL {
    URL(string: "https://huggingface.co/api/models/\(size.repository)/tree/\(size.revision)?recursive=true")!
  }

  static func source(_ size: Size, path: String) -> URL {
    let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    return URL(string: "https://huggingface.co/\(size.repository)/resolve/\(size.revision)/\(escaped)")!
  }

  /// The files a listing names inside the three packages (everything else, like the README, is
  /// left out). Each package is a folder, so every file in it is needed, the
  /// `Data/com.apple.CoreML/model.mlmodel` spec among them.
  static func packageFiles(inListing data: Data) throws -> [ListedFile] {
    struct Entry: Decodable {
      var type: String
      var path: String
      var size: Int64?
    }
    return try JSONDecoder().decode([Entry].self, from: data)
      .filter { $0.type == "file" && $0.path.contains(".mlpackage/") }
      .map { ListedFile(path: $0.path, size: $0.size ?? 0) }
  }
}
