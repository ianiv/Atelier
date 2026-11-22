import Foundation
@preconcurrency import ModelZoo

/// A link to a Hugging Face model repo, a folder in it or one of its files, as people paste them:
/// a page (`/<owner>/<repo>`, `/tree/<rev>/<dir>`, `/blob/<rev>/<path>`), a download
/// (`/resolve/<rev>/<path>`, with or without `?download=true`), on huggingface.co or hf.co, an
/// `hf://` path, or a bare `owner/repo`. Datasets and Spaces aren't models, so they're turned
/// away, as is any other site. The repo name is checked the way the engine reads one
/// (`ModelZoo.normalizeHuggingFaceRepo`), so a catalog match (`specificationForHuggingFaceRepo`)
/// sees the same name.
nonisolated struct HuggingFaceLink: Equatable, Sendable {
  /// `owner/name`.
  var repo: String
  /// The branch, tag or commit the link names, if any (else the repo's default branch).
  var revision: String?
  /// The folder or file the link points at, if any.
  var path: String?

  var owner: String { String(repo.split(separator: "/").first ?? "") }
  var name: String { String(repo.split(separator: "/").last ?? "") }

  static let hosts: Set<String> = ["huggingface.co", "www.huggingface.co", "hf.co"]

  /// A full link (`https://huggingface.co/…`, `https://hf.co/…` or `hf://…`), not just text that
  /// could be a repo name: only those are filled in from the clipboard and looked up unasked.
  static func isExplicitLink(_ text: String) -> Bool {
    let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let prefixes = ["https://huggingface.co/", "https://www.huggingface.co/", "https://hf.co/", "hf://"]
    return prefixes.contains { lowered.hasPrefix($0) } && parse(text) != nil
  }

  static func parse(_ text: String) -> HuggingFaceLink? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
    if trimmed.lowercased().hasPrefix("hf://") {
      return parse(components: String(trimmed.dropFirst(5)).split(separator: "/").map(String.init), hfPath: true)
    }
    let lowered = trimmed.lowercased()
    if Self.hosts.contains(where: { lowered.hasPrefix($0 + "/") }) { trimmed = "https://" + trimmed }
    if trimmed.contains("://") {
      guard let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), Self.hosts.contains(host)
      else { return nil }
      // Each part decoded on its own, so a revision like `refs%2Fpr%2F1` stays one part.
      let parts = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
      return parse(components: parts, hfPath: false)
    }
    // A bare `owner/repo`: exactly two parts.
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else { return nil }
    return parse(components: parts, hfPath: false)
  }

  private static func parse(components: [String], hfPath: Bool) -> HuggingFaceLink? {
    var parts = components.filter { !$0.isEmpty }
    if let first = parts.first?.lowercased() {
      if first == "datasets" || first == "spaces" { return nil }
      if first == "models" { parts.removeFirst() }
    }
    guard parts.count >= 2 else { return nil }
    var name = parts[1]
    var revision: String?
    // huggingface_hub's file system spells a revision `owner/repo@rev/path`.
    if hfPath, let at = name.firstIndex(of: "@") {
      revision = String(name[name.index(after: at)...]).removingPercentEncoding
      name = String(name[..<at])
    }
    if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
    guard isValidPart(parts[0]), isValidPart(name),
          let repo = ModelZoo.normalizeHuggingFaceRepo("\(parts[0])/\(name)")
    else { return nil }
    let rest = Array(parts.dropFirst(2))
    var path: String?
    if hfPath {
      path = rest.isEmpty ? nil : rest.joined(separator: "/")
    } else if let kind = rest.first, ["tree", "blob", "resolve"].contains(kind), rest.count >= 2 {
      revision = rest[1]
      path = rest.count > 2 ? rest.dropFirst(2).joined(separator: "/") : nil
    }
    return HuggingFaceLink(repo: repo, revision: revision, path: path)
  }

  /// Hugging Face names: letters, digits, `-`, `_` and `.`, not starting or ending with `-`/`.`.
  private static func isValidPart(_ part: String) -> Bool {
    guard !part.isEmpty, part.count <= 96, part != ".", part != ".." else { return false }
    return part.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" || $0 == "."
    }
  }

  /// The repo's page.
  var pageURL: URL { URL(string: "https://huggingface.co/\(repo)")! }

  /// The download URL of `path` at `revision`. A commit sha keeps it stable: the downloader resumes
  /// by this URL (its segment manifest records it), and a branch could move under a download.
  static func resolveURL(repo: String, revision: String, path: String) -> URL {
    let encoded = path.split(separator: "/").map { encode(String($0)) }.joined(separator: "/")
    return URL(string: "https://huggingface.co/\(repo)/resolve/\(encode(revision))/\(encoded)")!
  }

  static func encode(_ part: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    return part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part
  }

  /// The API URLs: the repo's info (at a revision when one is named) and its file tree.
  static func infoURL(repo: String, revision: String?) -> URL {
    if let revision {
      return URL(string: "https://huggingface.co/api/models/\(repo)/revision/\(encode(revision))")!
    }
    return URL(string: "https://huggingface.co/api/models/\(repo)")!
  }

  static func treeURL(repo: String, sha: String) -> URL {
    URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(sha)?recursive=true&expand=false")!
  }
}

/// A file in a repo, from its tree listing. Files kept in Git LFS (every weights file) have a
/// SHA-256 to check the download against; small files kept in Git only have a Git hash.
nonisolated struct HuggingFaceRepoFile: Codable, Equatable, Hashable, Sendable {
  var path: String
  var size: Int64
  var sha256: String?

  var name: String { (path as NSString).lastPathComponent }

  /// A repo path that stays inside the staging folder it's downloaded to: relative, with no `..`,
  /// `.` or empty parts. A tree listing (or an edited download.json) with anything else is ignored.
  static func isSafePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains("\0") else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
  var folder: String { (path as NSString).deletingLastPathComponent }
  var pathExtension: String { (path as NSString).pathExtension.lowercased() }
}

/// What the API says about a repo.
nonisolated struct HuggingFaceRepoInfo: Equatable, Sendable {
  /// The commit the listing is pinned to.
  var sha: String
  /// Downloads need the terms accepted on the repo's page first.
  var isGated: Bool
  var isPrivate: Bool

  /// `/api/models/<repo>` (or `/revision/<rev>`): `gated` is false, "auto" or "manual".
  static func decode(_ data: Data) throws -> HuggingFaceRepoInfo {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sha = object["sha"] as? String, !sha.isEmpty
    else { throw HuggingFaceError.unexpectedResponse }
    let gated = object["gated"]
    let isGated = (gated as? String).map { $0 != "false" } ?? ((gated as? Bool) ?? false)
    return HuggingFaceRepoInfo(sha: sha, isGated: isGated, isPrivate: (object["private"] as? Bool) ?? false)
  }

  /// One page of `/api/models/<repo>/tree/<sha>?recursive=true`: files only, with the LFS
  /// SHA-256 where there is one.
  static func decodeTree(_ data: Data) throws -> [HuggingFaceRepoFile] {
    guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw HuggingFaceError.unexpectedResponse
    }
    return items.compactMap { item in
      guard item["type"] as? String == "file", let path = item["path"] as? String,
            HuggingFaceRepoFile.isSafePath(path)
      else { return nil }
      let lfs = item["lfs"] as? [String: Any]
      let size = (lfs?["size"] as? NSNumber ?? item["size"] as? NSNumber)?.int64Value ?? 0
      return HuggingFaceRepoFile(path: path, size: size, sha256: lfs?["oid"] as? String)
    }
  }

  /// The next page of a listing, from its `Link: <…>; rel="next"` header.
  static func nextPage(link: String?) -> URL? {
    guard let link else { return nil }
    for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
      guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
      return URL(string: String(part[part.index(after: start)..<end]))
    }
    return nil
  }
}

nonisolated enum HuggingFaceError: LocalizedError, Equatable {
  case notALink
  case needsToken
  case tokenRejected
  case gated(repo: String, user: String?)
  case notFound
  case unexpectedResponse
  case server(Int)
  case tooLarge(String)

  var errorDescription: String? {
    switch self {
    case .notALink: "That isn't a Hugging Face model link. Paste a link to a model repo or one of its files."
    case .needsToken: "This repo needs you signed in. Add a Hugging Face token in Settings ▸ Models."
    case .tokenRejected: "Hugging Face rejected the token. Check it in Settings ▸ Models."
    case .gated(let repo, let user):
      if let user {
        "Accept the terms at huggingface.co/\(repo) while signed in as \(user), then try again."
      } else {
        "Accept the terms at huggingface.co/\(repo), add a token in Settings ▸ Models, then try again."
      }
    case .notFound: "Hugging Face has no such model repo, revision or file."
    case .unexpectedResponse: "Hugging Face sent a response Atelier doesn't understand."
    case .server(let status): "Hugging Face answered with error \(status)."
    case .tooLarge(let file): "\(file) is larger than a file of its kind should be."
    }
  }
}

/// What a repo offers to import, as rows of the link sheet: a Diffusers model's denoiser, every
/// checkpoint file, and each set of split (sharded) safetensors as one row. Files that can't be
/// imported are still listed, with the reason, so nothing goes missing without a word.
nonisolated struct HuggingFaceListing: Equatable, Sendable {
  enum Kind: String, Codable, Sendable, CaseIterable {
    case model, lora
  }

  struct Entry: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var detail: String
    /// What to download: one file, or the shards and their index.
    var files: [HuggingFaceRepoFile]
    /// The shard index, among `files`.
    var index: String?
    /// The shards are joined into one file before importing (`SafetensorsMerge`).
    var merges: Bool
    /// The file handed to the import sheet, by kind: Diffusers' and diffusers-style generic names
    /// take the repo's name, so the import is named after it.
    var modelOutput: String
    var loraOutput: String
    /// Why it can't be imported as a model, or as a LoRA.
    var modelProblem: String?
    var loraProblem: String?
    /// Download size.
    var size: Int64 { files.reduce(0) { $0 + $1.size } }
    var weights: [HuggingFaceRepoFile] { files.filter { $0.path != index } }

    func problem(for kind: Kind) -> String? { kind == .model ? modelProblem : loraProblem }
    func output(for kind: Kind) -> String { kind == .model ? modelOutput : loraOutput }
    /// Whether the file is a safetensors whose header can be read before downloading it.
    var isSafetensors: Bool { weights.allSatisfy { $0.pathExtension == "safetensors" } }
  }

  /// A Diffusers repo (`model_index.json` at the top): its pipeline class and, for a denoiser
  /// Atelier can import (`transformer/` or `unet/`), each precision it's saved in.
  struct Diffusers: Equatable, Sendable {
    var className: String
    var folder: String?
    var variants: [Variant]

    struct Variant: Identifiable, Equatable, Sendable {
      /// `fp16`, `bf16`…, or nil for the default files.
      var name: String?
      var entry: Entry
      var id: String { name ?? "" }
      var title: String { name ?? "Default" }
    }
  }

  var diffusers: Diffusers?
  var entries: [Entry]

  nonisolated static let weightsExtensions: Set<String> = ["safetensors", "ckpt", "pt", "pth", "bin"]
  /// Formats some repos carry that the importers can't read; listed with the reason.
  nonisolated static let otherWeightsExtensions: [String: String] = [
    "gguf": "GGUF files can't be imported yet.",
    "onnx": "ONNX files can't be imported.",
    "msgpack": "Flax weights can't be imported.",
    "h5": "TensorFlow weights can't be imported.",
    "mlmodel": "Core ML models can't be imported.",
  ]
  /// Folders of the parts a model uses beside its denoiser. Atelier uses its own converted text
  /// encoders and VAEs (downloaded for the family after import), so these aren't imported.
  nonisolated static let encoderFolders: Set<String> = [
    "text_encoder", "text_encoder_2", "text_encoder_3", "text_encoders", "tokenizer", "tokenizer_2",
    "tokenizer_3", "vae", "image_encoder", "safety_checker", "feature_extractor", "scheduler",
  ]
  /// File stems that say nothing about the model (Diffusers and PEFT defaults); the file takes the
  /// repo's name instead.
  nonisolated static let genericStems: Set<String> = [
    "diffusion_pytorch_model", "pytorch_model", "model", "pytorch_lora_weights", "adapter_model",
  ]
  static let usesOwnEncoders = "Not imported: Atelier downloads its own text encoders and VAE."

  /// Builds the rows from a tree listing and, for a Diffusers repo, its `model_index.json`.
  static func make(repo: String, files: [HuggingFaceRepoFile], modelIndex: [String: Any]?) -> HuggingFaceListing {
    let repoName = String(repo.split(separator: "/").last ?? Substring(repo))
    var diffusers: Diffusers?
    var denoiserFolder: String?
    if let modelIndex {
      let className = modelIndex["_class_name"] as? String ?? "Diffusers pipeline"
      // A component is `[library, class]`, or `[null, null]` when the pipeline leaves it out.
      func has(_ key: String) -> Bool {
        guard let value = modelIndex[key] as? [Any] else { return false }
        return value.contains { $0 is String }
      }
      denoiserFolder = has("transformer") ? "transformer" : has("unet") ? "unet" : nil
      let variants = denoiserFolder.map { folder in
        variantEntries(files.filter { $0.folder == folder }, folder: folder, className: className, repoName: repoName)
      } ?? []
      diffusers = Diffusers(className: className, folder: denoiserFolder, variants: variants)
    }

    var entries: [Entry] = []
    var claimed = Set<String>()
    // Split sets, grouped by folder, stem and count.
    let shards = files.compactMap { file -> (file: HuggingFaceRepoFile, shard: Shard)? in
      guard weightsExtensions.contains(file.pathExtension), let shard = Shard(file.name) else { return nil }
      if denoiserFolder != nil, file.folder == denoiserFolder { return nil }
      return (file, shard)
    }
    let groups = Dictionary(grouping: shards) { "\($0.file.folder)/\($0.shard.stem).\($0.file.pathExtension)/\($0.shard.total)" }
    for key in groups.keys.sorted() {
      let group = groups[key]!.sorted { $0.shard.number < $1.shard.number }
      let first = group[0]
      let folder = first.file.folder
      let stem = first.shard.stem
      let ext = first.file.pathExtension
      let index = indexFile(for: stem, ext: ext, in: folder, files: files)
      group.forEach { claimed.insert($0.file.path) }
      if let index { claimed.insert(index.path) }
      let output = (genericStems.contains(baseStem(stem)) ? repoName : stem) + ".safetensors"
      var problem: String?
      if ext != "safetensors" {
        problem = "Split .\(ext) checkpoints can't be joined; only split safetensors can."
      } else if Set(group.map(\.shard.number)).count != first.shard.total {
        problem = "The repo has \(group.count) of its \(first.shard.total) parts."
      } else if let reason = encoderReason(folder) {
        problem = reason
      }
      let title = (folder.isEmpty ? "" : folder + "/") + "\(stem) (\(first.shard.total) parts)"
      entries.append(Entry(
        id: key, title: title, detail: "Split safetensors, joined into one file before importing",
        files: group.map(\.file) + (index.map { [$0] } ?? []), index: index?.path, merges: true,
        modelOutput: output, loraOutput: output, modelProblem: problem,
        loraProblem: problem ?? "Split LoRAs can't be imported."))
    }
    // Single files.
    for file in files where !claimed.contains(file.path) {
      let ext = file.pathExtension
      if denoiserFolder != nil, file.folder == denoiserFolder, weightsExtensions.contains(ext) { continue }
      guard weightsExtensions.contains(ext) || otherWeightsExtensions[ext] != nil else { continue }
      // An encoder folder's files say why first, whatever their format.
      var problem = isH3ImageVAE(file) ? nil : encoderReason(file.folder)
      if problem == nil { problem = otherWeightsExtensions[ext] }
      let stem = (file.name as NSString).deletingPathExtension
      let base = genericStems.contains(baseStem(stem)) ? repoName : stem
      // A .bin checkpoint is a PyTorch pickle, which the model importer reads as .ckpt.
      let modelOutput = base + "." + (ext == "bin" ? "ckpt" : ext)
      entries.append(Entry(
        id: file.path, title: file.path, detail: ext == "safetensors" ? "Safetensors" : "PyTorch checkpoint",
        files: [file], index: nil, merges: false, modelOutput: modelOutput, loraOutput: base + "." + ext,
        modelProblem: problem, loraProblem: problem))
    }
    entries.sort { lhs, rhs in
      // Importable rows first, then by path.
      if (lhs.modelProblem == nil) != (rhs.modelProblem == nil) { return lhs.modelProblem == nil }
      return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
    return HuggingFaceListing(diffusers: diffusers, entries: entries)
  }

  /// The MiniMax H3 Image VAE, which `H3ImageVAEImporter` converts, so it can come from `vae/`.
  static func isH3ImageVAE(_ file: HuggingFaceRepoFile) -> Bool {
    file.name.lowercased().contains("h3_image") && file.pathExtension == "safetensors"
  }

  private static func encoderReason(_ folder: String) -> String? {
    folder.split(separator: "/").contains { encoderFolders.contains($0.lowercased()) } ? usesOwnEncoders : nil
  }

  /// `diffusion_pytorch_model.fp16` → `diffusion_pytorch_model`.
  private static func baseStem(_ stem: String) -> String {
    String(stem.split(separator: ".", maxSplits: 1).first ?? Substring(stem))
  }

  /// A split file's name: `<stem>-00001-of-00003.<ext>`.
  struct Shard: Equatable {
    var stem: String
    var number: Int
    var total: Int

    init?(_ name: String) {
      let stem = (name as NSString).deletingPathExtension
      let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count >= 4, parts[parts.count - 2] == "of",
            let number = Int(parts[parts.count - 3]), let total = Int(parts[parts.count - 1]),
            total > 1, number >= 1, number <= total
      else { return nil }
      self.stem = parts.dropLast(3).joined(separator: "-")
      self.number = number
      self.total = total
    }
  }

  /// `<stem>.safetensors.index.json`, or for a variant stem `<base>.<variant>`, Diffusers'
  /// `<base>.safetensors.index.<variant>.json`.
  private static func indexFile(for stem: String, ext: String, in folder: String, files: [HuggingFaceRepoFile]) -> HuggingFaceRepoFile? {
    var names = ["\(stem).\(ext).index.json"]
    let parts = stem.split(separator: ".", maxSplits: 1).map(String.init)
    if parts.count == 2 { names.append("\(parts[0]).\(ext).index.\(parts[1]).json") }
    return files.first { $0.folder == folder && names.contains($0.name) }
  }

  /// The denoiser folder's files as one entry per precision, in the order the picker prefers:
  /// fp16, then bf16, then the default files, then any other; safetensors before .bin within one.
  private static func variantEntries(_ files: [HuggingFaceRepoFile], folder: String, className: String, repoName: String) -> [Diffusers.Variant] {
    struct Key: Hashable { var variant: String?; var ext: String }
    var sets: [Key: [HuggingFaceRepoFile]] = [:]
    for file in files where ["safetensors", "bin"].contains(file.pathExtension) {
      var stem = (file.name as NSString).deletingPathExtension
      if let shard = Shard(file.name) { stem = shard.stem }
      let parts = stem.split(separator: ".", maxSplits: 1).map(String.init)
      sets[Key(variant: parts.count == 2 ? parts[1] : nil, ext: file.pathExtension), default: []].append(file)
    }
    let names = Set(sets.keys.map(\.variant))
    func rank(_ name: String?) -> Int {
      switch name {
      case "fp16": 0
      case "bf16": 1
      case nil: 2
      default: 3
      }
    }
    let ordered = names.sorted { lhs, rhs in
      rank(lhs) != rank(rhs) ? rank(lhs) < rank(rhs) : (lhs ?? "") < (rhs ?? "")
    }
    return ordered.compactMap { name in
      let ext = sets[Key(variant: name, ext: "safetensors")] != nil ? "safetensors" : "bin"
      guard let weights = sets[Key(variant: name, ext: ext)]?.sorted(by: { $0.path < $1.path }) else { return nil }
      let isSplit = weights.contains { Shard($0.name) != nil }
      let stem = name.map { "diffusion_pytorch_model.\($0)" } ?? "diffusion_pytorch_model"
      let index = isSplit ? indexFile(for: stem, ext: ext, in: folder, files: files) : nil
      let size = weights.reduce(Int64(0)) { $0 + $1.size }
      let count = weights.count
      let title = "Diffusers model: \(className), \(folder)/ (\(count) \(count == 1 ? "file" : "files"), \(size.formatted(.byteCount(style: .file))))"
      var problem: String?
      if isSplit, ext != "safetensors" {
        problem = "Split .bin checkpoints can't be joined; only split safetensors can."
      } else if isSplit, let total = weights.compactMap({ Shard($0.name)?.total }).first, total != count {
        problem = "The repo has \(count) of the \(total) parts."
      }
      let entry = Entry(
        id: "diffusers/\(folder)/\(name ?? "")", title: title,
        detail: isSplit ? "Split safetensors, joined into one file before importing" : (ext == "safetensors" ? "Safetensors" : "PyTorch checkpoint"),
        files: weights + (index.map { [$0] } ?? []), index: index?.path, merges: isSplit,
        modelOutput: repoName + "." + (ext == "bin" ? "ckpt" : "safetensors"), loraOutput: repoName + "." + ext,
        modelProblem: problem, loraProblem: "A Diffusers model isn't a LoRA.")
      return Diffusers.Variant(name: name, entry: entry)
    }
  }

  /// Whether a repo looks like it holds LoRAs, to start the sheet's Kind there: a LoRA in the
  /// repo's name or the file's, or a file too small to be a model.
  static func guessesLoRA(repo: String, entry: Entry?) -> Bool {
    guard let entry else { return repo.lowercased().contains("lora") }
    return repo.lowercased().contains("lora") || entry.title.lowercased().contains("lora")
      || (!entry.merges && entry.size > 0 && entry.size < 400_000_000)
  }
}
