import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Style thumbnails: square JPEGs in Application Support, one per style id, made from a generated
/// image, the Create canvas or an image file.
extension StyleStore {
  static var thumbnailsDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier/StyleThumbnails", isDirectory: true)
  }

  /// Pixels on a side: sharp in the editor at 2x.
  static let thumbnailSize = 384

  private static func thumbnailURL(_ id: UUID) -> URL {
    thumbnailsDirectory.appendingPathComponent(id.uuidString + ".jpg")
  }

  /// The style's thumbnail, once `loadThumbnail` has read it.
  func thumbnail(_ id: UUID) -> CGImage? {
    thumbnails[id] ?? nil
  }

  /// Reads the style's thumbnail from disk the first time it's shown.
  func loadThumbnail(_ id: UUID) async {
    guard thumbnails[id] == nil else { return }
    let url = Self.thumbnailURL(id)
    let image = await Task.detached {
      CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }.value
    thumbnails[id] = .some(image)
  }

  /// Sets the style's thumbnail from `image`, cropped to its centre square; nil removes it.
  func setThumbnail(_ image: CGImage?, for id: UUID) {
    let url = Self.thumbnailURL(id)
    guard let image, let square = Self.square(image, side: Self.thumbnailSize) else {
      thumbnails[id] = .some(nil)
      if persists { try? FileManager.default.removeItem(at: url) }
      return
    }
    thumbnails[id] = .some(square)
    guard persists else { return }
    try? FileManager.default.createDirectory(at: Self.thumbnailsDirectory, withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    CGImageDestinationFinalize(destination)
  }

  /// Sets the thumbnail from an image file (security-scoped access is the caller's).
  func setThumbnail(contentsOf url: URL, for id: UUID) -> Bool {
    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailSize * 4,
    ] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    else { return false }
    setThumbnail(image, for: id)
    return true
  }

  /// Why thumbnails can't be made now, or nil when they can.
  func thumbnailBlocker(_ create: CreateModel) -> String? {
    if create.selectedModel == nil || create.settings == nil || create.isLoadingModel {
      return "Pick a model on Create first."
    }
    if create.videoModel != nil { return "Pick an image model on Create: thumbnails are images." }
    if thumbnailSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a subject first." }
    return nil
  }

  /// Generates a thumbnail for each style, one after another in the queue, with the model and
  /// settings on Create and one seed, so the styles compare like for like. The subject goes into
  /// each style's `{{SUBJECT}}` (its `{{SETTING}}` is left empty). The images also save to the
  /// project, like any other run.
  func makeThumbnails(for chosen: [Style], create: CreateModel) {
    guard thumbnailRun == nil, !chosen.isEmpty, thumbnailBlocker(create) == nil,
          let model = create.selectedModel, let settings = create.settings
    else { return }
    let subject = thumbnailSubject
    let seed = create.seed
    thumbnailRun = (0, chosen.count, 0, chosen[0].name)
    thumbnailTask = Task { [weak self] in
      for style in chosen {
        guard let self, !Task.isCancelled else { break }
        thumbnailRun?.current = style.name
        let prompts = style.apply(prompt: subject, negativePrompt: "", setting: "")
        let request = GenerationEngine.Request(
          model: model, prompt: prompts.prompt, negativePrompt: prompts.negativePrompt, seed: seed,
          configuration: settings)
        var made = false
        if let item = try? await create.generate(forAgent: request, styleThumbnail: style.name, progress: { _ in }),
           let image = await create.history.image(tensorId: item.tensorId, in: create.history.project.name)
        {
          setThumbnail(image, for: style.id)
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
