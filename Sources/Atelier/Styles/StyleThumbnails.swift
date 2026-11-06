import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How a thumbnail was made, kept with its full-size image so Open in Create can bring both back.
nonisolated struct ThumbnailSource: Codable, Sendable {
  var prompt: String
  var negativePrompt: String
  var model: String?
  var seed: UInt32?
  /// The settings in the history dump format (`JSONValue.fields(of:)`).
  var settings: [String: JSONValue]

  init(prompt: String, negativePrompt: String, model: String?, seed: UInt32?, settings: [String: JSONValue]) {
    self.prompt = prompt
    self.negativePrompt = negativePrompt
    self.model = model
    self.seed = seed
    self.settings = settings
  }

  init(_ settings: ImageMetadata.Settings) {
    self.init(
      prompt: settings.prompt, negativePrompt: settings.negativePrompt, model: settings.pasted.model,
      seed: settings.pasted.seed, settings: settings.pasted.dump)
  }

  var metadata: ImageMetadata.Settings {
    ImageMetadata.Settings(
      prompt: prompt, negativePrompt: negativePrompt,
      pasted: DrawThingsJSON.Pasted(dump: settings, model: model, seed: seed))
  }
}

/// Style thumbnails: square JPEGs in Application Support, one per style id, made from a generated
/// image, the Create canvas or an image file. When it's known how the image was made, the
/// full-size image and its settings are kept beside it (`<id>-full.png`, `<id>.json`).
extension StyleStore {
  /// Where a scripted run (which doesn't save the user's styles) writes thumbnails instead.
  @MainActor static var scratchThumbnailsDirectory: URL?

  /// Thumbnails are written to disk: always, except in a scripted run without a scratch folder.
  private var writesThumbnails: Bool { persists || Self.scratchThumbnailsDirectory != nil }

  /// Pixels on a side: sharp in the editor at 2x.
  static let thumbnailSize = 384

  /// A style's thumbnail lives with its library.
  private func thumbnailsFolder(ofStyle id: UUID) -> URL {
    Self.scratchThumbnailsDirectory ?? thumbnailsFolder(ofLibrary: library(ofStyle: id)?.id ?? currentLibraryID)
  }

  private func thumbnailURL(_ id: UUID) -> URL {
    thumbnailsFolder(ofStyle: id).appendingPathComponent(id.uuidString + ".jpg")
  }

  private func fullImageURL(_ id: UUID) -> URL {
    thumbnailsFolder(ofStyle: id).appendingPathComponent(id.uuidString + "-full.png")
  }

  private func sourceURL(_ id: UUID) -> URL {
    thumbnailsFolder(ofStyle: id).appendingPathComponent(id.uuidString + ".json")
  }

  /// What follows a style's id in the names of its thumbnail, full image and settings.
  private static let thumbnailSuffixes = [".jpg", "-full.png", ".json"]

  /// Moves a style's thumbnail files between libraries' folders, while the style is still in `from`.
  func moveThumbnailFiles(_ id: UUID, from: UUID, to: UUID) {
    guard persists, Self.scratchThumbnailsDirectory == nil else { return }
    let fileManager = FileManager.default
    let destination = thumbnailsFolder(ofLibrary: to)
    try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    for suffix in Self.thumbnailSuffixes {
      let file = id.uuidString + suffix
      let source = thumbnailsFolder(ofLibrary: from).appendingPathComponent(file)
      guard fileManager.fileExists(atPath: source.path) else { continue }
      Log.attempt(Log.styles, "Moving a style's thumbnail") {
        try fileManager.moveItem(at: source, to: destination.appendingPathComponent(file))
      }
    }
  }

  /// Copies a style's thumbnail files to a new style's name in a library's folder.
  func copyThumbnailFiles(_ id: UUID, to newID: UUID, inLibrary library: UUID) {
    thumbnails[newID] = thumbnails[id]
    guard writesThumbnails else { return }
    let fileManager = FileManager.default
    let destination = Self.scratchThumbnailsDirectory ?? thumbnailsFolder(ofLibrary: library)
    try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    let folder = thumbnailsFolder(ofStyle: id)
    for suffix in Self.thumbnailSuffixes {
      let source = folder.appendingPathComponent(id.uuidString + suffix)
      guard fileManager.fileExists(atPath: source.path) else { continue }
      Log.attempt(Log.styles, "Copying a style's thumbnail") {
        try fileManager.copyItem(at: source, to: destination.appendingPathComponent(newID.uuidString + suffix))
      }
    }
  }

  /// Removes the thumbnails, full images and settings in `folder` of styles that aren't in `ids`.
  /// Their names start with the style's id; any other file stays.
  static func removeOrphanedThumbnails(in folder: URL, keeping ids: Set<UUID>) {
    let fileManager = FileManager.default
    for file in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
      guard let id = UUID(uuidString: String(file.prefix(36))), !ids.contains(id) else { continue }
      try? fileManager.removeItem(at: folder.appendingPathComponent(file))
    }
  }

  /// The style's thumbnail as JPEG, for a library file.
  func thumbnailJPEG(_ id: UUID) -> Data? {
    if let data = try? Data(contentsOf: thumbnailURL(id)) { return data }
    // A scripted run keeps thumbnails in memory only.
    let data = NSMutableData()
    guard let image = thumbnails[id] ?? nil,
          let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  /// Sets a thumbnail from image file data (a library file's).
  func setThumbnail(data: Data, for id: UUID) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return }
    setThumbnail(image, for: id)
  }

  /// A thumbnail from a photo picked in the photo library, with any settings it carries, like
  /// `setThumbnail(contentsOf:for:)`.
  func setThumbnail(photo data: Data, for id: UUID) {
    guard let image = ImageLoader.image(from: data) else { return }
    let settings = ImageMetadata.embedded(in: data).flatMap(ImageMetadata.settings(from:))
    setThumbnail(image, for: id, source: settings.map(ThumbnailSource.init))
  }

  /// Whether the style's thumbnail can be opened in Create (its image and settings are kept).
  func canOpenThumbnail(_ id: UUID) -> Bool {
    // Read again when the thumbnail changes.
    _ = thumbnails[id]
    return FileManager.default.fileExists(atPath: sourceURL(id).path)
  }

  /// The full-size image and settings of the style's thumbnail.
  /// The model a style's thumbnail was made with, without reading its image.
  func thumbnailModel(_ id: UUID) -> String? {
    (try? Data(contentsOf: sourceURL(id))).flatMap { try? JSONDecoder().decode(ThumbnailSource.self, from: $0) }?.model
  }

  func thumbnailSource(_ id: UUID) -> (image: CGImage, source: ThumbnailSource)? {
    guard let data = try? Data(contentsOf: sourceURL(id)),
          let source = try? JSONDecoder().decode(ThumbnailSource.self, from: data),
          let image = ImageLoader.image(at: fullImageURL(id))
    else { return nil }
    return (image, source)
  }

  /// The image the style's thumbnail was cut from, full size, else the thumbnail itself (a
  /// library's, or one made before full images were kept for every thumbnail).
  func fullThumbnailImage(_ id: UUID) async -> CGImage? {
    let urls = [fullImageURL(id), thumbnailURL(id)]
    let image = await Self.firstImage(at: urls)
    return image ?? thumbnail(id)
  }

  @concurrent private nonisolated static func firstImage(at urls: [URL]) async -> CGImage? {
    urls.lazy.compactMap { ImageLoader.image(at: $0) }.first
  }

  /// The style's thumbnail, once `loadThumbnail` has read it.
  func thumbnail(_ id: UUID) -> CGImage? {
    thumbnails[id] ?? nil
  }

  /// Reads the style's thumbnail from disk the first time it's shown.
  func loadThumbnail(_ id: UUID) async {
    guard thumbnails[id] == nil else { return }
    let url = thumbnailURL(id)
    let image = await Self.image(at: url)
    thumbnails[id] = .some(image)
  }

  @concurrent private nonisolated static func image(at url: URL) async -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
  }

  /// Sets the style's thumbnail from `image`, cropped to its centre square; nil removes it. With
  /// `source`, the full image and how it was made are kept for Open in Create.
  func setThumbnail(_ image: CGImage?, for id: UUID, source: ThumbnailSource? = nil) {
    let url = thumbnailURL(id)
    if writesThumbnails {
      for file in [fullImageURL(id), sourceURL(id)] { try? FileManager.default.removeItem(at: file) }
    }
    guard let image, let square = Self.square(image, side: Self.thumbnailSize) else {
      thumbnails[id] = .some(nil)
      if writesThumbnails { try? FileManager.default.removeItem(at: url) }
      return
    }
    guard writesThumbnails else {
      thumbnails[id] = .some(square)
      return
    }
    try? FileManager.default.createDirectory(at: thumbnailsFolder(ofStyle: id), withIntermediateDirectories: true)
    // The full image is kept for the viewer whenever the square is cut from more (not a library's
    // own thumbnail), and with its settings for Open in Create.
    let cropped = image.width != square.width || image.height != square.height
    if source != nil || cropped, let png = ImageTensor.png(image) {
      Log.attempt(Log.styles, "Saving a thumbnail's full image") {
        try png.write(to: fullImageURL(id), options: .atomic)
      }
      if let source, let json = try? JSONEncoder().encode(source) {
        Log.attempt(Log.styles, "Saving a thumbnail's settings") {
          try json.write(to: sourceURL(id), options: .atomic)
        }
      }
    }
    // Set after the files, so views reading `canOpenThumbnail` see them.
    defer { thumbnails[id] = .some(square) }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      thumbnailNotSaved()
      return
    }
    CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    if !CGImageDestinationFinalize(destination) { thumbnailNotSaved() }
  }

  private func thumbnailNotSaved() {
    Log.styles.error("Couldn't write a style's thumbnail")
    reportFailure?("Couldn't save the style's thumbnail.")
  }

  /// Sets the thumbnail from an image file (security-scoped access is the caller's), keeping its
  /// generation settings when it carries them.
  func setThumbnail(contentsOf url: URL, for id: UUID) -> Bool {
    guard let image = ImageLoader.image(at: url) else { return false }
    let settings = ImageMetadata.embedded(at: url).flatMap(ImageMetadata.settings(from:))
    setThumbnail(image, for: id, source: settings.map(ThumbnailSource.init))
    return true
  }

  /// Why thumbnails of `chosen` can't be made now, or nil when they can. An empty subject is
  /// fine when every one of them has a `{{SUBJECT:default}}` to use instead.
  func thumbnailBlocker(_ create: CreateModel, for chosen: [Style]) -> String? {
    if create.selectedModel == nil || create.settings == nil || create.isLoadingModel {
      return "Pick a model on Create first."
    }
    if create.videoModel != nil { return "Pick an image model on Create: thumbnails are images." }
    if (thumbnailValues[Style.subject] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       !chosen.allSatisfy({ $0.defaults[Style.subject] != nil })
    {
      return "Write a subject first."
    }
    return nil
  }

  /// Generates a thumbnail for each style, one after another in the queue, with the model and
  /// settings on Create and one seed, so the styles compare like for like. Each style's tags take
  /// `thumbnailValues` (an empty one is dropped). Create's negative prompt, canvas and moodboard
  /// aren't used. The images aren't saved to the project.
  func makeThumbnails(for chosen: [Style], create: CreateModel) {
    guard thumbnailRun == nil, !chosen.isEmpty, thumbnailBlocker(create, for: chosen) == nil,
          let model = create.selectedModel, let settings = create.settings
    else { return }
    let values = thumbnailValues
    let seed = create.seed
    var used = settings
    used.seed = seed
    let dump = JSONValue.fields(of: used)
    thumbnailRun = (0, chosen.count, 0, chosen[0].name)
    thumbnailTask = Task { [weak self] in
      for style in chosen {
        guard let self, !Task.isCancelled else { break }
        thumbnailRun?.current = style.name
        let prompts = style.apply(values, negativePrompt: "")
        let request = GenerationEngine.Request(
          model: model, prompt: prompts.prompt, negativePrompt: prompts.negativePrompt, seed: seed,
          configuration: settings)
        var made = false
        if let image = try? await create.generateStyleThumbnail(request, style: style.name) {
          let source = ThumbnailSource(
            prompt: prompts.prompt, negativePrompt: prompts.negativePrompt, model: model, seed: seed,
            settings: dump)
          setThumbnail(image, for: style.id, source: source)
          made = true
        }
        thumbnailRun?.done += 1
        if !made { thumbnailRun?.failed += 1 }
      }
      self?.thumbnailRun = nil
      self?.thumbnailTask = nil
    }
  }

  /// Stops making thumbnails; the running one is cancelled, the ones made are kept.
  func stopThumbnails() {
    thumbnailTask?.cancel()
  }

  private static func square(_ image: CGImage, side: Int) -> CGImage? {
    let crop = min(image.width, image.height)
    guard crop > 0,
          let cropped = image.cropping(to: CGRect(
            x: (image.width - crop) / 2, y: (image.height - crop) / 2, width: crop, height: crop)),
          let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()
  }
}
