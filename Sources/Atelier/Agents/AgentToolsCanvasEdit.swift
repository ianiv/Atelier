#if os(macOS)
import CoreGraphics
import Foundation

/// The tools for fixing part of an image without a person pointing at it: finding a face, moving
/// the mask's edge, and choosing the frame around a box. They name what to work on (a box, the
/// mask's bounds) and leave the arithmetic to the app (`FaceFinder`, `MaskMorphology`,
/// `FrameSelection`), where the canvas tools in `AgentTools.swift` take the numbers themselves.
extension AgentTools {
  static let canvasEditDefinitions: [[String: Any]] = [
    [
      "name": "find_faces",
      "title": "Find faces",
      "description": """
        Finds the faces in an image with Apple's Vision (nothing to download): the canvas image, \
        or `history_step`'s, which leaves the canvas alone. Returns source_size and `faces`, \
        largest first, in the image's pixels from its top left: `box` (it runs from about the \
        brows to the chin, not the whole head: pad it, as set_canvas_frame does, and grow a mask \
        made from it), `center`, `confidence`, `roll` and `yaw` (the head's tilt and turn in \
        degrees, when known) and `landmarks` (left_eye, right_eye, nose, outer_lips and \
        face_contour as [x, y] points; left and right are the image's). A face that is a small \
        part of a large image can be missed: pass `region` around the head to search only there, \
        at its own resolution. With no face found it fails with an error saying so (there is no \
        empty list to check for). To redo a face on the canvas: mask it (set_canvas_mask with an \
        ellipse over `box`, or auto_mask with a point at `center`), grow_canvas_mask, \
        set_canvas_frame with the box and a `scale`, optionally set_canvas_paint to fill the \
        mask and set_moodboard for a reference face, then generate with use_canvas. Or pass the \
        box to edit_image, which does all of it in one call without touching the Create screen.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "history_step": ["type": "integer", "description": "A history step (see list_history; images only). Omit for the canvas image."],
          "region": [
            "type": "object", "required": ["x", "y", "width", "height"],
            "description": "Search only this part of the image (its pixels from the top left). The faces still come back in the whole image's pixels.",
            "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
          ],
          "max_faces": ["type": "integer", "description": "How many faces to return at most, largest first. Default 10."],
        ],
      ],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "grow_canvas_mask",
      "title": "Grow or shrink the canvas mask",
      "description": """
        Grows the canvas mask by `pixels` on every side (a round brush run along its edge), or \
        with a negative number shrinks it: a mask from auto_mask or a face's box usually wants a \
        few dozen pixels more, so the run can blend the edit into its surroundings. `pixels` are \
        the canvas image's pixels, up to 512 either way. The mask is hard-edged; for a soft edge \
        set the Mask Blur settings (set_create_screen `settings` {"maskBlur": …, \
        "maskBlurOutset": …}), which a run applies in the frame's pixels. One ⌘Z step, “Agent \
        Mask”. Returns the mask summary (get_canvas_mask's) with grown_by. Needs a mask on the \
        canvas (set_canvas_mask, auto_mask).
        """,
      "inputSchema": [
        "type": "object",
        "required": ["pixels"],
        "properties": [
          "pixels": ["type": "integer", "minimum": -512, "maximum": 512, "description": "How far to move the mask's edge out, in the canvas image's pixels. Negative moves it in."]
        ],
      ],
    ],
    [
      "name": "set_canvas_frame",
      "title": "Frame part of the canvas image",
      "description": """
        Puts the frame around part of the canvas image, working out the region and the output \
        size for you: `box` (default: the mask's bounds) is padded (`padding` pixels, or \
        `padding_ratio` of its longer side, default 0.25), grown about its center to \
        `aspect_ratio` (default: the output's shape), never cropped, and moved (not shrunk) to \
        stay inside the image. Then the output size: `width` and `height`; or `scale`, frame \
        pixels per image pixel, which sizes the output to the region at exactly that zoom (a \
        912×1152 region at scale 4 is a 3648×4608 output), sides rounded up to multiples of 64 \
        and the region grown to match; or neither, \
        which keeps the output size (its pixel count, when `aspect_ratio` changes its shape). An \
        Edit run then regenerates that region at the output's resolution and, with Merge into \
        Image, puts it back into the whole image. Give the model a few megapixels: a face \
        250 pixels wide wants a scale of 4 or more. A changed output size is one ⌘Z step, “Agent \
        Settings”; the zoom isn't undoable, as with set_canvas_region. Returns the canvas as \
        get_create_screen's `canvas` describes it (`region` is what the frame shows, with \
        `frame` and `scale`), plus requested_box, padded_box, clamped and notes.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "box": [
            "type": "object", "required": ["x", "y", "width", "height"],
            "description": "What to frame, in the canvas image's pixels from its top left: a face's box from find_faces, say. Default: the mask's bounds.",
            "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
          ],
          "padding": ["type": "number", "description": "Image pixels to add on every side of the box. Instead of padding_ratio."],
          "padding_ratio": ["type": "number", "description": "Padding as a share of the box's longer side. Default 0.25."],
          "aspect_ratio": ["type": ["string", "number"], "description": "The region's shape, width over height: \"W:H\" (\"3:4\") or a number (0.75). Default: the output's shape (`width`:`height` when given)."],
          "width": ["type": "integer", "description": "The output width in pixels, rounded to a multiple of 64. With `height`; not with `scale`."],
          "height": ["type": "integer", "description": "The output height in pixels, rounded to a multiple of 64."],
          "scale": ["type": "number", "description": "Frame pixels per image pixel, 0.05–32: the output is the region at this zoom. Instead of `width` and `height`."],
          "stay_inside_image": ["type": "boolean", "description": "Move the region to lie inside the image where it fits (the default). False leaves it centered on the box, past the image's edges if need be (an Edit run fills in what's outside)."],
        ],
      ],
    ],
    [
      "name": "get_moodboard",
      "title": "Get moodboard",
      "description": """
        Lists the Create screen's moodboard, the reference images that go with a run on models \
        that take them (see list_models): `images` in order, each with `position` (1 is first), \
        `id`, `width`, `height`, `weight` (0–1; 0 keeps it on the board but leaves it out of \
        runs), `sent` and `picture`, the number a prompt calls it by (“Picture 2”): images are \
        numbered in order, counting only those sent, after the canvas when an Edit run sends it \
        too (`canvas_is_picture_1`). Also model_takes_references for the selected model, with a \
        note when it takes none. The moodboard belongs to the app, not to a project. With \
        include_images, each image comes back too, in order, as a small thumbnail.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "include_images": ["type": "boolean", "description": "Also return each image, in order, scaled to 256 px on its long side. Default false."]
        ],
      ],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "set_moodboard",
      "title": "Change the moodboard",
      "description": """
        Changes the Create screen's moodboard: the reference images sent with the next run \
        (generate with use_canvas, or the user's Generate) on models that take them. Applied in \
        order: `clear`; `remove` (ids, or positions as they were before the call); `add` (each \
        {"image": a path or data: URL} or {"history_step": N}, with `weight`, default 1, and \
        `position`, default the end); `weights` ({"id" or "position", "weight"}, positions as \
        before the call); `order` (every image's id, in the new order). The order is what a \
        prompt's Picture numbers count: with an image on the canvas in Edit the canvas is \
        Picture 1 and the first moodboard image Picture 2, so a prompt can say “the face from \
        Picture 2”. Images are scaled down to 1536 px on the long side. The whole call is one ⌘Z step, “Agent Moodboard”. Returns the moodboard \
        as get_moodboard lists it, with a note when the selected model takes no reference \
        images (they stay on the board but aren't sent).
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "clear": ["type": "boolean", "description": "Empty the moodboard, first."],
          "remove": [
            "type": "array", "description": "Images to take off: ids (see get_moodboard), or positions as before the call (1 is first).",
            "items": ["type": ["string", "integer"]],
          ],
          "add": [
            "type": "array",
            "description": "Images to add, in order: {\"image\": path or data: URL} or {\"history_step\": N}, each with an optional `weight` (0–1, default 1) and `position` (where it goes in the board as it then is, 1 is first; default the end). A bare path or data: URL works too.",
            "items": [
              "anyOf": [
                ["type": "string"],
                [
                  "type": "object",
                  "properties": [
                    "image": ["type": "string"], "history_step": ["type": "integer"],
                    "weight": ["type": "number", "minimum": 0, "maximum": 1], "position": ["type": "integer", "minimum": 1],
                  ],
                ],
              ]
            ],
          ],
          "weights": [
            "type": "array", "description": "Weights to set: {\"id\" or \"position\" (as before the call), \"weight\": 0–1}. 0 leaves an image on the board but out of runs.",
            "items": [
              "type": "object", "required": ["weight"],
              "properties": ["id": ["type": "string"], "position": ["type": "integer"], "weight": ["type": "number", "minimum": 0, "maximum": 1]],
            ],
          ],
          "order": ["type": "array", "items": ["type": "string"], "description": "Every image's id once, in the new order, last. Images added in the same call have no id yet: place them with `position`."],
        ],
      ],
    ],
  ]

  // MARK: - Arguments

  /// A rectangle argument, {"x", "y", "width", "height"} in an image's pixels.
  nonisolated static func rect(_ value: Any?, named name: String) throws -> CGRect {
    guard let object = value as? [String: Any], let x = double(object["x"]), let y = double(object["y"]),
          let width = double(object["width"]), let height = double(object["height"])
    else { throw ToolError("`\(name)` is {\"x\", \"y\", \"width\", \"height\"} in the image's pixels (from its top left).") }
    guard width > 0, height > 0 else { throw ToolError("`\(name)` has no size: width and height must be above 0.") }
    return CGRect(x: x, y: y, width: width, height: height)
  }

  /// A shape argument, width over height: "W:H" or a number.
  nonisolated static func aspectRatio(_ value: Any) throws -> Double {
    var ratio: Double?
    if let text = value as? String {
      let parts = text.split(whereSeparator: { ":/x×".contains($0) }).map { Double($0.trimmingCharacters(in: .whitespaces)) }
      if parts.count == 2, let width = parts[0], let height = parts[1], height > 0 {
        ratio = width / height
      } else if parts.count == 1 {
        ratio = parts[0]
      }
    } else if !isBoolean(value) {
      ratio = (value as? NSNumber)?.doubleValue
    }
    guard let ratio, ratio.isFinite, ratio >= 0.1, ratio <= 10 else {
      throw ToolError("`aspect_ratio` is width over height, as \"W:H\" (\"3:4\") or a number (0.75), between 1:10 and 10:1.")
    }
    return ratio
  }

  // MARK: - find_faces

  func findFaces(_ arguments: [String: Any]) async throws -> [String: Any] {
    if arguments["history_step"] != nil, Self.int(arguments["history_step"]) == nil {
      throw ToolError("`history_step` is a history step number (see list_history).")
    }
    let image: CGImage
    if let step = Self.int(arguments["history_step"]) {
      guard let item = create.history.items.first(where: { $0.id.logicalTime == step }) else {
        throw ToolError("No history step \(step) in “\(create.history.project.name)”. See list_history.")
      }
      guard !item.isVideo else { throw ToolError("History step \(step) is a video; find_faces takes images.") }
      guard item.hasImage, let loaded = await create.history.image(for: item) else {
        throw ToolError("Couldn't read history step \(step)'s image.")
      }
      image = loaded
    } else {
      image = try canvasImage()
    }
    let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var region: CGRect?
    if let value = arguments["region"] {
      let rect = try Self.rect(value, named: "region")
      guard rect.intersects(imageRect) else {
        throw ToolError("`region` doesn't overlap the \(image.width)×\(image.height) image (its pixels from the top left).")
      }
      region = rect
    }
    var limit = 10
    if let value = arguments["max_faces"] {
      guard !Self.isBoolean(value), let given = Self.int(value), given >= 1 else {
        throw ToolError("`max_faces` is how many faces to return at most, 1 or more (10 by default).")
      }
      limit = given
    }
    // Vision takes a moment on a large image: off the main actor, as Select Subject runs.
    let searched = region
    let faces = try await Task.detached(priority: .userInitiated) { try FaceFinder.faces(in: image, region: searched) }.value
    guard !faces.isEmpty else {
      throw ToolError(
        region == nil
          ? "No faces found. Small faces can be missed: pass `region` around the head (see get_image)."
          : "No faces found in `region`. Check where the head is (get_image), or try a tighter region around it.")
    }
    func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    func point(_ point: CGPoint) -> [Double] { [rounded(point.x), rounded(point.y)] }
    let listed = faces.prefix(limit).map { face -> [String: Any] in
      [
        "box": Self.json(face.box.integral),
        "center": point(CGPoint(x: face.box.midX, y: face.box.midY)),
        "confidence": Double(face.confidence),
        "roll": face.roll.map { rounded($0 * 180 / .pi) } ?? NSNull(),
        "yaw": face.yaw.map { rounded($0 * 180 / .pi) } ?? NSNull(),
        "landmarks": face.landmarks.mapValues { $0.map(point) },
      ]
    }
    var result: [String: Any] = ["source_size": Self.json(imageRect.size), "faces": listed]
    if faces.count > limit { result["note"] = "\(faces.count) faces found; the largest \(limit) are listed (max_faces)." }
    return try Self.textResult(json: result)
  }

  // MARK: - grow_canvas_mask

  func growCanvasMask(_ arguments: [String: Any]) async throws -> [String: Any] {
    guard let value = arguments["pixels"], !Self.isBoolean(value), let amount = Self.double(value), amount.isFinite,
          amount.rounded() != 0, abs(amount.rounded()) <= 512
    else {
      throw ToolError("`pixels` is how far to move the mask's edge, in the canvas image's pixels: 1 to 512 grows it, -1 to -512 shrinks it.")
    }
    let pixels = Int(amount.rounded())
    await Self.settleUndo()
    let image = try canvasImage()
    guard create.canEditMask else { throw ToolError(maskUnavailableReason()) }
    guard let mask = create.canvasMask, mask.mayHavePaint else {
      throw ToolError("The mask is empty: paint one with set_canvas_mask or auto_mask first.")
    }
    // Growing paints, which a server with an older Atelier can't take; shrinking only takes away.
    if pixels > 0, !create.canPaintMask {
      throw ToolError(
        "\(create.runTargetServerName ?? "The server") can't take masks: its Atelier is older. Run on this device (Run on in the app), or only shrink or clear the mask.")
    }
    // Rasterizing the mask and the distance transform take a while on a large image: off the main
    // actor, as the Select tool's selections are worked out.
    let width = image.width, height = image.height
    let (grown, painted) = await Task.detached(priority: .userInitiated) { () -> (CanvasMask?, Int) in
      let coverage = mask.coverage(width: width, height: height)
      let painted = coverage.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
      guard painted > 0 else { return (nil, 0) }
      return (mask.grown(by: pixels, width: width, height: height, from: coverage)?.mask, painted)
    }.value
    guard painted > 0 else { throw ToolError("The mask is empty: paint one with set_canvas_mask or auto_mask first.") }
    guard let grown else {
      throw ToolError("Shrinking by \(-pixels) px leaves nothing. Shrink by less, or clear the mask with set_canvas_mask.")
    }
    // After the wait, before the mask it replaces is read again: it must still be the one grown.
    await Self.settleUndo()
    guard create.canvasShowsImage, create.image === image, create.canvasMask == mask, create.canEditMask else {
      throw ToolError("The canvas or its mask changed meanwhile. Call grow_canvas_mask again.")
    }
    Self.asOneUndoStep { create.setMask(grown, actionName: CreateModel.agentMaskActionName, undoManager: $0) }
    var result = maskSummary()
    result["grown_by"] = pixels
    return try Self.textResult(json: result)
  }

  // MARK: - set_canvas_frame

  func setCanvasFrame(_ arguments: [String: Any]) async throws -> [String: Any] {
    await Self.settleUndo()
    let image = try canvasImage()
    let sourceSize = CGSize(width: image.width, height: image.height)
    let sourceRect = CGRect(origin: .zero, size: sourceSize)
    guard var configuration = create.settings else { throw ToolError("The Create screen has no output size yet.") }

    let box: CGRect
    if let value = arguments["box"] {
      box = try Self.rect(value, named: "box")
      guard box.intersects(sourceRect) else {
        throw ToolError("`box` doesn't overlap the \(image.width)×\(image.height) canvas image (its pixels from the top left).")
      }
    } else if let bounds = create.canvasMaskStats?.bounds {
      box = bounds
    } else {
      throw ToolError("The mask is empty, so there's nothing to frame: pass `box` or paint a mask.")
    }
    if arguments["padding"] != nil, arguments["padding_ratio"] != nil {
      throw ToolError("Pass `padding` (image pixels) or `padding_ratio` (a share of the box's longer side), not both.")
    }
    let padding: Double
    if let value = arguments["padding"] {
      guard !Self.isBoolean(value), let pixels = Self.double(value), pixels >= 0, pixels.isFinite else {
        throw ToolError("`padding` is image pixels, 0 or more.")
      }
      padding = pixels
    } else {
      var ratio = 0.25
      if let value = arguments["padding_ratio"] {
        guard !Self.isBoolean(value), let given = Self.double(value), given >= 0, given.isFinite else {
          throw ToolError("`padding_ratio` is a share of the box's longer side, 0 or more (0.25 by default).")
        }
        ratio = given
      }
      padding = ratio * max(box.width, box.height)
    }
    let width = Self.int(arguments["width"]), height = Self.int(arguments["height"])
    let scale = arguments["scale"].flatMap { Self.isBoolean($0) ? nil : Self.double($0) }
    if width != nil || height != nil, scale != nil || arguments["scale"] != nil {
      throw ToolError("Pass `width` and `height`, or `scale`, not both.")
    }
    guard (width == nil) == (height == nil), (width ?? 1) > 0, (height ?? 1) > 0 else {
      throw ToolError("Pass `width` and `height` together, both above 0.")
    }
    if arguments["scale"] != nil {
      guard let scale, CanvasState.range.contains(scale) else {
        throw ToolError("`scale` must be 0.05–32 (frame pixels per image pixel).")
      }
    }
    let aspect = try arguments["aspect_ratio"].map(Self.aspectRatio)
    if let stays = arguments["stay_inside_image"], !Self.isBoolean(stays) { throw ToolError("`stay_inside_image` is true or false.") }
    let staysInside = arguments["stay_inside_image"] as? Bool ?? true

    // The region: the padded box at the shape asked for, else the output's.
    let current = CGSize(width: configuration.width, height: configuration.height)
    let given = width.flatMap { width in height.map { CGSize(width: Self.roundTo64(width), height: Self.roundTo64($0)) } }
    let shape = aspect ?? (given ?? current).width / (given ?? current).height
    let padded = box.insetBy(dx: -padding, dy: -padding)
    var region = FrameSelection.region(around: box, padding: padding, aspect: shape, inside: staysInside ? sourceSize : nil)
    // The output size for it. With nothing asked that changes it, it stays exactly as it is.
    let frame: CGSize
    if given == nil, scale == nil, aspect == nil {
      frame = current
      region = CanvasPlacement.grown(region, toShapeOf: current)
    } else {
      let sized = FrameSelection.frame(
        for: region, width: width, height: height, scale: scale, pixelCount: Double(configuration.width * configuration.height))
      frame = sized.size
      region = sized.region
    }
    // Rounding the size to 64 can have moved the region's edges: back inside, without resizing it.
    if staysInside { region = FrameSelection.region(around: region, padding: 0, aspect: 0, inside: sourceSize) }
    let placement = FrameSelection.placement(showing: region, sourceSize: sourceSize, frameSize: frame)

    var notes: [String] = []
    if Int(frame.width) != configuration.width || Int(frame.height) != configuration.height {
      configuration.width = Int(frame.width)
      configuration.height = Int(frame.height)
      Self.asOneUndoStep { create.replaceSettings(with: configuration, actionName: "Agent Settings", undoManager: $0) }
      notes.append("The output size is now \(configuration.width)×\(configuration.height) (one ⌘Z step, “Agent Settings”).")
    }
    guard create.showRegion(region) != nil else { throw ToolError("The Create screen has no output size yet.") }

    var result = canvasState()
    result["requested_box"] = Self.json(box)
    result["padded_box"] = Self.json(padded)
    result["clamped"] = placement.clamped
    if placement.clamped {
      notes.append(
        "Showing that region needs a zoom outside the canvas's 0.05×–32×, so the frame shows `region` instead. Pass a larger `box` or more padding, or a smaller output size.")
    }
    if result["extends_past_image"] as? Bool == true {
      notes.append("The frame reaches past the image's edges: an Edit run fills in what's outside, and with Merge into Image the image grows to hold it.")
    }
    if let bounds = create.canvasMaskStats?.bounds, let crop = create.canvasPlacement?.cropRect,
       !crop.insetBy(dx: -1, dy: -1).contains(bounds)
    {
      notes.append("The mask reaches outside the region the frame shows: only the part inside it is regenerated.")
    }
    if create.effectiveCanvasMode == .generate {
      notes.append("Runs don't take the canvas now (canvas_mode_in_effect is generate): paint a mask, lower `strength`, or set canvas_mode edit.")
    }
    if !notes.isEmpty { result["notes"] = notes }
    return try Self.textResult(json: result)
  }

  // MARK: - Moodboard

  /// The moodboard as get_moodboard lists it (and get_create_screen's `moodboard`): the images in
  /// order, and how a prompt numbers them.
  func moodboardState() -> [String: Any] {
    let takes = create.usesReferences
    // As the moodboard column numbers them (`MoodboardColumn.role`): an Edit run's canvas is the
    // first picture, the board's images the ones after.
    let canvasSent = create.effectiveCanvasMode == .edit && create.image != nil && create.canvasClip == nil
    var number = canvasSent ? 1 : 0
    let images = create.moodboard.items.enumerated().map { index, item -> [String: Any] in
      let sent = item.weight > 0
      if sent { number += 1 }
      return [
        "position": index + 1, "id": item.id.uuidString, "width": item.image.width, "height": item.image.height,
        "weight": Double(item.weight), "sent": sent, "picture": sent ? number : NSNull(),
      ]
    }
    var state: [String: Any] = ["images": images, "model_takes_references": takes, "canvas_is_picture_1": canvasSent]
    if !takes {
      state["note"] =
        "\(create.selectedModel ?? "The selected model") doesn't take reference images (see list_models), so runs with it leave the moodboard out."
    }
    return state
  }

  func getMoodboard(_ arguments: [String: Any]) throws -> [String: Any] {
    if let include = arguments["include_images"], !Self.isBoolean(include) { throw ToolError("`include_images` is true or false.") }
    var result = try Self.textResult(json: moodboardState())
    guard arguments["include_images"] as? Bool == true, var content = result["content"] as? [[String: Any]] else { return result }
    for item in create.moodboard.items {
      if let preview = Self.jpeg(ImageLoader.fitted(item.image, maxSide: 256)) {
        content.append(["type": "image", "data": preview.base64EncodedString(), "mimeType": "image/jpeg"])
      }
    }
    result["content"] = content
    return result
  }

  func setMoodboard(_ arguments: [String: Any]) async throws -> [String: Any] {
    if let clear = arguments["clear"], !Self.isBoolean(clear) { throw ToolError("`clear` is true or false.") }
    let clear = arguments["clear"] as? Bool == true
    func list(_ name: String) throws -> [Any]? {
      guard let value = arguments[name] else { return nil }
      guard let list = value as? [Any] else { throw ToolError("`\(name)` is an array.") }
      return list
    }
    let remove = try list("remove"), add = try list("add"), weights = try list("weights"), order = try list("order")
    guard clear || remove != nil || add != nil || weights != nil || order != nil else {
      throw ToolError("Pass `add`, `remove`, `weights`, `order` or `clear`.")
    }
    func weight(_ value: Any?, default fallback: Float? = nil) throws -> Float {
      guard let value else {
        if let fallback { return fallback }
        throw ToolError("`weight` is 0-1.")
      }
      guard !Self.isBoolean(value), let weight = Self.double(value), (0...1).contains(weight) else { throw ToolError("`weight` is 0-1.") }
      return Float(weight)
    }
    // The images to add are read first: loading one from History waits, and nothing may wait
    // between reading the board and changing it.
    var added: [(item: MoodboardItem, position: Int?)] = []
    for (index, entry) in (add ?? []).enumerated() {
      let object = entry as? [String: Any]
      let source = (entry as? String) ?? (object?["image"] as? String)
      let step = Self.int(object?["history_step"])
      guard (source == nil) != (step == nil) else {
        throw ToolError("Image \(index + 1) in `add` is {\"image\": a path or data: URL} or {\"history_step\": N}, with an optional `weight` and `position`.")
      }
      let image: CGImage
      if let source {
        image = try Self.loadImage(source)
      } else {
        let step = step ?? 0
        guard let item = create.history.items.first(where: { $0.id.logicalTime == step }) else {
          throw ToolError("No history step \(step) in “\(create.history.project.name)”. See list_history.")
        }
        guard !item.isVideo else { throw ToolError("History step \(step) is a video. The moodboard takes images.") }
        guard item.hasImage, let loaded = await create.history.image(for: item) else {
          throw ToolError("Couldn't read history step \(step)'s image.")
        }
        image = loaded
      }
      var position: Int?
      if let value = object?["position"] {
        guard let given = Self.int(value), given >= 1 else { throw ToolError("`position` is where the image goes on the board, 1 for first.") }
        position = given
      }
      added.append(
        (MoodboardItem(image: ImageLoader.fitted(image, maxSide: Moodboard.maxSide), weight: try weight(object?["weight"], default: 1)), position))
    }

    await Self.settleUndo()
    let before = create.moodboard.items
    /// An image named by id, or by its position before the call.
    func named(_ value: Any?) throws -> MoodboardItem.ID {
      if let text = value as? String, Int(text) == nil {
        guard let item = before.first(where: { $0.id.uuidString.caseInsensitiveCompare(text) == .orderedSame }) else {
          throw ToolError("No moodboard image with id \(text). See get_moodboard.")
        }
        return item.id
      }
      guard let value, !Self.isBoolean(value), let position = Self.int(value) else {
        throw ToolError("A moodboard image is named by its `id` or its position (1 is first). See get_moodboard.")
      }
      guard before.indices.contains(position - 1) else { throw ToolError("No moodboard image \(position) (there are \(before.count)).") }
      return before[position - 1].id
    }
    var items = clear ? [] : before
    for entry in remove ?? [] {
      let id = try named(entry)
      items.removeAll { $0.id == id }
    }
    for entry in added {
      if let position = entry.position {
        guard position <= items.count + 1 else {
          throw ToolError("`position` \(position) is past the end: the board has \(items.count) image\(items.count == 1 ? "" : "s") then, so it's 1 to \(items.count + 1).")
        }
        items.insert(entry.item, at: position - 1)
      } else {
        items.append(entry.item)
      }
    }
    for entry in weights ?? [] {
      guard let object = entry as? [String: Any], (object["id"] == nil) != (object["position"] == nil) else {
        throw ToolError("Each of `weights` is {\"id\" or \"position\", \"weight\": 0-1}.")
      }
      let id = try named(object["id"] ?? object["position"])
      let value = try weight(object["weight"])
      guard let index = items.firstIndex(where: { $0.id == id }) else {
        throw ToolError("That moodboard image is taken off by this same call, so it has no weight to set.")
      }
      items[index].weight = value
    }
    if let order {
      let ids = try order.map { entry -> MoodboardItem.ID in
        guard let text = entry as? String, let id = items.first(where: { $0.id.uuidString.caseInsensitiveCompare(text) == .orderedSame })?.id
        else { throw ToolError("`order` must list every image once, by id (see get_moodboard).") }
        return id
      }
      guard ids.count == items.count, Set(ids).count == ids.count else { throw ToolError("`order` must list every image once, by id (see get_moodboard).") }
      items = ids.compactMap { id in items.first { $0.id == id } }
    }
    Self.asOneUndoStep { create.setMoodboard(items, actionName: CreateModel.agentMoodboardActionName, undoManager: $0) }
    return try Self.textResult(json: moodboardState())
  }
}
#endif
