import CoreGraphics
import SwiftUI

/// What a drag on the canvas does. On iPad the Pencil always paints (or erases, with Eraser) and
/// fingers always move and zoom, as in Draw Things; on the Mac a drag paints with Brush or Eraser
/// and Space-drag moves.
enum CanvasTool: String, CaseIterable, Identifiable {
  case move, brush, eraser

  var id: Self { self }

  var title: String {
    switch self {
    case .move: "Move"
    case .brush: "Brush"
    case .eraser: "Eraser"
    }
  }

  var systemImage: String {
    switch self {
    case .move: "hand.raised"
    case .brush: "paintbrush.pointed"
    case .eraser: "eraser"
    }
  }
}

// MARK: - Refining from the Create screen

/// Everything that changes the canvas mask, the frame's region and Merge into Image, for the
/// canvas's own tools and for callers without the view (agents, scripted checks). Each mask
/// change is one undo step on the window's undo manager, as a brush stroke is.
extension CreateModel {
  /// The undo action name for mask changes an agent makes.
  static let agentMaskActionName = "Agent Mask"

  /// The mask tools apply: an image (not a clip or a run's preview) is on the canvas as the input
  /// of an Edit run, for an image model, with no layout editor over it. Strength needn't be below
  /// 100%: painting is what makes Edit mean something then (`canEdit`).
  var canPaintMask: Bool {
    canEditMask && runTargetTakesMasks
  }

  /// A mask on the canvas can be changed without painting more (Invert, Clear), whatever the run
  /// target takes: a mask an older server can't use can still be cleared.
  var canEditMask: Bool {
    canvasShowsImage && canvasMode == .edit && videoModel == nil && layout == nil
  }

  /// Whether the next Edit run from the screen would send a mask, wherever it runs: something
  /// painted inside the frame where the canvas isn't empty (`CanvasMask.frameMask`). Rasterized
  /// once per mask and placement.
  var screenFrameHasPaint: Bool {
    guard effectiveCanvasMode == .edit, videoModel == nil, let mask = canvasMask, mask.mayHavePaint,
          let image, let placement = canvasPlacement
    else { return false }
    let key = "\(mask.hashValue) \(ObjectIdentifier(image)) \(placement.imageRect) \(placement.frameSize)"
    if let cached = frameMaskCache, cached.key == key { return cached.hasPaint }
    let rendered = CanvasState.render(image, placement: placement)
    let hasPaint = mask.frameMask(placement, canvas: rendered) != nil
    frameMaskCache = (key, hasPaint)
    return hasPaint
  }

  /// Where runs go can inpaint with a mask: this device, or a server new enough to list it
  /// (`RemoteProtocol.maskFeature`). An older one would regenerate the whole frame, so jobs with a
  /// mask are refused there (`RemoteBackend.submit`).
  var runTargetTakesMasks: Bool {
    runTarget == .local || serverCatalog?.features.contains(RemoteProtocol.maskFeature) == true
  }

  /// The output size: the frame on the canvas.
  var frameSize: CGSize? {
    guard let settings, settings.width > 0, settings.height > 0 else { return nil }
    return CGSize(width: settings.width, height: settings.height)
  }

  /// Where the canvas image lies in the frame now.
  var canvasPlacement: CanvasPlacement? {
    guard canvasShowsImage, let image, let frameSize else { return nil }
    return CanvasPlacement(
      sourceSize: CGSize(width: image.width, height: image.height), frameSize: frameSize, scale: canvas.scale,
      offset: canvas.offset)
  }

  /// Whether Merge into Image would do anything for the next run: Edit on an image model with the
  /// frame showing part of the image, reaching past it, or with a mask painted.
  var canMergeIntoImage: Bool {
    guard effectiveCanvasMode == .edit, videoModel == nil, let canvasPlacement else { return false }
    // As `setRefineInputs` decides for the request Generate would queue. The placement alone
    // settles it while panning or zooming, without rasterizing the mask for each new frame.
    if RefineMerge.applies(placement: canvasPlacement, scale: canvas.scale, offset: canvas.offset, hasMask: false) {
      return true
    }
    return runTargetTakesMasks && screenFrameHasPaint
  }

  // MARK: Mask

  /// Adds strokes or shapes (in the canvas image's pixels, from its top left), each painting or
  /// erasing as it says. False when there's no image to paint on.
  @discardableResult
  func addMaskStrokes(_ strokes: [CanvasMask.Stroke], actionName: String = "Paint Mask", undoManager: UndoManager?) -> Bool {
    // Inverting an existing mask paints nothing new, so it's allowed where painting isn't.
    let invertsOnly = canvasMask != nil && strokes.allSatisfy { $0.kind == .invert }
    guard invertsOnly ? canEditMask : canPaintMask, !strokes.isEmpty else { return false }
    var mask = canvasMask ?? CanvasMask()
    mask.strokes += strokes
    setMask(mask, actionName: actionName, undoManager: undoManager)
    return true
  }

  /// Adds (or with `erases`, subtracts) a mask image the size of the canvas image: painted where
  /// it's light.
  @discardableResult
  func addMaskImage(_ image: CGImage, erases: Bool = false, actionName: String = "Add Mask Image", undoManager: UndoManager?)
    -> Bool
  {
    guard let stroke = CanvasMask.Stroke.bitmap(image, erases: erases) else { return false }
    return addMaskStrokes([stroke], actionName: actionName, undoManager: undoManager)
  }

  /// Flips what's painted, over the whole image.
  @discardableResult
  func invertMask(actionName: String = "Invert Mask", undoManager: UndoManager?) -> Bool {
    addMaskStrokes([.invert], actionName: actionName, undoManager: undoManager)
  }

  func clearMask(actionName: String = "Clear Mask", undoManager: UndoManager?) {
    guard canvasMask != nil, canEditMask else { return }
    setMask(nil, actionName: actionName, undoManager: undoManager)
  }

  /// Replaces the mask as one undo step. Undoing does nothing once another image is on the canvas.
  func setMask(_ mask: CanvasMask?, actionName: String, undoManager: UndoManager?) {
    let previous = canvasMask
    canvasMask = mask
    guard let undoManager, let image else { return }
    let imageID = ObjectIdentifier(image)
    undoManager.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        guard target.image.map(ObjectIdentifier.init) == imageID else { return }
        target.setMask(previous, actionName: actionName, undoManager: undoManager)
      }
    }
    undoManager.setActionName(actionName)
  }

  // MARK: Frame

  /// Zooms and moves the canvas so the frame shows `region` of the canvas image (its pixels, from
  /// the top left), fitted and centered. Returns the region the frame actually shows, which is
  /// larger or smaller when the zoom needed is beyond the canvas's range (`CanvasState.range`),
  /// and differs in shape when the frame's does; nil without an image.
  @discardableResult
  func showRegion(_ region: CGRect) -> CGRect? {
    guard canvasShowsImage, let image, let frameSize, region.width > 0, region.height > 0 else { return nil }
    let sourceSize = CGSize(width: image.width, height: image.height)
    let wanted = CanvasPlacement.zoomAndOffset(showing: region, sourceSize: sourceSize, frameSize: frameSize)
    let scale = min(max(wanted.scale, CanvasState.range.lowerBound), CanvasState.range.upperBound)
    canvas.scale = scale
    canvas.offset = CanvasPlacement.offset(centering: CGPoint(x: region.midX, y: region.midY), scale: scale, sourceSize: sourceSize)
    return canvasPlacement?.cropRect
  }

  // MARK: Placing an image

  /// Puts an image on the canvas as the input of the next Edit run, with no mask.
  func placeOnCanvas(_ image: CGImage) {
    setCanvasImage(image)
  }

  // MARK: Looking at the mask

  /// The canvas image with the mask tinted red, the frame outlined and what's outside the image
  /// hatched (`CanvasMask.overlay`).
  func canvasMaskOverlay(maxSide: Int = 2048) -> CGImage? {
    guard canvasShowsImage, let image else { return nil }
    return CanvasMask.overlay(source: image, mask: canvasMask, placement: canvasPlacement, maxSide: maxSide)
  }

  /// How much is painted, where, and how much of what the frame shows.
  var canvasMaskStats: CanvasMask.Stats? {
    guard canvasShowsImage, let image else { return nil }
    return (canvasMask ?? CanvasMask()).stats(sourceSize: CGSize(width: image.width, height: image.height), placement: canvasPlacement)
  }

  /// Lands a merged result: the frame keeps showing the region it refined (the image may have
  /// grown, moving it).
  func keepRefinePlacement(merge: RefineMerge, sourceOrigin: CGPoint, resultSize: CGSize) {
    let placement = merge.placement
    let zoom = placement.zoom
    let crop = placement.cropRect
    let center = CGPoint(x: crop.midX + sourceOrigin.x, y: crop.midY + sourceOrigin.y)
    let scale = (zoom.x + zoom.y) / 2
    canvas.scale = scale
    canvas.offset = CGSize(
      width: (resultSize.width / 2 - center.x) * scale, height: (resultSize.height / 2 - center.y) * scale)
  }
}

// MARK: - Overlay and statistics

extension CanvasMask {
  struct Stats: Sendable {
    /// Painted pixels, and their share of the image.
    var paintedPixels: Int
    var paintedFraction: Double
    /// The painted pixels' bounding box, image pixels from the top left; nil when none are.
    var bounds: CGRect?
    /// The share of the image pixels the frame shows that are painted; nil without a frame.
    var frameFraction: Double?
  }

  func stats(sourceSize: CGSize, placement: CanvasPlacement?) -> Stats {
    let width = Int(sourceSize.width), height = Int(sourceSize.height)
    let coverage = coverage(width: width, height: height)
    var count = 0
    var minX = width, minY = height, maxX = -1, maxY = -1
    var inFrame = 0, frameTotal = 0
    let crop = placement?.cropRect.intersection(CGRect(origin: .zero, size: sourceSize))
    for y in 0..<height {
      for x in 0..<width {
        let painted = coverage[y * width + x] != 0
        if painted {
          count += 1
          minX = min(minX, x)
          minY = min(minY, y)
          maxX = max(maxX, x)
          maxY = max(maxY, y)
        }
        if let crop, !crop.isNull, crop.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
          frameTotal += 1
          if painted { inFrame += 1 }
        }
      }
    }
    return Stats(
      paintedPixels: count, paintedFraction: width * height > 0 ? Double(count) / Double(width * height) : 0,
      bounds: count > 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil,
      frameFraction: placement == nil ? nil : frameTotal > 0 ? Double(inFrame) / Double(frameTotal) : 0)
  }

  /// The mask as an opaque image the size of the canvas image, white where painted and black
  /// elsewhere: the form agents pass to `set_canvas_mask`, so one read back can be sent again.
  func image(sourceSize: CGSize) -> CGImage? {
    let width = Int(sourceSize.width), height = Int(sourceSize.height)
    guard width > 0, height > 0,
          let provider = CGDataProvider(data: Data(coverage(width: width, height: height)) as CFData)
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// The mask as a red tint for the canvas, `alpha` where painted, at most `maxSide` pixels on its
  /// long side (it's drawn over the image at the image's size).
  func tint(sourceSize: CGSize, maxSide: Int = 1024, alpha: Double = 0.45) -> CGImage? {
    let scale = min(1, Double(maxSide) / max(sourceSize.width, sourceSize.height))
    let width = max(Int((sourceSize.width * scale).rounded()), 1)
    let height = max(Int((sourceSize.height * scale).rounded()), 1)
    let coverage = coverage(width: width, height: height, scale: (Double(width) / sourceSize.width, Double(height) / sourceSize.height))
    guard coverage.contains(255) else { return nil }
    let a = UInt8(alpha * 255)
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for index in coverage.indices where coverage[index] != 0 {
      // Premultiplied red.
      rgba[index * 4] = a
      rgba[index * 4 + 3] = a
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// A picture of a refine run's inputs: `source` with what `mask` paints tinted red at about
  /// half strength, the frame (`placement`) outlined, and wherever the frame reaches past the
  /// image hatched. Scaled down to `maxSide` pixels on its long side.
  static func overlay(source: CGImage, mask: CanvasMask?, placement: CanvasPlacement?, maxSide: Int = 2048) -> CGImage? {
    let sourceRect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
    let crop = placement?.cropRect
    let bounds = (crop.map { sourceRect.union($0) } ?? sourceRect).integral
    let scale = min(1, Double(maxSide) / max(bounds.width, bounds.height))
    let width = max(Int((bounds.width * scale).rounded()), 1), height = max(Int((bounds.height * scale).rounded()), 1)
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // Image pixels counting down from the bounds' top left.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    func drawUpright(_ image: CGImage, in rect: CGRect) {
      context.saveGState()
      context.translateBy(x: rect.minX, y: rect.maxY)
      context.scaleBy(x: 1, y: -1)
      context.draw(image, in: CGRect(origin: .zero, size: rect.size))
      context.restoreGState()
    }
    // Outside the image: gray hatching.
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(bounds)
    context.setStrokeColor(gray: 0.75, alpha: 1)
    context.setLineWidth(max(2 / scale, 1))
    let step = max(16 / scale, 8)
    var x = bounds.minX - bounds.height
    while x < bounds.maxX {
      context.move(to: CGPoint(x: x, y: bounds.maxY))
      context.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
      x += step
    }
    context.strokePath()
    context.interpolationQuality = .high
    drawUpright(source, in: sourceRect)
    if let mask, let tint = mask.tint(sourceSize: sourceRect.size, maxSide: max(width, height), alpha: 0.5) {
      context.interpolationQuality = .none
      drawUpright(tint, in: sourceRect)
    }
    if let crop {
      context.setStrokeColor(red: 1, green: 0.85, blue: 0, alpha: 1)
      context.setLineWidth(max(3 / scale, 1))
      context.stroke(crop.insetBy(dx: 1.5 / scale, dy: 1.5 / scale))
    }
    return context.makeImage()
  }
}

// MARK: - Controls

/// Move / Brush / Eraser, the brush size, Clear Mask and Invert Mask, in the status bar beside the
/// zoom controls. Always there; disabled when there's nothing to paint on.
struct CanvasToolControls: View {
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager

  private static let sizes: [Double] = [8, 16, 32, 64, 128, 256]

  var body: some View {
    @Bindable var model = model
    // Painting needs a target that takes masks; changing a mask that's there doesn't.
    let paints = model.canPaintMask
    let edits = model.canEditMask
    HStack(spacing: 2) {
      Picker("Canvas Tool", selection: $model.canvasTool) {
        ForEach(CanvasTool.allCases) { tool in
          Label(tool.title, systemImage: tool.systemImage).tag(tool)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .help(Self.toolHelp)
      .disabled(!paints)
      Menu {
        ForEach(Self.sizes, id: \.self) { size in
          Button("\(Int(size)) px") { model.brushSize = size }
        }
      } label: {
        Text("\(Int(model.brushSize)) px").monospacedDigit().frame(minWidth: 44).touchTarget()
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Brush Size, in frame pixels")
      .disabled(!paints)
      Button {
        model.invertMask(undoManager: undoManager)
      } label: {
        Label("Invert Mask", systemImage: "circle.lefthalf.filled").touchTarget()
      }
      .help("Invert Mask")
      // Inverting nothing paints everything, which needs a target that takes masks.
      .disabled(!edits || (model.canvasMask == nil && !paints))
      Button {
        model.clearMask(undoManager: undoManager)
      } label: {
        Label("Clear Mask", systemImage: "xmark.circle").touchTarget()
      }
      .disabled(!edits || model.canvasMask == nil)
      .help("Clear Mask")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    MergeIntoImageToggle()
  }

  private static var toolHelp: String {
    #if os(iOS)
      "Paint the area to regenerate with Apple Pencil: Brush paints, Eraser erases. Fingers move and zoom."
    #else
      "Move drags the image; Brush and Eraser paint the area to regenerate. Hold Space to drag the image while painting."
    #endif
  }
}

/// Merge into Image, in the status bar with the canvas tools: always there, enabled when it would
/// do something (`canMergeIntoImage`).
struct MergeIntoImageToggle: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    @Bindable var model = model
    Toggle(isOn: $model.mergeIntoImage) {
      Label("Merge into Image", systemImage: "square.on.square.dashed").touchTarget()
    }
    .toggleStyle(.button)
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .disabled(!model.canMergeIntoImage)
    .help(
      "Put the result back into the whole image, through the mask when one is painted. The image grows when the frame reaches past it. Off saves just what's in the frame.")
  }
}
