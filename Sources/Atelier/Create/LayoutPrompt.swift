import CoreGraphics
import Foundation

/// A layout prompt: a caption plus boxes, each with what goes in it. The models that read one take
/// it as prompt text, each in its own format, so the prompt itself is where a layout is kept:
/// `prompt(_:width:height:)` writes it and `init?(prompt:format:width:height:)` reads it back.
struct LayoutPrompt: Equatable {
  /// The models that read layouts, and how each writes one.
  enum Format: Equatable {
    /// A caption citing `<id>` tags, a space, then `[{"id", "bbox", "desc"}, …]`. Boxes are
    /// `[top, left, bottom, right]` on a 0 to 1000 grid.
    case flux3
    /// Ideogram's JSON prompt (what Draw Things' Magic Prompt writes), with `obj` and `text`
    /// elements boxed `[y1, x1, y2, x2]` on a 0 to 1000 grid.
    case ideogram4
    /// MOSS Image's layout JSON: boxes in pixels from the image's center, `[y1, x1, y2, x2]`.
    case moss

    /// From MGK's version name.
    init?(version: String?) {
      switch version {
      case "FLUX.3 5B": self = .flux3
      case "Ideogram 4": self = .ideogram4
      case "MOSS Image": self = .moss
      default: return nil
      }
    }

    var kinds: [Item.Kind] { self == .moss ? [.object, .character, .text] : [.object, .text] }
    /// Ideogram describes the background on its own.
    var hasBackground: Bool { self == .ideogram4 }
    /// FLUX 3's caption cites boxes by id.
    var citesIDs: Bool { self == .flux3 }
  }

  struct Item: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
      case object, character, text

      var title: String { rawValue.capitalized }
    }

    var id = UUID()
    /// The id FLUX 3's caption cites, such as `dog_1`.
    var name: String
    var kind: Kind
    /// In the unit square, from the top left.
    var rect: CGRect
    var description = ""
    /// For text boxes, the exact words to show.
    var text = ""
    /// MOSS fields Atelier doesn't edit, kept as their JSON so they survive a round trip.
    var extras: [String: String] = [:]
  }

  var caption = ""
  var background = ""
  var items: [Item] = []
  /// MOSS summary fields Atelier doesn't edit (`meta`, `canvas`, `palette`), as JSON.
  var summaryExtras: [String: String] = [:]

  init(caption: String = "") {
    self.caption = caption
  }

  /// An unused id for a new box of `kind`: `object_1`, `object_2`…
  func newName(for kind: Item.Kind) -> String {
    let names = Set(items.map(\.name))
    var index = 1
    while names.contains("\(kind.rawValue)_\(index)") { index += 1 }
    return "\(kind.rawValue)_\(index)"
  }

  // MARK: Writing

  /// The prompt text for `format` at `width` × `height` pixels.
  func prompt(_ format: Format, width: Int, height: Int) -> String {
    switch format {
    case .flux3: fluxPrompt
    case .ideogram4: ideogramPrompt(width: width, height: height)
    case .moss: mossPrompt(width: width, height: height)
    }
  }

  private var fluxPrompt: String {
    let rows = items.map { item in
      var description = item.description
      if item.kind == .text {
        // FLUX 3 puts the words in quotes at the start of the description.
        description = "\"\(item.text)\"" + (description.isEmpty ? "" : " \(description)")
      }
      return "{\"id\": \(Self.encode(item.name)), \"bbox\": \(Self.grid(item.rect, separator: ", ")), "
        + "\"desc\": \(Self.encode(description))}"
    }
    let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rows.isEmpty else { return caption }
    let list = "[\(rows.joined(separator: ", "))]"
    return caption.isEmpty ? list : "\(caption) \(list)"
  }

  private func ideogramPrompt(width: Int, height: Int) -> String {
    let elements = items.map { item in
      var fields = [
        "\"type\":\(Self.encode(item.kind == .text ? "text" : "obj"))",
        "\"bbox\":\(Self.grid(item.rect, separator: ","))",
      ]
      if item.kind == .text { fields.append("\"text\":\(Self.encode(item.text))") }
      fields.append("\"desc\":\(Self.encode(item.description))")
      return "{\(fields.joined(separator: ","))}"
    }
    return "{\"aspect_ratio\":\(Self.encode(Self.aspectRatio(width: width, height: height))),"
      + "\"high_level_description\":\(Self.encode(caption)),"
      + "\"compositional_deconstruction\":{"
      + "\"background\":\(Self.encode(background)),"
      + "\"elements\":[\(elements.joined(separator: ","))]}}"
  }

  private func mossPrompt(width: Int, height: Int) -> String {
    var summary = summaryExtras.filter { $0.key != "palette" }.sorted { $0.key < $1.key }
      .map { "\(Self.encode($0.key)):\($0.value)" }
    summary.append("\"caption\":\(Self.encode(caption))")
    if let palette = summaryExtras["palette"] { summary.append("\"palette\":\(palette)") }
    let rows = items.map { item in
      var fields = [
        "\"label\":\(Self.encode(item.kind.rawValue))",
        "\"caption\":\(Self.encode(item.description))",
      ]
      if item.kind == .text { fields.append("\"text\":\(Self.encode(item.text))") }
      fields += item.extras.sorted { $0.key < $1.key }.map { "\(Self.encode($0.key)):\($0.value)" }
      fields.append("\"bbox\":\(Self.centered(item.rect, width: width, height: height))")
      return "{\(fields.joined(separator: ","))}"
    }
    return "{\"summary\":{\(summary.joined(separator: ","))},\"items\":[\(rows.joined(separator: ","))],"
      + "\"bbox_coord_space\":\"abs_centralized\",\"bbox_format\":\"yxyx\"}"
  }

  /// `[top, left, bottom, right]` on the 0 to 1000 grid.
  private static func grid(_ rect: CGRect, separator: String) -> String {
    let rect = rect.standardized
    return "[" + [rect.minY, rect.minX, rect.maxY, rect.maxX]
      .map { String(Int(($0 * 1000).rounded()).clamped(to: 0...1000)) }
      .joined(separator: separator) + "]"
  }

  /// `[top, left, bottom, right]` in pixels from the center, the edges taken outward to whole
  /// pixels first, as MOSS' own prompt compiler does.
  private static func centered(_ rect: CGRect, width: Int, height: Int) -> String {
    let rect = rect.standardized
    // Rounded to a millionth of a pixel first, so a box read back from whole pixels stays put.
    func pixels(_ value: Double, _ size: Int) -> Double { (value * Double(size) * 1e6).rounded() / 1e6 }
    let top = Int(pixels(rect.minY, height).rounded(.down)) - height / 2
    let left = Int(pixels(rect.minX, width).rounded(.down)) - width / 2
    let bottom = max(Int(pixels(rect.maxY, height).rounded(.up)) - height / 2, top + 1)
    let right = max(Int(pixels(rect.maxX, width).rounded(.up)) - width / 2, left + 1)
    return "[\(top),\(left),\(bottom),\(right)]"
  }

  static func aspectRatio(width: Int, height: Int) -> String {
    guard width > 0, height > 0 else { return "1:1" }
    var (lhs, rhs) = (width, height)
    while rhs != 0 { (lhs, rhs) = (rhs, lhs % rhs) }
    return "\(width / lhs):\(height / lhs)"
  }

  private static func encode(_ value: Any) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    else { return "\"\"" }
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: Reading

  /// Reads a prompt written in `format`; nil when it isn't a layout.
  init?(prompt: String, format: Format, width: Int, height: Int) {
    switch format {
    case .flux3: self.init(fluxPrompt: prompt)
    case .ideogram4: self.init(ideogramPrompt: prompt)
    case .moss: self.init(mossPrompt: prompt, width: width, height: height)
    }
  }

  private init?(fluxPrompt prompt: String) {
    // The list is the last thing in the prompt: try each `[{` from the first until the rest parses.
    var searchStart = prompt.startIndex
    while let start = prompt.range(of: "[{", range: searchStart..<prompt.endIndex)?.lowerBound {
      searchStart = prompt.index(after: start)
      guard let rows = Self.parse(String(prompt[start...])) as? [[String: Any]] else { continue }
      var items: [Item] = []
      for row in rows {
        guard let rect = Self.rect(row["bbox"], scale: 1000), let description = row["desc"] as? String
        else { break }
        var item = Item(
          name: row["id"] as? String ?? "", kind: .object, rect: rect, description: description)
        // A description that opens with quoted words is a text box.
        if description.hasPrefix("\""),
           let close = description.dropFirst().firstIndex(of: "\"")
        {
          item.kind = .text
          item.text = String(description[description.index(after: description.startIndex)..<close])
          item.description = description[description.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        }
        items.append(item)
      }
      guard items.count == rows.count, !items.isEmpty else { continue }
      self.caption = prompt[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
      self.items = items
      for index in self.items.indices where self.items[index].name.isEmpty {
        self.items[index].name = newName(for: self.items[index].kind)
      }
      return
    }
    return nil
  }

  private init?(ideogramPrompt prompt: String) {
    guard let object = Self.parse(prompt) as? [String: Any],
          let composition = object["compositional_deconstruction"] as? [String: Any],
          let elements = composition["elements"] as? [[String: Any]]
    else { return nil }
    caption = object["high_level_description"] as? String ?? ""
    background = composition["background"] as? String ?? ""
    for element in elements {
      let kind: Item.Kind = element["type"] as? String == "text" ? .text : .object
      // Elements without a box (crowds, starry skies) get the whole frame.
      let rect = Self.rect(element["bbox"], scale: 1000) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
      items.append(
        Item(
          name: newName(for: kind), kind: kind, rect: rect,
          description: element["desc"] as? String ?? "", text: element["text"] as? String ?? ""))
    }
  }

  private init?(mossPrompt prompt: String, width: Int, height: Int) {
    guard width > 0, height > 0, let object = Self.parse(prompt) as? [String: Any],
          let summary = object["summary"] as? [String: Any],
          let rows = object["items"] as? [[String: Any]]
    else { return nil }
    caption = summary["caption"] as? String ?? ""
    for (key, value) in summary where key != "caption" { summaryExtras[key] = Self.encode(value) }
    let centered = object["bbox_coord_space"] as? String != "abs"
    let yxyx = object["bbox_format"] as? String != "xyxy"
    for row in rows {
      guard let box = row["bbox"] as? [NSNumber], box.count == 4 else { return nil }
      var values = box.map(\.doubleValue)
      if !yxyx { values = [values[1], values[0], values[3], values[2]] }
      if centered {
        values = [
          values[0] + Double(height / 2), values[1] + Double(width / 2),
          values[2] + Double(height / 2), values[3] + Double(width / 2),
        ]
      }
      let rect = CGRect(
        x: values[1] / Double(width), y: values[0] / Double(height),
        width: (values[3] - values[1]) / Double(width), height: (values[2] - values[0]) / Double(height))
      let kind = Item.Kind(rawValue: row["label"] as? String ?? "") ?? .object
      var item = Item(
        name: newName(for: kind), kind: kind, rect: rect, description: row["caption"] as? String ?? "",
        text: row["text"] as? String ?? "")
      for (key, value) in row where !["label", "caption", "text", "bbox"].contains(key) {
        item.extras[key] = Self.encode(value)
      }
      items.append(item)
    }
  }

  private static func parse(_ text: String) -> Any? {
    try? JSONSerialization.jsonObject(
      with: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8), options: [.json5Allowed])
  }

  /// A `[top, left, bottom, right]` box on a `scale` grid, in the unit square.
  private static func rect(_ value: Any?, scale: Double) -> CGRect? {
    guard let box = value as? [NSNumber], box.count == 4 else { return nil }
    let v = box.map { $0.doubleValue / scale }
    return CGRect(x: v[1], y: v[0], width: v[3] - v[1], height: v[2] - v[0]).standardized
  }
}

private extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
