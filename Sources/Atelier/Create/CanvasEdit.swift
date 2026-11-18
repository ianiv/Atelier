import CoreGraphics
import Foundation

/// What an Edit run takes from the canvas, as a value on its own: the image, where it lies in the
/// frame, its mask, paint and finer layers, whether the result merges back into it, and the
/// reference images that go with it. The Create screen fills one from what it shows
/// (`CreateModel.screenRequest`); a caller that edits an image without putting it on the canvas
/// fills one from its own inputs. Either way the request is built by the same code
/// (`GenerationEngine.Request.apply`), so both make the same run.
nonisolated struct CanvasEdit: @unchecked Sendable {
  /// The image being edited, at its own resolution.
  var source: CGImage
  /// The project step `source` is exactly, if any: the result follows it.
  var sourceTensorId: Int64?
  /// `source` came from outside the project (saved as an Imported step).
  var isImported = false
  /// The canvas zoom (frame pixels per image pixel; nil fits the image to the frame) and offset
  /// (the image's centre from the frame's, frame pixels, y down), as `CanvasState` has them.
  var scale: Double?
  var offset: CGSize = .zero
  /// The mask in `source`'s pixels; nil regenerates the whole frame.
  var mask: CanvasMask?
  /// Colours painted over `source`, an input of the run only (`RefineInputs.make`).
  var paint: CanvasPaint?
  /// The source step's finer layers (`Project.detailLayers`).
  var detail: [Project.DetailLayer] = []
  /// Put the result back into `source` (`RefineMerge`), where that changes anything.
  var merge = false
  /// Reference images sent with the run, for models that read them.
  var moodboard: [GenerationEngine.Reference] = []

  /// The run's Edit inputs for a frame of `frame` (the output size) at these Mask Blur settings,
  /// as `GenerationEngine.Request.setRefineInputs` works them out; nil when the image couldn't be
  /// drawn. Apart from the request, so it can be checked without one.
  func refineInputs(frame: CGSize, maskBlur: Double, maskBlurOutset: Int) -> RefineInputs? {
    RefineInputs.make(
      source: source, sourceTensorId: sourceTensorId, isImported: isImported, scale: scale, offset: offset, frame: frame,
      mask: mask, merge: merge, detail: detail, paint: paint, maskBlur: maskBlur, maskBlurOutset: maskBlurOutset)
  }
}

extension GenerationEngine.Request {
  /// Sets the request's Edit inputs and references from `edit`, as `setRefineInputs` does from
  /// its arguments (at the request's output size and Mask Blur). False when the image couldn't be
  /// drawn; the references are set either way.
  @discardableResult
  mutating func apply(_ edit: CanvasEdit) -> Bool {
    moodboard = edit.moodboard
    guard let inputs = edit.refineInputs(
      frame: CGSize(width: configuration.width, height: configuration.height), maskBlur: Double(configuration.maskBlur),
      maskBlurOutset: configuration.maskBlurOutset)
    else { return false }
    setRefineInputs(inputs, isImported: edit.isImported)
    return true
  }
}
