#if os(macOS)
@preconcurrency import _MediaGenerationKit
import CoreGraphics
import Foundation

/// What `edit_image` is asked to do, read from its arguments with nothing else to hand: no image,
/// model or screen. So the reading (which fields go together, each message) is checked on its own
/// (`CanvasEditArgumentsTests`); what needs the image's size or the model is checked by the tool.
nonisolated struct CanvasEditArguments: Sendable {
  /// Where an image comes from: a file or data: URL, or a step of the current project.
  enum Source: Equatable, Sendable {
    case image(String)
    case historyStep(Int)
  }

  struct Reference: Equatable, Sendable {
    var source: Source
    var weight: Float
  }

  /// `mask.select`: what `auto_mask` takes, on the image being edited.
  struct Selection: Equatable, Sendable {
    var points: [SAMSegmenter.Point] = []
    var box: CGRect?
    var subject = false
    var size: SAMFiles.Size?
  }

  /// The mask, built in this order: the shapes, the image and the selection together, then grown
  /// (or shrunk), then inverted.
  struct Mask: Sendable {
    var shapes: [CanvasMask.Stroke] = []
    var image: String?
    var select: Selection?
    var grow = 0
    var invert = false
  }

  struct Paint: Sendable {
    var shapes: [CanvasPaint.Stroke] = []
    var fillMask = false
    var color: CanvasPaint.Color?
  }

  var source: Source
  var prompt: String
  /// The part of the image the frame shows; nil is the whole image.
  var region: CGRect?
  var width: Int?
  var height: Int?
  var scale: Double?
  var mask: Mask?
  var paint: Paint?
  var references: [Reference] = []
  var merge = true

  typealias ToolError = AgentTools.ToolError

  static func parse(_ arguments: [String: Any]) throws -> CanvasEditArguments {
    if arguments["input_image"] != nil {
      throw ToolError("edit_image takes its image as `image` (a path or data: URL) or `history_step`, not input_image.")
    }
    if arguments["use_canvas"] != nil {
      throw ToolError("edit_image doesn't read the canvas: pass `image` or `history_step`. To run what's on the canvas, call generate with use_canvas.")
    }
    let path = arguments["image"] as? String
    let step = AgentTools.int(arguments["history_step"])
    guard (path == nil) != (step == nil), arguments["image"] == nil || path != nil, arguments["history_step"] == nil || step != nil else {
      throw ToolError("Pass `image` or `history_step`, only one.")
    }
    guard let prompt = arguments["prompt"] as? String else { throw ToolError("`prompt` is required (it can be empty).") }
    var parsed = CanvasEditArguments(source: path.map(Source.image) ?? .historyStep(step ?? 0), prompt: prompt)

    if let value = arguments["region"] { parsed.region = try AgentTools.rect(value, named: "region") }
    parsed.width = AgentTools.int(arguments["width"])
    parsed.height = AgentTools.int(arguments["height"])
    if parsed.width != nil || parsed.height != nil, arguments["scale"] != nil {
      throw ToolError("Pass `width` and `height`, or `scale`, not both.")
    }
    guard (parsed.width == nil) == (parsed.height == nil), (parsed.width ?? 1) > 0, (parsed.height ?? 1) > 0 else {
      throw ToolError("Pass `width` and `height` together, both above 0.")
    }
    if let value = arguments["scale"] {
      guard !AgentTools.isBoolean(value), let scale = AgentTools.double(value), CanvasState.range.contains(scale) else {
        throw ToolError("`scale` must be 0.05–32 (frame pixels per image pixel).")
      }
      parsed.scale = scale
    }
    if let value = arguments["mask"] { parsed.mask = try mask(value) }
    if let value = arguments["paint"] { parsed.paint = try paint(value, hasMask: parsed.mask != nil) }
    if let value = arguments["reference_images"] { parsed.references = try references(value) }
    if let value = arguments["merge_into_image"] {
      guard AgentTools.isBoolean(value), let merge = value as? Bool else { throw ToolError("`merge_into_image` is true or false.") }
      parsed.merge = merge
    }
    return parsed
  }

  private static func mask(_ value: Any) throws -> Mask {
    guard let object = value as? [String: Any] else {
      throw ToolError("`mask` is an object: {\"shapes\": […], \"image\": …, \"select\": {…}, \"grow\": pixels, \"invert\": true}.")
    }
    var mask = Mask()
    if let value = object["shapes"] {
      guard let shapes = value as? [Any] else { throw ToolError("`mask.shapes` is an array of shapes.") }
      mask.shapes = try shapes.enumerated().map { index, entry in
        guard let shape = entry as? [String: Any] else { throw ToolError("Shape \(index + 1) isn't an object.") }
        return try AgentTools.stroke(shape, number: index + 1, erases: false)
      }
    }
    if let value = object["image"] {
      guard let source = value as? String else { throw ToolError("`mask.image` is a path or data: URL: white regenerates, black or transparent keeps.") }
      mask.image = source
    }
    if let value = object["select"] { mask.select = try selection(value) }
    guard !mask.shapes.isEmpty || mask.image != nil || mask.select != nil else {
      throw ToolError("`mask` needs `shapes`, an `image` or a `select`: what to regenerate. `grow` and `invert` change that.")
    }
    if let value = object["grow"] {
      guard !AgentTools.isBoolean(value), let amount = AgentTools.double(value), amount.isFinite, abs(amount.rounded()) <= 512 else {
        throw ToolError("`mask.grow` is how far to move the mask's edge out, in the image's pixels, -512 to 512 (negative moves it in).")
      }
      mask.grow = Int(amount.rounded())
    }
    if let value = object["invert"] {
      guard AgentTools.isBoolean(value), let invert = value as? Bool else { throw ToolError("`mask.invert` is true or false.") }
      mask.invert = invert
    }
    return mask
  }

  private static func selection(_ value: Any) throws -> Selection {
    guard let object = value as? [String: Any] else {
      throw ToolError("`mask.select` is an object: {\"points\": [{\"x\", \"y\"}], \"box\": {…}} for SAM 2.1, or {\"subject\": true}.")
    }
    if object["text"] != nil || object["prompt"] != nil {
      throw ToolError("`mask.select` doesn't take a text prompt. Look at the image (get_image) and pass `points` on what you mean, a `box` around it, or `subject: true`.")
    }
    var selection = Selection()
    if let value = object["points"] {
      guard let points = value as? [Any] else { throw ToolError("`mask.select.points` is an array of {\"x\", \"y\"}.") }
      selection.points = try points.enumerated().map { index, entry in
        guard let point = entry as? [String: Any], let x = AgentTools.double(point["x"]), let y = AgentTools.double(point["y"]) else {
          throw ToolError("Point \(index + 1) needs x and y.")
        }
        return SAMSegmenter.Point(location: CGPoint(x: x, y: y), positive: point["positive"] as? Bool ?? true)
      }
    }
    if let value = object["box"] { selection.box = try AgentTools.rect(value, named: "mask.select.box") }
    selection.subject = object["subject"] as? Bool == true
    if selection.subject {
      guard selection.box == nil, selection.points.count <= 1, selection.points.first?.positive != false else {
        throw ToolError("`subject` takes at most one point, to pick the subject under it, and no box. For points and boxes, leave out `subject` (SAM 2.1).")
      }
    } else if selection.points.isEmpty, selection.box == nil {
      throw ToolError("`mask.select` needs `points`, a `box`, or `subject: true`.")
    }
    // As many as SAM's prompt encoder takes beside the box (`SAMGeometry.promptInputs`).
    let limit = SAMGeometry.maxPromptPoints - (selection.box == nil ? 0 : 2)
    guard selection.points.count <= limit else {
      throw ToolError("`mask.select` takes at most \(limit) points\(selection.box == nil ? "" : " with a box") (\(selection.points.count) given).")
    }
    if let value = object["size"] {
      guard let name = value as? String, let size = SAMFiles.Size(rawValue: name) else { throw ToolError("`size` is \"tiny\", \"small\" or \"large\".") }
      selection.size = size
    }
    return selection
  }

  private static func paint(_ value: Any, hasMask: Bool) throws -> Paint {
    guard let object = value as? [String: Any] else {
      throw ToolError("`paint` is an object: {\"shapes\": […], \"fill_mask\": true, \"color\": \"#RRGGBB\"}.")
    }
    var paint = Paint()
    if let value = object["color"] {
      guard let text = value as? String else { throw ToolError("`paint.color` is \"#RRGGBB\" or \"#RRGGBBAA\".") }
      paint.color = try AgentTools.paintColor(text, what: "`paint.color`")
    }
    if let value = object["fill_mask"] {
      guard AgentTools.isBoolean(value), let fills = value as? Bool else { throw ToolError("`paint.fill_mask` is true or false.") }
      paint.fillMask = fills
    }
    if paint.fillMask {
      guard hasMask else { throw ToolError("`paint.fill_mask` needs a `mask`.") }
      guard paint.color != nil else {
        throw ToolError("`paint.fill_mask` needs `paint.color` (\"#RRGGBB\"): the color the mask is filled with, which the prompt can then name.")
      }
    }
    if let value = object["shapes"] {
      guard let shapes = value as? [Any] else { throw ToolError("`paint.shapes` is an array of shapes.") }
      paint.shapes = try shapes.enumerated().map { index, entry in
        guard let shape = entry as? [String: Any] else { throw ToolError("Shape \(index + 1) isn't an object.") }
        // Off the screen there's no paint color to fall back to: each shape has its own, or `color`.
        guard paint.color != nil || shape["color"] != nil || shape["erase"] as? Bool == true else {
          throw ToolError("Shape \(index + 1) has no `color`, and there's no `paint.color` to take.")
        }
        return try AgentTools.paintStroke(shape, number: index + 1, color: paint.color ?? CanvasPaint.Color(red: 0, green: 0, blue: 0))
      }
    }
    guard paint.fillMask || !paint.shapes.isEmpty else { throw ToolError("`paint` needs `shapes` or `fill_mask`.") }
    return paint
  }

  private static func references(_ value: Any) throws -> [Reference] {
    let problem = ToolError(
      "Each reference image is a path, a data: URL, {\"image\": …} or {\"history_step\": N}, with an optional `weight` (0–1).")
    guard let entries = value as? [Any] else { throw problem }
    return try entries.compactMap { entry -> Reference? in
      let object = entry as? [String: Any]
      let path = (entry as? String) ?? (object?["image"] as? String)
      let step = AgentTools.int(object?["history_step"])
      guard (path == nil) != (step == nil) else { throw problem }
      let weight = Float(AgentTools.double(object?["weight"]) ?? 1)
      // As generate: a weight of 0 leaves the image out.
      guard weight > 0 else { return nil }
      return Reference(source: path.map(Source.image) ?? .historyStep(step ?? 0), weight: min(weight, 1))
    }
  }
}

/// `edit_image`: an Edit run on an image the caller names, built from the same value the Create
/// screen's own runs are (`CanvasEdit`) and queued off the canvas (`JobQueue.Job.detached`), so
/// the result is what Generate would have made while the screen stays as the user left it.
extension AgentTools {
  static let editImageDefinition: [String: Any] = [
    "name": "edit_image",
    "title": "Edit an image without the canvas",
    "description": """
      Edits part of an image in one call, without touching the Create screen: the canvas, its \
      mask and paint, the prompt, the settings, the moodboard and the selected History step all \
      stay as the user has them, and no preview or result shows on the canvas. It does what \
      set_canvas_image, set_canvas_mask or auto_mask, grow_canvas_mask, set_canvas_paint, \
      set_canvas_frame and generate with use_canvas do together, on its own copy. The image is \
      `history_step` or `image`; `region` (the image's pixels from its top left; default the \
      whole image) is what the model sees and regenerates, at `width`×`height`, or at `scale` \
      frame pixels per image pixel (a 912×1152 region at scale 4 is a 3648×4608 run), or with \
      neither at the model's usual pixel count; a region of another shape than the size is grown \
      about its center, never cropped (with `scale` the size is rounded up to 64s, so the run \
      sees a little more than `region`), then moved to stay inside the image where it fits. \
      Keep the region inside the image: where it reaches past the edges, or is larger than \
      the image, the run fills in what's outside and the merged result grows to hold it, so \
      it's larger than the source (extends_past_image, canvas_size and a note say so). `mask` \
      limits what changes inside it; `paint` puts flat color on the input (`fill_mask` fills the mask, which a prompt can then name: “replace the \
      green area with the face from Picture 2”); `reference_images` go along as the pictures \
      after the image itself (Picture 1), for models that take them (see list_models). With \
      merge_into_image (the default) the result is put back into the whole image and saved as \
      a new step after the source in the project open when it was called (even if another is \
      opened before it ends), and outside the mask nothing changes. \
      Settings layer as generate's do (the model's defaults, `preset`, `settings`, then the \
      fields). It runs as a job on this Mac, in the Queue with the rest: it waits, and returns \
      what generate returns plus merged, parent_history_step, canvas_size (the saved image's \
      size), source_size, extends_past_image, region, scale, mask, has_paint, references and \
      job_id; with background: true it returns a job_id at \
      once for get_job, list_jobs and cancel_job. To match the result's colors to the source \
      afterwards, call match_colors with original_history_step (the source step) and \
      unchanged_only true.
      """,
    "inputSchema": [
      "type": "object",
      "required": ["prompt"],
      "properties": [
        "history_step": ["type": "integer", "description": "The image to edit: a history step (see list_history; images only). The result is saved after it."],
        "image": ["type": "string", "description": "Instead: path to an image, or a data: URL. It's saved to the project with the result."],
        "prompt": ["type": "string", "description": "Required. For an edit model, say what to change and what to keep; the image is Picture 1, reference images Picture 2 and on."],
        "negative_prompt": ["type": "string"],
        "model": ["type": "string", "description": "Model file or name (see list_models). Defaults to the model selected in the app. It must be on this Mac."],
        "preset": ["type": "string", "description": "Name of a saved preset to apply (see list_presets)."],
        "settings": ["type": "object", "description": "Any other settings as Draw Things configuration JSON keys (see get_settings), e.g. {\"maskBlur\": 8, \"maskBlurOutset\": 4} for a softer mask edge."],
        "use_app_settings": ["type": "boolean", "description": "Start from the settings in Atelier's inspector instead of the model's defaults (read, not changed). Only when `model` is the app's selected model."],
        "steps": ["type": "integer"],
        "guidance_scale": ["type": "number"],
        "strength": ["type": "number", "description": "How much to change, 0–1, for models that don't take references. At 1 with no mask such a model has nothing of the image to work from."],
        "seed": ["type": "integer", "minimum": 0, "maximum": 4_294_967_295, "description": "Random when omitted."],
        "region": [
          "type": "object", "required": ["x", "y", "width", "height"],
          "description": "The part of the image the run sees and regenerates, in the image's pixels from its top left: a face's box with room around it, say (find_faces, get_image). Default: the whole image.",
          "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
        ],
        "width": ["type": "integer", "description": "The run's width in pixels, rounded to a multiple of 64. With `height`; not with `scale`."],
        "height": ["type": "integer", "description": "The run's height in pixels, rounded to a multiple of 64."],
        "scale": ["type": "number", "description": "Frame pixels per image pixel, 0.05–32: the run is the region at this zoom, sides rounded up to 64 (the region grows to match, about its center). Instead of `width` and `height`."],
        "mask": [
          "type": "object",
          "description": "What to regenerate, in the image's pixels; the rest of the region is kept and blended at the edge (the Mask Blur settings). Built in order: `shapes`, `image` and `select` together, then `grow`, then `invert`.",
          "properties": [
            "shapes": [
              "type": "array",
              "description": "{\"shape\": \"rect\" or \"ellipse\", \"x\", \"y\", \"width\", \"height\"} or {\"shape\": \"polygon\", \"points\": [[x, y], …]}, as set_canvas_mask takes them.",
              "items": ["type": "object"],
            ],
            "image": ["type": "string", "description": "A mask image the size of the image (path or data: URL): white regenerates; transparent or black keeps."],
            "select": [
              "type": "object",
              "description": "Select as auto_mask does: {\"subject\": true} (Apple's Vision; with one point, the subject under it), or SAM 2.1 from `points` ({\"x\", \"y\", \"positive\"}) and a `box`, with `size` (tiny, small or large).",
              "properties": [
                "points": ["type": "array", "items": ["type": "object"]],
                "box": ["type": "object"],
                "subject": ["type": "boolean"],
                "size": ["type": "string", "enum": ["tiny", "small", "large"]],
              ],
            ],
            "grow": ["type": "integer", "minimum": -512, "maximum": 512, "description": "Move the mask's edge out by this many image pixels (negative: in), as grow_canvas_mask does."],
            "invert": ["type": "boolean", "description": "Flip the mask over the whole image, last."],
          ],
        ],
        "paint": [
          "type": "object",
          "description": "Flat color on the run's input only (never in the result outside the mask): `fill_mask` fills what the mask covers with `color`, and `shapes` paint as set_canvas_paint's do (each with its own `color`, else `color`).",
          "properties": [
            "shapes": ["type": "array", "items": ["type": "object"]],
            "fill_mask": ["type": "boolean", "description": "Fill the mask with `color`. Needs a `mask`."],
            "color": ["type": "string", "description": "\"#RRGGBB\" or \"#RRGGBBAA\", e.g. \"#00FF00\"."],
          ],
        ],
        "reference_images": [
          "type": "array",
          "description": "Reference images, in order (Picture 2 and on): paths or data: URLs, {\"image\": …, \"weight\": 0–1} or {\"history_step\": N}. Only for models that take them.",
          "items": ["anyOf": [["type": "string"], ["type": "object"]]],
        ],
        "merge_into_image": ["type": "boolean", "description": "Put the result back into the whole image (the default). False saves just the frame."],
        "save_to": ["type": "string", "description": "Where to write the PNG: a file path, or a folder. Defaults to a temporary folder."],
        "include_image": ["type": "boolean", "description": "Return the image inline (scaled to 1024 px on the long side). Default true."],
        "background": ["type": "boolean", "description": "Return a job_id right away instead of waiting, then check on it with get_job. Either way the run keeps going if the call is cancelled or dropped; only cancel_job stops it."],
      ],
    ],
  ]

  /// Runs edit_image as a job, as `generate` runs (`startJob`).
  func startEditImage(_ arguments: [String: Any], progress: @escaping (Progress) -> Void) async throws -> [String: Any] {
    if let background = arguments["background"], !Self.isBoolean(background) { throw ToolError("`background` must be true or false.") }
    return try await startJob(
      tool: "edit_image", label: (arguments["prompt"] as? String) ?? "", background: arguments["background"] as? Bool == true,
      progress: progress
    ) { [weak self] update in
      guard let self else { throw CancellationError() }
      return try await self.editImage(arguments, progress: update)
    }
  }

  /// Reads and decodes an image file or data: URL off the main actor: a 16-megapixel PNG takes
  /// a while.
  @concurrent static func loadedImage(_ source: String) async throws -> CGImage {
    try loadImage(source)
  }

  /// `mask.image` as a mask stroke, read and converted off the main actor (the stroke is the
  /// mask's pixels as a PNG, written at the image's full size). Nil when it paints nothing.
  @concurrent static func maskStroke(imageAt source: String, width: Int, height: Int) async throws -> CanvasMask.Stroke? {
    let image = try loadImage(source)
    guard image.width == width, image.height == height else {
      throw ToolError(
        "The mask image is \(image.width)×\(image.height), but the image is \(width)×\(height). Make it that size: white regenerates, black or transparent keeps.")
    }
    return CanvasMask.Stroke.bitmap(image)
  }

  /// A reference image at the size the moodboard keeps (`Moodboard.maxSide`), scaled off the main
  /// actor.
  @concurrent static func reference(_ image: CGImage, maxSide: Int) async -> CGImage {
    ImageLoader.fitted(image, maxSide: maxSide)
  }

  /// An image named by a caller, at its own size. A History step is one of `project`'s, the
  /// project the call started in: the steps of another opened since have other numbers.
  private func sourceImage(_ source: CanvasEditArguments.Source, in project: Project) async throws -> (image: CGImage, item: HistoryItem?) {
    switch source {
    case .image(let path): return (try await Self.loadedImage(path), nil)
    case .historyStep(let step):
      guard create.history.project === project else {
        throw ToolError("Another project was opened while edit_image was reading its images, so history step \(step) is no longer the one meant. Call edit_image again.")
      }
      guard let item = create.history.items.first(where: { $0.id.logicalTime == step }) else {
        throw ToolError("No history step \(step) in “\(create.history.project.name)”. See list_history.")
      }
      guard !item.isVideo else { throw ToolError("History step \(step) is a video; edit_image takes images.") }
      guard item.hasImage, let image = await create.history.image(for: item) else {
        throw ToolError("Couldn't read history step \(step)'s image.")
      }
      return (image, item)
    }
  }

  private func editImage(_ arguments: [String: Any], progress: @escaping (Progress) -> Void) async throws -> [String: Any] {
    let parsed = try CanvasEditArguments.parse(arguments)
    if create.models.isEmpty { await create.refreshModelList() }
    // On this Mac only: a server's run reports back through the canvas's own path.
    let named = arguments["model"] as? String
    if named ?? "" == "", let selected = create.selectedModel, !create.models.contains(where: { $0.file == selected }) {
      throw ToolError("\(selected) is only on \(create.runTargetServerName ?? "the server"); edit_image runs on this Mac. Pass a `model` from list_models.")
    }
    let model = try resolveModel(named)
    let layered = try await configuration(arguments, model: model)
    var configuration = layered.configuration
    var notes = layered.notes
    let loras = configuration.loras.compactMap(\.file)
    let isVideo = VideoModel(model: model, loras: loras) != nil
      || create.models.first { $0.file == model }.map { ModelTraits($0).isVideo } == true
    guard !isVideo else { throw ToolError("\(model) makes video; edit_image edits images.") }
    let takesReferences = self.takesReferences(model: model, loras: loras)
    if !parsed.references.isEmpty, !takesReferences {
      throw ToolError("\(model) doesn't take reference images (see list_models), so leave out `reference_images` or pick an edit model.")
    }
    // As the canvas's Edit mode (`CreateModel.canEdit`): such a model has nothing to start from.
    if !takesReferences, configuration.strength >= 1, parsed.mask == nil {
      throw ToolError("Edit means nothing to \(model) at Strength 100% with no mask: pass a `mask` or lower `strength`.")
    }
    if layered.sizeGiven, parsed.scale != nil { throw ToolError("Pass `width` and `height`, or `scale`, not both.") }

    // The image, and the step it is. The step, the detail layers and the result's place all
    // belong to the project open now: the job is tied to it (`JobQueue.Job.project`), so opening
    // another while it waits or runs doesn't send the result there.
    let project = create.history.project
    let projectName = project.name
    let (source, sourceItem) = try await sourceImage(parsed.source, in: project)
    let sourceSize = CGSize(width: source.width, height: source.height)
    let sourceRect = CGRect(origin: .zero, size: sourceSize)
    let size = "\(source.width)×\(source.height)"
    var detail: [Project.DetailLayer] = []
    if let tensorId = sourceItem?.imageTensorId { detail = await project.read { $0.detailLayers(tensorId: tensorId) } }

    // The frame: the output size, and where the image lies in it (`CanvasState`'s zoom and offset).
    var scale: Double?
    var offset = CGSize.zero
    if let region = parsed.region {
      guard region.intersects(sourceRect) else {
        throw ToolError("`region` doesn't overlap the \(size) image (its pixels from the top left).")
      }
      var frame = FrameSelection.frame(
        for: region, width: layered.sizeGiven ? configuration.width : nil, height: layered.sizeGiven ? configuration.height : nil,
        scale: parsed.scale, pixelCount: Double(configuration.width * configuration.height))
      // Growing a region inside the image to the size's shape (or to whole 64s) can push it past
      // an edge, which would grow the merged image: it's moved back inside where it fits, as
      // set_canvas_frame does. One the caller put past the edges stays where it was asked for.
      if sourceRect.contains(region) {
        frame.region = FrameSelection.region(around: frame.region, padding: 0, aspect: 0, inside: sourceSize)
      }
      configuration.width = Int(frame.size.width)
      configuration.height = Int(frame.size.height)
      let placement = FrameSelection.placement(showing: frame.region, sourceSize: sourceSize, frameSize: frame.size)
      guard !placement.clamped else {
        let wanted = CanvasPlacement.zoomAndOffset(showing: frame.region, sourceSize: sourceSize, frameSize: frame.size).scale
        throw ToolError(
          "That region needs a zoom of \(String(format: wanted >= 100 ? "%.0f" : "%.3g", wanted))×, outside 0.05×–32×. Pass a \(wanted > 1 ? "larger" : "smaller") `region` or another size.")
      }
      scale = placement.scale
      offset = placement.offset
    } else {
      // The whole image. As generate's input_image: its shape at about the model's pixel count,
      // filled rather than fitted, since rounding the size to 64 shifts the shape a little and a
      // fitted image would leave slivers for the model to fill in (and the merge to grow by).
      if let zoom = parsed.scale {
        configuration.width = Self.roundTo64(Int((sourceSize.width * zoom).rounded()))
        configuration.height = Self.roundTo64(Int((sourceSize.height * zoom).rounded()))
      } else if !layered.sizeGiven {
        let area = Double(configuration.width * configuration.height)
        let aspect = sourceSize.width / sourceSize.height
        configuration.width = Self.roundTo64(Int((area * aspect).squareRoot()))
        configuration.height = Self.roundTo64(Int((area / aspect).squareRoot()))
      }
      let across = Double(configuration.width) / sourceSize.width, down = Double(configuration.height) / sourceSize.height
      let fill = max(across, down)
      guard CanvasState.range.contains(fill) else {
        throw ToolError("Showing the whole \(size) image at \(configuration.width)×\(configuration.height) needs a zoom of \(String(format: "%.3g", fill))×, outside 0.05×–32×.")
      }
      // The same shape exactly is the fitted image (`CanvasState.scale` nil).
      scale = abs(across - down) < 1e-9 ? nil : fill
    }
    let frameSize = CGSize(width: configuration.width, height: configuration.height)
    let placement = CanvasPlacement(sourceSize: sourceSize, frameSize: frameSize, scale: scale, offset: offset)

    // The mask's strokes, in the image's pixels.
    var strokes: [CanvasMask.Stroke] = []
    if let mask = parsed.mask {
      for (index, stroke) in mask.shapes.enumerated() {
        let bounds = stroke.kind == .polygon ? Self.bounds(of: stroke.points) : Self.bounds(of: stroke.points).standardized
        guard bounds.intersects(sourceRect) else {
          throw ToolError("Shape \(index + 1) lies wholly outside the \(size) image (coordinates are its pixels from the top left).")
        }
        strokes.append(stroke)
      }
      if let path = mask.image, let stroke = try await Self.maskStroke(imageAt: path, width: source.width, height: source.height) {
        strokes.append(stroke)
      }
      if let select = mask.select { strokes += try await selected(select, on: source) }
    }
    for (index, stroke) in (parsed.paint?.shapes ?? []).enumerated() {
      let bounds = Self.bounds(of: stroke.points).standardized.insetBy(dx: -stroke.radius, dy: -stroke.radius)
      guard bounds.intersects(sourceRect) else {
        throw ToolError("Paint shape \(index + 1) lies wholly outside the \(size) image (coordinates are its pixels from the top left).")
      }
    }

    // Reference images, as the moodboard holds them.
    var references: [GenerationEngine.Reference] = []
    for reference in parsed.references {
      let image = try await sourceImage(reference.source, in: project).image
      references.append(.init(image: await Self.reference(image, maxSide: Moodboard.maxSide), weight: reference.weight))
    }

    // The mask grown and measured, the paint, and the frame drawn: off the main actor, where a
    // 16-megapixel image takes a while.
    let sourceTensorId = sourceItem?.imageTensorId
    let prepared = await Self.prepared(
      CanvasEdit(
        source: source, sourceTensorId: sourceTensorId, isImported: sourceItem == nil, scale: scale, offset: offset, detail: detail,
        merge: parsed.merge, moodboard: references),
      strokes: parsed.mask == nil ? nil : strokes, grow: parsed.mask?.grow ?? 0, invert: parsed.mask?.invert ?? false,
      paint: parsed.paint, placement: placement, maskBlur: Double(configuration.maskBlur), maskBlurOutset: configuration.maskBlurOutset)
    if let stats = prepared.mask, stats.painted == 0 || stats.inRegion == 0 {
      throw ToolError(
        "The mask is empty: its shapes/selection cover nothing inside `region`"
          + (stats.painted > 0 ? " (what it covers lies outside the part of the image the run sees)." : "."))
    }
    guard let inputs = prepared.inputs else { throw ToolError("Couldn't draw the \(size) image into the \(configuration.width)×\(configuration.height) frame.") }

    let seed: UInt32
    if let value = Self.int(arguments["seed"]) {
      guard value >= 0, value <= Int(UInt32.max) else { throw ToolError("`seed` must be 0–4294967295.") }
      seed = UInt32(value)
    } else {
      seed = UInt32.random(in: 0...UInt32.max)
    }
    var request = GenerationEngine.Request(
      model: model, prompt: parsed.prompt, negativePrompt: arguments["negative_prompt"] as? String ?? "", seed: seed,
      configuration: configuration)
    request.moodboard = references
    request.setRefineInputs(inputs, isImported: sourceItem == nil)
    // It follows the step it edits, on no line of the Queue's (`JobQueue.Job.detached`).
    request.parentTensorId = sourceItem.map(HistoryStore.tip(of:))
    let merged = request.merge != nil
    let region = (request.merge?.placement ?? placement).cropRect
    let zoom = (request.merge?.placement ?? placement).zoom
    if parsed.merge, !merged {
      notes.append("Nothing to merge into: the run took the whole image with no mask, so its result is the new image.")
    }
    // As the canvas reports it (`canvasState`): half a pixel of slack for rounding to whole frame pixels.
    let extendsPastImage = !sourceRect.insetBy(dx: -0.5, dy: -0.5).contains(region)
    if extendsPastImage, !merged {
      notes.append("The region reaches past the \(size) image's edges: the run fills in what's outside.")
    }

    let summary = String(parsed.prompt.prefix(60))
    // The project it was saved into, as the job hands it back: renamed while the job waited, it
    // has another name and object than the ones held here, and it may no longer be the open one.
    let (item, returned) = try await run(request, target: .local, detached: true, project: projectName, summary: summary, progress: progress)
    let savedIn = reopened(returned)
    let stillOpen = savedIn === create.history.project
    // The saved image's own size: a merged one is the whole (maybe grown) image, not the frame.
    let saved = await savedIn.read { $0.image(for: item) }
    let savedSize = saved.map { ["width": $0.width, "height": $0.height] } ?? ["width": item.sidecar.width, "height": item.sidecar.height]
    // The step it edited, by its image: steps are renumbered when History forks.
    var parent: HistoryItem?
    if stillOpen {
      parent = sourceItem.flatMap { create.history.item(tensorId: $0.tensorId) }
        ?? item.inputTensorId.flatMap { create.history.item(tensorId: $0) }
    } else {
      let ids = [sourceItem?.tensorId, item.inputTensorId].compactMap(\.self)
      parent = await savedIn.read { project in
        let tree = project.tree()
        return ids.lazy.compactMap { id in tree.step(tensorId: id).flatMap { tree.items[$0] } }.first
      }
    }
    if merged {
      let grew = savedSize["width"] != source.width || savedSize["height"] != source.height
      if extendsPastImage || grew {
        // Said plainly: a caller comparing the result with its source, or pasting it back
        // somewhere, has an image of another size, with the source no longer at its top left.
        notes.append(
          "The region reaches past the \(size) image's edges, so the merged image grew to hold it: it is \(savedSize["width"]!)×\(savedSize["height"]!) (canvas_size), with what the run made outside the image at its edges. To keep the image's size, pass a `region` inside it.")
      } else {
        notes.append("Merged into the whole image (\(savedSize["width"]!)×\(savedSize["height"]!)).")
      }
    }
    if let parent { notes.append("It follows history step \(parent.id.logicalTime). The Create screen wasn't changed.") }
    if !stillOpen {
      notes.append("It was saved to “\(savedIn.name)”, the project it was called in, which isn't the open one now: its history_step is a step there.")
    }
    var extra: [String: Any] = [
      "parent_history_step": parent?.id.logicalTime ?? NSNull(), "merged": merged, "canvas_size": savedSize,
      "source_size": Self.json(sourceSize), "extends_past_image": extendsPastImage,
      "region": Self.json(region), "scale": (zoom.x + zoom.y) / 2, "has_paint": prepared.hasPaint, "references": references.count,
    ]
    if let stats = prepared.mask {
      extra["mask"] = [
        "painted_pixels": stats.painted, "bounds": stats.bounds.map(Self.json) ?? NSNull(), "coverage_in_region": stats.inRegion,
      ] as [String: Any]
    } else {
      extra["mask"] = NSNull()
    }
    return try await result(
      of: item, in: savedIn, model: model, configuration: request.configuration, seed: seed, summary: summary, notes: notes,
      arguments: arguments, extra: extra)
  }

  /// `mask.select` on `image`, as auto_mask selects on the canvas image, with its messages.
  private func selected(_ select: CanvasEditArguments.Selection, on image: CGImage) async throws -> [CanvasMask.Stroke] {
    let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let size = "\(image.width)×\(image.height)"
    for (index, point) in select.points.enumerated() where !imageRect.contains(point.location) {
      throw ToolError("Point \(index + 1) is outside the \(size) image (its pixels from the top left).")
    }
    var box: CGRect?
    if let given = select.box {
      let rect = given.intersection(imageRect)
      guard !rect.isNull, rect.width > 0, rect.height > 0 else { throw ToolError("`mask.select.box` doesn't overlap the \(size) image.") }
      box = rect
    }
    let samSize = select.size ?? create.autoMask.size
    if !select.subject, SAMFiles.installed(samSize) == nil {
      throw ToolError(
        "SAM 2.1 \(samSize.title) isn't downloaded. Ask the user to download it in Atelier: on the Create screen pick the Select tool (the wand beside Brush and Eraser) and use the download in its bar. Or use `subject: true`, which needs no download.")
    }
    do {
      let found = try await AutoMaskSession.autoMaskStroke(
        on: image, prompt: select.subject ? nil : SAMSegmenter.Prompt(points: select.points, box: box),
        subjectAt: select.subject ? .some(select.points.first?.location) : nil, size: samSize)
      guard found.selection.selectedPixels > 0, let stroke = found.selection.stroke else {
        throw ToolError("`mask.select` selected nothing. Try another point, add a box, or use `subject: true`.")
      }
      return [stroke]
    } catch let error as SubjectMask.Failure {
      throw ToolError(error.localizedDescription + " Try `subject: true` without a point, or select with SAM 2.1 (`points` or a `box`).")
    } catch let error as AutoMaskError {
      throw ToolError(Self.hint(for: error))
    }
  }

  /// What `prepared` works out.
  nonisolated struct PreparedEdit: @unchecked Sendable {
    /// The mask as the run takes it: how much is painted, where, and how much of what the frame
    /// shows; nil with no mask.
    var mask: (painted: Int, bounds: CGRect?, inRegion: Double)?
    var hasPaint = false
    /// The run's inputs; nil when the mask is empty or the image couldn't be drawn.
    var inputs: RefineInputs?
  }

  /// The heavy part of an edit, off the main actor: the mask's strokes rasterized, grown and
  /// inverted (`MaskMorphology`), measured against the frame, the paint (the shapes, then the mask
  /// filled, as set_canvas_paint orders them), and the frame drawn (`CanvasEdit.refineInputs`). `edit` comes without mask or paint.
  @concurrent static func prepared(
    _ edit: CanvasEdit, strokes: [CanvasMask.Stroke]?, grow: Int, invert: Bool, paint: CanvasEditArguments.Paint?,
    placement: CanvasPlacement, maskBlur: Double, maskBlurOutset: Int
  ) async -> PreparedEdit {
    var edit = edit
    var result = PreparedEdit()
    let width = edit.source.width, height = edit.source.height
    var flat: CanvasMask.Stroke?
    if let strokes {
      var mask = CanvasMask(strokes: strokes)
      var coverage = mask.coverage(width: width, height: height)
      if grow != 0 {
        // As grow_canvas_mask grows the canvas's (`CanvasMask.grown`); nothing left is no mask.
        let grown = mask.grown(by: grow, width: width, height: height, from: coverage)
        mask = grown?.mask ?? CanvasMask(strokes: [])
        coverage = grown?.coverage ?? [UInt8](repeating: 0, count: width * height)
      }
      if invert {
        mask.strokes.append(.invert)
        for index in coverage.indices { coverage[index] = coverage[index] != 0 ? 0 : 255 }
      }
      // How much is painted, where, and how much of what the frame shows (`CanvasMask.stats`).
      let crop = placement.cropRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
      var count = 0, inFrame = 0, frameTotal = 0
      var minX = width, minY = height, maxX = -1, maxY = -1
      for y in 0..<height {
        let inRow = !crop.isNull && Double(y) + 0.5 >= crop.minY && Double(y) + 0.5 < crop.maxY
        for x in 0..<width {
          let painted = coverage[y * width + x] != 0
          if painted {
            count += 1
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            maxY = y
          }
          if inRow, Double(x) + 0.5 >= crop.minX, Double(x) + 0.5 < crop.maxX {
            frameTotal += 1
            if painted { inFrame += 1 }
          }
        }
      }
      let bounds = count > 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
      result.mask = (count, bounds, frameTotal > 0 ? Double(inFrame) / Double(frameTotal) : 0)
      guard count > 0, inFrame > 0 else { return result }
      edit.mask = mask
      if paint?.fillMask == true, let png = CanvasMask.grayPNG(coverage, width: width, height: height) {
        flat = CanvasMask.Stroke(kind: .bitmap, points: [.zero], bitmap: png)
      }
    }
    if let paint {
      var layer = CanvasPaint()
      layer.strokes += paint.shapes
      if let flat, let color = paint.color, let fill = CanvasPaint.Stroke.fill(flat, color: color) { layer.strokes.append(fill) }
      if layer.mayHaveColor {
        edit.paint = layer
        result.hasPaint = true
      }
    }
    result.inputs = edit.refineInputs(frame: placement.frameSize, maskBlur: maskBlur, maskBlurOutset: maskBlurOutset)
    return result
  }
}
/// What `crop_image` is asked for, read from its arguments alone (`CropArgumentsTests` in
/// `CropTests`): a rectangle, a ratio, or no crop. Numbers come from an agent, so they're checked
/// here (finite, a size) and against the image in `crop(over:width:height:)` before any becomes
/// an Int.
nonisolated enum CropArguments {
  enum Change: Equatable, Sendable {
    /// x, y, width, height in the source's pixels.
    case rect(CGRect)
    /// The largest crop of the ratio, centred.
    case aspect(Edit.CropAspect, swapped: Bool)
    case clear
  }

  typealias ToolError = AgentTools.ToolError

  /// The ratios `aspect` takes: the Crop bar's, each either way up.
  static let aspects: [String: (Edit.CropAspect, Bool)] = {
    var names: [String: (Edit.CropAspect, Bool)] = ["original": (.original, false), "square": (.square, false)]
    for aspect in Edit.CropAspect.allCases {
      guard let parts = aspect.parts else { continue }
      names["\(parts.width):\(parts.height)"] = (aspect, false)
      if parts.width != parts.height { names["\(parts.height):\(parts.width)"] = aspect.swapping(false) }
    }
    return names
  }()

  static func parse(_ arguments: [String: Any]) throws -> Change {
    let rectKeys = ["x", "y", "width", "height"]
    let hasRect = rectKeys.contains { arguments[$0] != nil }
    let hasAspect = arguments["aspect"] != nil
    var clear = false
    if let value = arguments["clear"] {
      guard AgentTools.isBoolean(value), let flag = value as? Bool else { throw ToolError("`clear` is true or false.") }
      clear = flag
    }
    guard [hasRect, hasAspect, clear].filter(\.self).count == 1 else {
      throw ToolError("Pass the crop as `x`, `y`, `width` and `height`, or as `aspect`, or `clear: true`: one of them.")
    }
    if clear { return .clear }
    if hasAspect {
      guard let name = arguments["aspect"] as? String, let found = aspects[name.lowercased().replacingOccurrences(of: " ", with: "")] else {
        throw ToolError("`aspect` is one of \(aspects.keys.sorted().joined(separator: ", ")).")
      }
      if let anchor = arguments["anchor"] {
        guard anchor as? String == "center" else { throw ToolError("`anchor` can only be \"center\" (the default).") }
      }
      return .aspect(found.0, swapped: found.1)
    }
    if arguments["anchor"] != nil { throw ToolError("`anchor` goes with `aspect`.") }
    var values: [Double] = []
    for key in rectKeys {
      guard let value = arguments[key], !AgentTools.isBoolean(value), let number = AgentTools.double(value), number.isFinite else {
        throw ToolError("`x`, `y`, `width` and `height` are all needed, as numbers of the source's pixels from its top left.")
      }
      values.append(number)
    }
    guard values[2] > 0, values[3] > 0 else { throw ToolError("`width` and `height` must be above 0.") }
    return .rect(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
  }
}

nonisolated extension CropArguments.Change {
  /// The crop this makes on a `width` × `height` source with `current` there now (whose ratio
  /// lock a rectangle drops, as a free drag would); nil for none. A rectangle must be inside the
  /// image and at least `Edit.Crop.minimumSide` on a side.
  func crop(over _: Edit.Crop?, width: Int, height: Int) throws -> Edit.Crop? {
    switch self {
    case .clear: return nil
    case .aspect(let aspect, let swapped):
      let bounds = CGSize(width: width, height: height)
      let rect = CropGeometry.largest(ratio: aspect.ratio(imageWidth: width, imageHeight: height, swapped: swapped), in: bounds)
      return Edit.Crop(rect: rect, imageWidth: width, imageHeight: height, aspect: aspect, swapped: swapped)
    case .rect(let rect):
      let side = Double(Edit.Crop.minimumSide)
      guard rect.minX >= -0.5, rect.minY >= -0.5, rect.maxX <= Double(width) + 0.5, rect.maxY <= Double(height) + 0.5 else {
        throw AgentTools.ToolError("The crop goes outside the source image, which is \(width)×\(height) pixels.")
      }
      guard rect.width >= side, rect.height >= side, let crop = Edit.Crop(rect: rect, imageWidth: width, imageHeight: height) else {
        throw AgentTools.ToolError("The crop must be at least \(Edit.Crop.minimumSide)×\(Edit.Crop.minimumSide) pixels.")
      }
      return crop
    }
  }
}

/// `crop_image`: the Edit screen's Crop, saved as a step after the source as Save to History
/// does, through `edit_image_look`'s job: the base is the step's record (its look and crop), so a
/// look stays as it was and only the crop changes.
extension AgentTools {
  static let cropImageDefinition: [String: Any] = [
    "name": "crop_image",
    "title": "Crop an image",
    "description": """
      Crops an image as the Edit screen's Crop tool does and saves the result as a new history \
      step after its source, like Save to History. Non-destructive, like edit_image_look: for a \
      step this tool, edit_image_look or the Edit screen made, it goes back to that step's source \
      and keeps the look the step records, changing only the crop; for any other step the look is \
      no change. Coordinates are always the source image's pixels from its top left, never the \
      cropped step's: call get_image on the source step (the source_step this tool returns) to see \
      what you're cropping. Pass `x`, `y`, `width` and `height` (inside the image, at least 16 \
      pixels a side); or `aspect` for the largest centered crop of that ratio (original, 1:1, 4:5, \
      5:4, 2:3, 3:2, 3:4, 4:3, 9:16, 16:9); or `clear: true` to take the crop off. The crop goes \
      before the look, so a vignette centers on it and grain is sized to the cropped frame. Runs \
      as a job in the Queue on this device: by default it waits and returns history_step, \
      source_step, crop ({x, y, width, height} in the source's pixels, or null), width, height \
      and job_id; with background: true it returns a job_id at once for get_job. The same edit \
      already waiting or running isn't queued twice. Leaves the Edit screen as the user has it. \
      Not for videos.
      """,
    "inputSchema": [
      "type": "object",
      "properties": [
        "history_step": ["type": "integer", "description": "A history step from list_history or generate. Omit for the canvas image."],
        "x": ["type": "number", "description": "The crop's left edge, in the source's pixels."],
        "y": ["type": "number", "description": "The crop's top edge, in the source's pixels."],
        "width": ["type": "number", "description": "The crop's width in pixels (at least 16)."],
        "height": ["type": "number", "description": "The crop's height in pixels (at least 16)."],
        "aspect": ["type": "string", "description": "Instead of a rectangle: the largest centered crop of this ratio: original, 1:1, 4:5, 5:4, 2:3, 3:2, 3:4, 4:3, 9:16 or 16:9."],
        "anchor": ["type": "string", "enum": ["center"], "description": "Where an `aspect` crop sits: center (the only choice, and the default)."],
        "clear": ["type": "boolean", "description": "Take the crop off: the whole source with the step's look."],
        "background": ["type": "boolean", "description": "Return a job_id at once instead of waiting. Default false."],
      ],
    ],
  ]

  /// crop_image: its arguments read, then `edit_image_look`'s path with only the crop changed.
  func cropImage(_ arguments: [String: Any], progress: @escaping (Progress) -> Void) async throws -> [String: Any] {
    let change = try CropArguments.parse(arguments)
    var look: [String: Any] = [:]
    for key in ["history_step", "background"] where arguments[key] != nil { look[key] = arguments[key] }
    return try await editImageLook(look, crop: change, progress: progress)
  }

  /// A crop for answers, in the source's pixels.
  nonisolated static func cropJSON(_ crop: Edit.Crop) -> [String: Any] {
    var json: [String: Any] = ["x": crop.x, "y": crop.y, "width": crop.width, "height": crop.height]
    if let aspect = crop.aspect { json["aspect"] = aspect.label(swapped: crop.swapped) }
    return json
  }
}
#endif
