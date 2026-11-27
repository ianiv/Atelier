import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One item on the clipboard as the moodboard's Paste reads it: what it says it is, the file it
/// stands for (a file copied in Finder), and its data. Kept apart from the pasteboard so reading
/// it can be tested without one, and so it can be decoded off the main actor.
nonisolated struct ClipboardItem: Sendable {
  var types: [UTType]
  var fileURL: URL?
  /// The item's data as its first image or audio type (`PastedMedia.payloadType`), read only for
  /// an item that isn't a file: a copied file's data is its Finder icon.
  var data: Data?
}

/// What Paste in the moodboard column adds: images go on the board, audio fills the Audio box
/// (for the video models that take it), as dropping them there does.
nonisolated enum PastedMedia: Sendable {
  case image(CGImage)
  /// A copy of the audio, under the temporary exports, so nothing depends on the clipboard's
  /// file; `AudioClip.set` copies it in and the copy is removed afterwards.
  case audio(URL, name: String)

  enum Kind: Sendable {
    case image, audio
  }

  /// What Paste brought: the media in clipboard order, plus what it left out, for the status bar.
  struct Batch: Sendable {
    var media: [PastedMedia] = []
    /// Items that weren't images or audio, or whose data couldn't be read.
    var failed = 0
    /// Audio left out because the selected model takes none.
    var audioLeftOut = 0
    /// Audio after the first, which `load` doesn't copy: the Audio box holds one file.
    var moreAudio = 0
  }

  /// What a type is to the moodboard. Movies are audiovisual, not audio, so they're nothing here
  /// (the moodboard takes stills; videos go on the canvas).
  static func kind(of type: UTType?) -> Kind? {
    guard let type else { return nil }
    if type.conforms(to: .image) { return .image }
    if type.conforms(to: .audio) { return .audio }
    return nil
  }

  /// What an item is. A file's own type wins over the item's data types: Finder puts the file's
  /// icon on the clipboard as a TIFF too, which isn't what was copied.
  static func kind(types: [UTType], fileURL: URL?) -> Kind? {
    if let fileURL { return kind(of: UTType(filenameExtension: fileURL.pathExtension)) }
    return types.lazy.compactMap(kind(of:)).first
  }

  /// The type to read an item's data as: for an image, PNG or TIFF (which every app that copies
  /// an image offers and ImageIO always reads), else the first image type ImageIO decodes, since
  /// an app may offer one it can't (SVG, a private format) first; for audio, its first audio type.
  /// `takesAudio` false leaves audio unread.
  static func payloadType(_ types: [UTType], takesAudio: Bool = true) -> UTType? {
    switch kind(types: types, fileURL: nil) {
    case .image:
      if let common = [UTType.png, .tiff].first(where: types.contains) { return common }
      let decodable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
      return types.first { $0.conforms(to: .image) && decodable.contains($0.identifier) }
    case .audio:
      return takesAudio ? types.first { $0.conforms(to: .audio) } : nil
    case nil:
      return nil
    }
  }

  /// Reads the clipboard's items: images decoded (through ImageIO's thumbnail API, never at full
  /// size) to the moodboard's size, the first audio copied. Off the main actor, since a large
  /// photo takes a while to decode.
  @concurrent static func load(_ items: [ClipboardItem], takesAudio: Bool) async -> Batch {
    var batch = Batch()
    var hasAudio = false
    for item in items {
      let found: Found? =
        if let url = item.fileURL { withAccess(to: url) { file(url) } } else { data(item) }
      switch found {
      case .image(let image):
        batch.media.append(.image(image))
      case .audio(let copy):
        if !takesAudio {
          batch.audioLeftOut += 1
        } else if hasAudio {
          batch.moreAudio += 1
        } else if let audio = copy() {
          batch.media.append(audio)
          hasAudio = true
        } else {
          batch.failed += 1
        }
      case nil:
        batch.failed += 1
      }
    }
    return batch
  }

  /// What an item turned out to be; audio is copied only when it's used.
  private enum Found {
    case image(CGImage)
    case audio(() -> PastedMedia?)
  }

  /// A copied file, by its extension first, then by its contents: a file with no extension, or
  /// the wrong one, is still what the system detected when the button was enabled
  /// (`Clipboard.pastableKinds` reads the detected type, not the name).
  private static func file(_ url: URL) -> Found? {
    // A movie is never moodboard material, though AVFoundation may read its sound.
    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true,
       UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == false
    {
      return nil
    }
    let named = kind(types: [], fileURL: url)
    if named != .audio, let image = ImageLoader.image(at: url, maxSide: Moodboard.maxSide) { return .image(image) }
    guard named == .audio || (try? AVAudioFile(forReading: url)) != nil else { return nil }
    return .audio {
      withAccess(to: url) {
        let copy = newCopy(extension: url.pathExtension)
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else {
          try? FileManager.default.removeItem(at: copy)
          return nil
        }
        return .audio(copy, name: url.lastPathComponent)
      }
    }
  }

  private static func data(_ item: ClipboardItem) -> Found? {
    switch kind(types: item.types, fileURL: nil) {
    case .image:
      return item.data.flatMap { ImageLoader.image(from: $0, maxSide: Moodboard.maxSide) }.map(Found.image)
    case .audio:
      return .audio { item.data.flatMap { audio($0, type: payloadType(item.types)) } }
    case nil:
      return nil
    }
  }

  /// Audio data written to a file of its type, as `AudioClip` keeps a file.
  static func audio(_ data: Data, type: UTType?) -> PastedMedia? {
    let fileExtension = type?.preferredFilenameExtension ?? "wav"
    let copy = newCopy(extension: fileExtension)
    guard (try? data.write(to: copy)) != nil else {
      try? FileManager.default.removeItem(at: copy)
      return nil
    }
    return .audio(copy, name: "Pasted Audio.\(fileExtension)")
  }

  /// A pasted file may be outside what Atelier can read on its own (an iPad's Files).
  private static func withAccess<T>(to url: URL, _ body: () -> T?) -> T? {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    return body()
  }

  /// Audio copies go in a folder of their own among the temporary exports (emptied at launch and
  /// quit), so ones a paste never handed over can be found.
  static var copies: URL {
    TemporaryFiles.folder(.exports).appending(path: "Pasted", directoryHint: .isDirectory)
  }

  static func newCopy(extension fileExtension: String) -> URL {
    try? FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
    return copies.appending(path: UUID().uuidString).appendingPathExtension(fileExtension)
  }

  /// Removes the audio copies Paste made, and any older ones left behind: iPadOS's PasteButton
  /// hands over nothing when one item fails, so copies its other items made are never seen.
  static func removeCopies(_ media: [PastedMedia]) {
    for case .audio(let url, _) in media {
      try? FileManager.default.removeItem(at: url)
    }
    let fileManager = FileManager.default
    for file in (try? fileManager.contentsOfDirectory(at: copies, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      // A paste still being read has made its copies seconds ago.
      if let modified, Date().timeIntervalSince(modified) > 10 * 60 { try? fileManager.removeItem(at: file) }
    }
  }
}

/// iPadOS's `PasteButton` reads the clipboard through Transferable, without asking "Allow Paste?".
/// A file comes first: its data alone would lose its name, and for audio its type.
nonisolated extension PastedMedia: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .audio) { received in
      // The received file goes when this returns.
      let copy = PastedMedia.newCopy(extension: received.file.pathExtension)
      do {
        try FileManager.default.copyItem(at: received.file, to: copy)
      } catch {
        try? FileManager.default.removeItem(at: copy)
        throw error
      }
      return PastedMedia.audio(copy, name: received.file.lastPathComponent)
    }
    FileRepresentation(importedContentType: .image) { received in
      try PastedMedia.image(PastedImage.image(at: received.file))
    }
    DataRepresentation(importedContentType: .image) { data in
      try PastedMedia.image(PastedImage.image(from: data))
    }
    // By type, so the file gets an extension AVFoundation reads it by.
    DataRepresentation(importedContentType: .wav) { try audio($0, as: .wav) }
    DataRepresentation(importedContentType: .mp3) { try audio($0, as: .mp3) }
    DataRepresentation(importedContentType: .mpeg4Audio) { try audio($0, as: .mpeg4Audio) }
    DataRepresentation(importedContentType: .aiff) { try audio($0, as: .aiff) }
  }

  private static func audio(_ data: Data, as type: UTType) throws -> PastedMedia {
    guard let audio = audio(data, type: type) else { throw CocoaError(.fileWriteUnknown) }
    return audio
  }
}

/// Only the images, for `PasteButton` when the selected model takes no audio, so audio alone
/// on the clipboard leaves it disabled. Decoded to the moodboard's size, unlike `DroppedImage`.
nonisolated struct PastedImage: Transferable {
  var image: CGImage

  static func image(at url: URL) throws -> CGImage {
    guard let image = ImageLoader.image(at: url, maxSide: Moodboard.maxSide) else { throw ProjectError.badImage }
    return image
  }

  static func image(from data: Data) throws -> CGImage {
    guard let image = ImageLoader.image(from: data, maxSide: Moodboard.maxSide) else { throw ProjectError.badImage }
    return image
  }

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in PastedImage(image: try image(at: received.file)) }
    DataRepresentation(importedContentType: .image) { data in PastedImage(image: try image(from: data)) }
  }
}

/// Paste in the moodboard column's header: the clipboard's images join the board, and its audio
/// fills the Audio box when the model takes audio. Disabled, not hidden, when there's nothing
/// it can use.
struct MoodboardPasteButton: View {
  @Environment(CreateModel.self) private var model
  #if os(macOS)
    /// What's on the clipboard, by type alone (`Clipboard.pastableKinds`).
    @State private var kinds: Set<PastedMedia.Kind> = []
  #endif

  var body: some View {
    let takesAudio = model.videoModel?.takesAudio == true
    let help = takesAudio ? "Add the images and audio on the clipboard" : "Add the images on the clipboard"
    #if os(macOS)
      Button("Paste", systemImage: "doc.on.clipboard") { paste(takesAudio: takesAudio) }
        .disabled(!kinds.contains(.image) && !(takesAudio && kinds.contains(.audio)))
        .help(help)
        .task {
          // The Mac has no notice of the clipboard changing; its change count is cheap to read
          // and reading it shows nothing to the user, unlike reading what's on it.
          var seen: Int?
          while !Task.isCancelled {
            let count = Clipboard.changeCount
            if count != seen {
              seen = count
              kinds = await Clipboard.pastableKinds()
            }
            try? await Task.sleep(for: .seconds(1))
          }
        }
    #else
      // The system's button enables itself for what's on the clipboard, and reading it from the
      // button needs no "Allow Paste?".
      Group {
        if takesAudio {
          PasteButton(payloadType: PastedMedia.self) { media in
            Task { @MainActor in
              model.pasteIntoMoodboard(PastedMedia.Batch(media: media))
            }
          }
        } else {
          PasteButton(payloadType: PastedImage.self) { images in
            Task { @MainActor in
              model.pasteIntoMoodboard(PastedMedia.Batch(media: images.map { .image($0.image) }))
            }
          }
        }
      }
      .help(help)
    #endif
  }

  #if os(macOS)
    private func paste(takesAudio: Bool) {
      let items = Clipboard.items(takesAudio: takesAudio)
      Task { model.pasteIntoMoodboard(await PastedMedia.load(items, takesAudio: takesAudio)) }
    }
  #endif
}
