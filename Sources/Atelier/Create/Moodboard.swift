import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One reference image on the moodboard. Weight 0 keeps it on the board but leaves it out of the
/// next run, as the engine does.
struct MoodboardItem: Identifiable {
  var id = UUID()
  var image: CGImage
  var weight: Float = 1
}

/// The moodboard, kept across launches as PNGs plus an index in
/// ~/Library/Application Support/Atelier/Moodboard/.
@MainActor
@Observable
final class Moodboard {
  private(set) var items: [MoodboardItem] = []

  /// Reference images are scaled down to this long side: the engine resizes references to about
  /// the output's pixel count anyway, and full-size photos would bloat project files.
  static let maxSide = 1536

  private struct Entry: Codable {
    var id: UUID
    var weight: Float
  }

  private static var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Atelier/Moodboard", directoryHint: .isDirectory)
  }

  init() {
    guard SessionState.isEnabled,
      let data = try? Data(contentsOf: Self.folder.appending(path: "index.json")),
      let entries = try? JSONDecoder().decode([Entry].self, from: data)
    else { return }
    items = entries.compactMap { entry in
      ImageLoader.image(at: Self.folder.appending(path: "\(entry.id).png"), maxSide: Self.maxSide)
        .map { MoodboardItem(id: entry.id, image: $0, weight: entry.weight) }
    }
  }

  func add(_ image: CGImage) {
    items.append(MoodboardItem(image: ImageLoader.fitted(image, maxSide: Self.maxSide)))
    save(writing: items.last)
  }

  /// Puts an image at `index` (the front, for MiniMax H3 FL2VA's last frame).
  func insert(_ image: CGImage, at index: Int) {
    let item = MoodboardItem(image: ImageLoader.fitted(image, maxSide: Self.maxSide))
    items.insert(item, at: min(max(index, 0), items.count))
    save(writing: item)
  }

  func remove(_ id: MoodboardItem.ID) {
    items.removeAll { $0.id == id }
    try? FileManager.default.removeItem(at: Self.folder.appending(path: "\(id).png"))
    save()
  }

  func removeAll() {
    for item in items {
      try? FileManager.default.removeItem(at: Self.folder.appending(path: "\(item.id).png"))
    }
    items = []
    save()
  }

  func setWeight(_ weight: Float, for id: MoodboardItem.ID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].weight = min(max(weight, 0), 1)
    save()
  }

  /// Replaces the board, e.g. with a history step's moodboard.
  func replace(with references: [(image: CGImage, weight: Float)]) {
    removeAll()
    for reference in references {
      items.append(MoodboardItem(image: reference.image, weight: reference.weight))
      save(writing: items.last)
    }
  }

  /// The images the next run sends: weight above zero, in order.
  var references: [GenerationEngine.Reference] {
    items.filter { $0.weight > 0 }.map { .init(image: $0.image, weight: $0.weight) }
  }

  private func save(writing item: MoodboardItem? = nil) {
    guard SessionState.isEnabled else { return }
    let folder = Self.folder
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let item, let png = ImageTensor.png(item.image) {
      try? png.write(to: folder.appending(path: "\(item.id).png"))
    }
    let entries = items.map { Entry(id: $0.id, weight: $0.weight) }
    if let data = try? JSONEncoder().encode(entries) {
      try? data.write(to: folder.appending(path: "index.json"))
    }
  }
}

/// Reads images from files and pasteboard data, applying EXIF orientation.
enum ImageLoader {
  static func image(at url: URL, maxSide: Int? = nil) -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { image(from: $0, maxSide: maxSide) }
  }

  static func image(from data: Data, maxSide: Int? = nil) -> CGImage? {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap { image(from: $0, maxSide: maxSide) }
  }

  private static func image(from source: CGImageSource, maxSide: Int?) -> CGImage? {
    guard CGImageSourceGetCount(source) > 0 else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let side = max(width, height)
    // The thumbnail API is the one that applies the orientation; at full size it's lossless.
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(side > 0 ? side : 16384, maxSide ?? .max),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// `image` scaled down so its long side is at most `maxSide`.
  static func fitted(_ image: CGImage, maxSide: Int) -> CGImage {
    let side = max(image.width, image.height)
    guard side > maxSide else { return image }
    let scale = Double(maxSide) / Double(side)
    let width = max(Int((Double(image.width) * scale).rounded()), 1)
    let height = max(Int((Double(image.height) * scale).rounded()), 1)
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
  }
}

/// An image dropped from Finder, another app, or Atelier's own thumbnails (which export PNG).
struct DroppedImage: Transferable {
  var image: CGImage
  /// Generation settings the file carries.
  var metadata: ImageMetadata.Embedded?

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      guard let image = ImageLoader.image(at: received.file) else { throw ProjectError.badImage }
      return DroppedImage(image: image, metadata: ImageMetadata.embedded(at: received.file))
    }
    DataRepresentation(importedContentType: .image) { data in
      guard let image = ImageLoader.image(from: data) else { throw ProjectError.badImage }
      return DroppedImage(image: image, metadata: ImageMetadata.embedded(in: data))
    }
  }
}

extension CanvasState {
  /// The canvas frame as the next Edit run sees it: `size` pixels with `image` placed by the
  /// canvas zoom and offset, transparent where it doesn't reach (the engine inpaints there).
  func render(_ image: CGImage, size: CGSize) -> CGImage? {
    let width = Int(size.width), height = Int(size.height)
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let fit = min(size.width / Double(image.width), size.height / Double(image.height))
    let zoom = scale ?? fit
    let drawn = CGSize(width: Double(image.width) * zoom, height: Double(image.height) * zoom)
    // Core Graphics counts y upward; the canvas offset counts it downward. `integral` grows the
    // rect to whole pixels, so an image that covers the frame leaves no transparent sliver.
    let rect = CGRect(
      x: size.width / 2 + offset.width - drawn.width / 2,
      y: size.height / 2 - offset.height - drawn.height / 2,
      width: drawn.width, height: drawn.height
    ).integral
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    return context.makeImage()
  }
}

/// The moodboard column along the canvas's right edge: reference images with their weights.
struct MoodboardColumn: View {
  @Environment(CreateModel.self) private var model
  @AppStorage("moodboardShown") private var shown = true
  @State private var isTargeted = false

  private static let thumbnail: CGFloat = 72

  /// What the column holds for the selected model: H3 FL2VA takes the last frame from it, H3
  /// Ref2VA numbered pictures.
  private var title: String {
    let video = model.videoModel
    if video?.takesLastFrame == true { return "Last Frame" }
    if video?.takesReferences == true { return "References" }
    return "Moodboard"
  }

  var body: some View {
    let moodboard = model.moodboard
    let video = model.videoModel
    VStack(spacing: 8) {
      HStack(spacing: 4) {
        if shown {
          Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("Add Images…", systemImage: "plus") { model.imageImport = .moodboard }
            .help("Add reference images")
        }
        Button(shown ? "Hide Moodboard" : "Show Moodboard", systemImage: "square.stack") {
          shown.toggle()
        }
        .help(shown ? "Hide the moodboard" : "Show the moodboard (\(moodboard.items.count))")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      if shown {
        if video?.takesAudio == true {
          AudioClipChip(width: Self.thumbnail)
          Divider()
        }
        if moodboard.items.isEmpty {
          Text(video?.takesLastFrame == true ? "Drop the last frame here" : "Drop reference images here")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(width: Self.thumbnail, height: Self.thumbnail * 1.5)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        } else {
          ScrollView {
            VStack(spacing: 10) {
              ForEach(moodboard.items) { item in
                MoodboardThumbnail(item: item, size: Self.thumbnail, role: role(of: item))
              }
            }
          }
          .scrollIndicators(.never)
          .frame(width: Self.thumbnail)
        }
        if !model.usesReferences {
          Text("Not used by this model")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(width: Self.thumbnail)
        }
      }
    }
    .padding(8)
    .fixedSize(horizontal: true, vertical: false)
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
    .overlay {
      if isTargeted {
        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
      }
    }
    .dropDestination(for: DroppedImage.self) { images, _ in
      for image in images { moodboard.add(image.image) }
      shown = true
      return !images.isEmpty
    } isTargeted: { isTargeted = $0 }
  }

  /// How the selected video model reads an image: H3 FL2VA's last frame is the first image it
  /// gets, H3 Ref2VA calls the canvas (in Edit) Picture 1 and the moodboard images the ones after.
  private func role(of item: MoodboardItem) -> String? {
    guard let video = model.videoModel else { return nil }
    let sent = model.moodboard.items.filter { $0.weight > 0 }
    guard let index = sent.firstIndex(where: { $0.id == item.id }) else { return nil }
    if video.takesLastFrame { return index == 0 ? "Last frame" : "Not used" }
    if video.takesReferences {
      let canvas = model.effectiveCanvasMode == .edit && model.image != nil && model.canvasClip == nil
      return "Picture \(index + (canvas ? 2 : 1))"
    }
    return nil
  }
}

private struct MoodboardThumbnail: View {
  @Environment(CreateModel.self) private var model
  let item: MoodboardItem
  let size: CGFloat
  /// What the selected video model makes of it, e.g. "Picture 2".
  var role: String?
  @State private var hovering = false
  @State private var editing = false

  var body: some View {
    let moodboard = model.moodboard
    VStack(spacing: 2) {
      Image(decorative: item.image, scale: 1)
        .resizable()
        .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 6))
        .opacity(item.weight > 0 ? 1 : 0.35)
        .overlay(alignment: .topTrailing) {
          if hovering {
            Button("Remove", systemImage: "xmark.circle.fill") { moodboard.remove(item.id) }
              .labelStyle(.iconOnly)
              .buttonStyle(.plain)
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, .black.opacity(0.6))
              .padding(3)
              .help("Remove from the moodboard")
          }
        }
        .contentShape(.rect)
        .onTapGesture { editing = true }
        .onHover { hovering = $0 }
      Text(
        [role, Double(item.weight).formatted(.percent.precision(.fractionLength(0)))]
          .compactMap { $0 }.joined(separator: " · ")
      )
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .help("Click to set its weight. 0% leaves it out of the next image.")
    .popover(isPresented: $editing, arrowEdge: .leading) {
      MoodboardWeightEditor(item: item)
    }
    .debugPresents(item.id == moodboard.items.first?.id ? "moodboardWeight" : "", $editing)
    .contextMenu {
      Button("Show on Canvas") { model.setCanvasImage(item.image) }
      Button("Remove") { moodboard.remove(item.id) }
      Divider()
      Button("Clear Moodboard") { moodboard.removeAll() }
    }
  }
}

private struct MoodboardWeightEditor: View {
  @Environment(CreateModel.self) private var model
  let item: MoodboardItem

  var body: some View {
    let moodboard = model.moodboard
    let weight = Binding(
      get: { Double(moodboard.items.first { $0.id == item.id }?.weight ?? item.weight) },
      set: { moodboard.setWeight(Float($0), for: item.id) })
    VStack(alignment: .leading, spacing: 10) {
      Image(decorative: item.image, scale: 1)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 260, maxHeight: 260)
        .clipShape(.rect(cornerRadius: 6))
      HStack {
        Text("Weight")
        Slider(value: weight, in: 0...1)
          .frame(width: 140)
        TextField("Weight", value: weight, format: .percent.precision(.fractionLength(0)))
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 52)
      }
      Text("0% leaves the image out. For edit models such as FLUX.2 and Kontext, any weight above 0% counts the same.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding()
  }
}
