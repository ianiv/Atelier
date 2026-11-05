import CoreGraphics
import CryptoKit
import Foundation
import Observation

/// A style as a server offers it. Its thumbnail comes separately, by hash, so a device downloads
/// each image once however often the list is refreshed.
nonisolated struct RemoteStyle: Codable, Hashable, Identifiable, Sendable {
  var style: Style
  var thumbnailHash: String?
  /// The model its thumbnail was made with, which Open in Create needs there to be.
  var thumbnailModel: String?

  var id: UUID { style.id }
}

/// The styles of each paired server, kept on disk so they stay usable while it's offline:
///
///     <folder>/<server>/styles.json
///     <folder>/<server>/<thumbnail hash>.jpg
///
/// They're read-only here. A style in use is only a template to write the prompt into, so it runs the
/// same wherever the job does; to change one, copy it to this device. A server's list never touches
/// this device's own styles.
@MainActor
@Observable
final class RemoteStyleLibrary {
  private let folder: URL
  private(set) var styles: [UUID: [RemoteStyle]] = [:]
  /// Thumbnails read so far, by hash.
  private(set) var thumbnails: [String: CGImage] = [:]
  private var isLoaded = false

  init(folder: URL = RemotePaths.root.appending(path: "ServerStyles", directoryHint: .isDirectory)) {
    self.folder = folder
  }

  private func serverFolder(_ server: UUID) -> URL {
    folder.appending(path: server.uuidString, directoryHint: .isDirectory)
  }

  private func listURL(_ server: UUID) -> URL { serverFolder(server).appending(path: "styles.json") }

  private func thumbnailURL(_ server: UUID, _ hash: String) -> URL { serverFolder(server).appending(path: "\(hash).jpg") }

  /// What earlier visits to each server left.
  func loadIfNeeded() {
    guard !isLoaded else { return }
    isLoaded = true
    let servers = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    for directory in servers {
      guard let server = UUID(uuidString: directory.lastPathComponent),
            let data = try? Data(contentsOf: listURL(server)),
            let list = try? JSONDecoder().decode([RemoteStyle].self, from: data)
      else { continue }
      styles[server] = list
    }
  }

  func styles(of server: UUID) -> [RemoteStyle] {
    loadIfNeeded()
    return styles[server] ?? []
  }

  /// Every server's styles, for looking one up.
  var all: [RemoteStyle] {
    loadIfNeeded()
    return styles.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { styles[$0] ?? [] }
  }

  func style(id: UUID?) -> Style? {
    guard let id else { return nil }
    return all.first { $0.id == id }?.style
  }

  /// The server a style came from.
  func server(ofStyle id: UUID) -> UUID? {
    loadIfNeeded()
    return styles.first { $0.value.contains { $0.id == id } }?.key
  }

  /// Takes on `list` as the server's styles, removing thumbnails nothing uses any more.
  func update(_ list: [RemoteStyle], server: UUID) {
    loadIfNeeded()
    styles[server] = list
    let directory = serverFolder(server)
    Log.attempt(Log.remote, "Keeping a server's styles") {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(list).write(to: listURL(server), options: .atomic)
    }
    let used = Set(list.compactMap(\.thumbnailHash))
    for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
      where file.pathExtension == "jpg" && !used.contains(file.deletingPathExtension().lastPathComponent)
    {
      try? FileManager.default.removeItem(at: file)
    }
  }

  /// Asks the server for its list. Offline, what's here stays.
  func refresh(server: UUID, backend: RemoteBackend) async {
    guard let list = try? await backend.styles() else { return }
    update(list, server: server)
  }

  /// Forgets a server that's been removed.
  func remove(server: UUID) {
    loadIfNeeded()
    styles[server] = nil
    try? FileManager.default.removeItem(at: serverFolder(server))
  }

  /// A style's thumbnail: from memory, from disk, or from the server, which is kept. Nil if it has
  /// none, or the server's away and it was never fetched.
  func thumbnail(of style: RemoteStyle, server: UUID, backend: RemoteBackend) async -> CGImage? {
    guard let hash = style.thumbnailHash else { return nil }
    if let image = thumbnails[hash] { return image }
    let url = thumbnailURL(server, hash)
    if let image = ImageLoader.image(at: url) {
      thumbnails[hash] = image
      return image
    }
    guard let data = try? await backend.styleThumbnail(style.id), RemoteBlob(data).hash == hash,
          let image = ImageLoader.image(from: data)
    else { return nil }
    try? FileManager.default.createDirectory(at: serverFolder(server), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
    thumbnails[hash] = image
    return image
  }
}
