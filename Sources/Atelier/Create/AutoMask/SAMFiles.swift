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

  /// The models directory's SAM folder.
  static var folder: URL { URL(fileURLWithPath: AppSettings.modelsDirectory).appending(path: folderName) }

  static func folder(_ size: Size) -> URL { folder.appending(path: size.title, directoryHint: .isDirectory) }

  /// The size, when its download finished and every file it listed is still there at its size.
  static func installed(_ size: Size) -> SAMFiles? {
    let root = folder(size)
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
