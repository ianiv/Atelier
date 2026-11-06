@preconcurrency import _MediaGenerationKit
@preconcurrency import Diffusion
import Foundation
@preconcurrency import ModelZoo
import SQLite3
import SwiftUI

/// What a folder from Draw Things holds, read without changing anything. The folder is usually
/// Draw Things' Documents (Models inside, projects beside it), but its Models folder alone works
/// too, which is where someone who keeps models on another drive will point.
nonisolated struct DrawThingsContents: Sendable {
  struct ProjectFile: Sendable, Hashable {
    var url: URL
    var size: Int64
    var name: String { url.deletingPathExtension().lastPathComponent }
  }

  /// A model file no catalog or registry explains, so no list in Atelier will show it.
  struct UnmatchedFile: Sendable, Hashable, Identifiable {
    enum Kind: Sendable {
      /// The engine's own format (a SQLite file): nothing in it says which family it is, so its
      /// owner has to, and the importer only takes originals, which they rarely still have.
      case converted
      /// A format the engine can't run, which the importers can convert.
      case unconverted
    }

    var url: URL
    var size: Int64
    var kind: Kind
    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// By its name, the only sign there is. Draw Things' LoRAs end in `_lora_f16.ckpt`.
    var isLoRA: Bool { name.lowercased().contains("lora") }

    var reason: String {
      switch kind {
      case .converted:
        "Draw Things converted this file, but nothing says which model family it's for. Choose one to list it."
      case .unconverted:
        "Not converted yet, and the engine can't run it as it is. Import it as a model or a LoRA to convert a copy."
      }
    }
  }

  var folder: URL
  var modelsFolder: URL?
  var hasCustomModels = false
  var hasCustomLoRAs = false
  /// Models and LoRAs its custom.json and custom_lora.json list, wherever their files are. Draw
  /// Things writes these in its own Documents/Models even when the models are on another drive
  /// (`ModelZoo.filePathForOtherModelDownloaded`), so the file names mean nothing without them.
  var registeredCount = 0
  /// Names of the model files in the models folder.
  var modelFiles: [String] = []
  var configurationsFile: URL?
  var projects: [ProjectFile] = []

  var projectsSize: Int64 { projects.reduce(0) { $0 + $1.size } }

  var isWorthSharing: Bool { !modelFiles.isEmpty || registeredCount > 0 }

  /// A file's kind, from its first bytes: Draw Things' .ckpt files are SQLite databases.
  static func isConverted(_ url: URL) -> Bool {
    hasSQLiteHeader(url)
  }

  static func scan(_ folder: URL) -> DrawThingsContents {
    let fileManager = FileManager.default
    var contents = DrawThingsContents(folder: folder)
    let nested = folder.appendingPathComponent("Models", isDirectory: true)
    var isFolder: ObjCBool = false
    let hasNested = fileManager.fileExists(atPath: nested.path, isDirectory: &isFolder) && isFolder.boolValue
    let models = hasNested ? nested : folder
    let names = (try? fileManager.contentsOfDirectory(atPath: models.path)) ?? []
    contents.modelFiles = names.filter { ModelLibrary.checkpointExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    contents.hasCustomModels = names.contains("custom.json")
    contents.hasCustomLoRAs = names.contains("custom_lora.json")
    contents.registeredCount = ModelLibrary.registeredCount(in: models)
    if hasNested || !contents.modelFiles.isEmpty || contents.hasCustomModels || contents.hasCustomLoRAs {
      contents.modelsFolder = models
    }
    // Beside the models, as `ConfigurationZoo` looks for it.
    if names.contains("custom_configs.json") {
      contents.configurationsFile = models.appendingPathComponent("custom_configs.json")
    }
    // Picking Models alone still finds the projects when they're beside it.
    let projectsFolder = !hasNested && models.lastPathComponent == "Models" ? models.deletingLastPathComponent() : folder
    let candidates = [projectsFolder, projectsFolder.appendingPathComponent("Sessions", isDirectory: true)]
    contents.projects = candidates.flatMap { projectFiles(in: $0) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return contents
  }

  /// The model files in the models folder that `known` doesn't account for.
  func unmatchedFiles(known: Set<String>) -> [UnmatchedFile] {
    guard let modelsFolder else { return [] }
    let registered = ModelLibrary.registeredFiles(in: modelsFolder)
    return modelFiles.filter { !known.contains($0) && !registered.contains($0) }.map { name in
      let url = modelsFolder.appendingPathComponent(name)
      // A converted model's weights can be almost all in its -tensordata.
      let size = Self.size(of: url) + Self.size(of: URL(fileURLWithPath: url.path + "-tensordata"))
      return UnmatchedFile(url: url, size: size, kind: Self.isConverted(url) ? .converted : .unconverted)
    }
  }

  private static func projectFiles(in folder: URL) -> [ProjectFile] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".sqlite3") }.compactMap { name in
      let url = folder.appendingPathComponent(name)
      guard isProject(url) else { return nil }
      return ProjectFile(url: url, size: ["", "-wal", "-shm"].reduce(0) { $0 + size(of: URL(fileURLWithPath: url.path + $1)) })
    }
  }

  /// Whether a .sqlite3 file is a project, by its history table. Draw Things keeps other databases
  /// of its own beside them, such as its settings. Immutable, so that looking writes nothing beside
  /// the original, as opening a database in its journal mode would. Scanning the file's first pages
  /// for the table's name instead misses some projects: the schema isn't always there.
  static func isProject(_ url: URL) -> Bool {
    guard hasSQLiteHeader(url) else { return false }
    var components = URLComponents()
    components.scheme = "file"
    components.path = url.path
    components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
    guard let uri = components.string else { return false }
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return false }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    let query = "select count(*) from sqlite_master where name like 'tensorhistorynode%'"
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW
    else { return false }
    return sqlite3_column_int(statement, 0) > 0
  }

  private static func hasSQLiteHeader(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
  }

  private static func size(of url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
  }

  /// Copies projects into `directory` with their -wal and -shm, leaving the originals. A project
  /// already there at the same size is taken to be this one, so importing twice doesn't duplicate
  /// it; another project with the same name gets a number.
  @concurrent static func copy(_ projects: [ProjectFile], to directory: URL) async -> (copied: [String], skipped: [String], failed: [String]) {
    var result: (copied: [String], skipped: [String], failed: [String]) = ([], [], [])
    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    for project in projects {
      if size(of: directory.appendingPathComponent(project.url.lastPathComponent)) == size(of: project.url) {
        result.skipped.append(project.name)
        continue
      }
      var name = project.name
      var n = 2
      while fileManager.fileExists(atPath: directory.appendingPathComponent(name).appendingPathExtension("sqlite3").path) {
        name = "\(project.name) \(n)"
        n += 1
      }
      let target = directory.appendingPathComponent(name).appendingPathExtension("sqlite3")
      do {
        try fileManager.copyItem(at: project.url, to: target)
        for suffix in ["-wal", "-shm"] {
          let side = URL(fileURLWithPath: project.url.path + suffix)
          if fileManager.fileExists(atPath: side.path) {
            try fileManager.copyItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
          }
        }
        result.copied.append(name)
      } catch {
        for suffix in ["", "-wal", "-shm"] {
          try? fileManager.removeItem(at: URL(fileURLWithPath: target.path + suffix))
        }
        result.failed.append(project.name)
      }
    }
    return result
  }
}

/// What several chosen folders hold between them, for someone whose models and projects are in
/// different places. A folder can sit inside another, so nothing is counted twice.
nonisolated struct DrawThingsSelection: Sendable {
  var folders: [DrawThingsContents] = []

  func contains(_ url: URL) -> Bool {
    folders.contains { $0.folder.standardizedFileURL == url.standardizedFileURL }
  }

  /// Each models folder once, in the order chosen.
  var modelsFolders: [DrawThingsContents] {
    var seen = Set<String>()
    return folders.filter { contents in
      guard let path = contents.modelsFolder?.standardizedFileURL.path else { return false }
      return seen.insert(path).inserted
    }
  }

  /// The models folders to share: those with model files or listing models, files first since the
  /// first can become the models folder. A folder that only lists them still counts: it's what says
  /// what the files on another drive are. Only when no folder has anything does ticking the part ask
  /// for an empty one. `inUse` says which Atelier already reads.
  func foldersToShare(inUse: (URL) -> Bool) -> [URL] {
    let available = modelsFolders.filter { !inUse($0.modelsFolder!) }
    let useful = available.filter(\.isWorthSharing)
    let ordered = useful.filter { !$0.modelFiles.isEmpty } + useful.filter(\.modelFiles.isEmpty)
    let anything = modelsFolders.contains(where: \.isWorthSharing)
    return (anything ? ordered : available).compactMap(\.modelsFolder)
  }

  /// Models listed in folders being shared whose own folder has none of their files.
  var registeredCount: Int { modelsFolders.reduce(0) { $0 + $1.registeredCount } }

  var modelFileCount: Int { modelsFolders.reduce(0) { $0 + $1.modelFiles.count } }

  var projects: [DrawThingsContents.ProjectFile] {
    var seen = Set<String>()
    return folders.flatMap(\.projects).filter { seen.insert($0.url.standardizedFileURL.path).inserted }
  }

  var projectsSize: Int64 { projects.reduce(0) { $0 + $1.size } }

  var configurationsFiles: [URL] {
    var seen = Set<String>()
    return folders.compactMap(\.configurationsFile).filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  /// A file listed in any of the folders is accounted for, as sharing them all would make it.
  func unmatchedFiles(known: Set<String>) -> [DrawThingsContents.UnmatchedFile] {
    let registered = modelsFolders.compactMap(\.modelsFolder).reduce(into: known) {
      $0.formUnion(ModelLibrary.registeredFiles(in: $1))
    }
    return modelsFolders.flatMap { $0.unmatchedFiles(known: registered) }
  }
}

/// Finding Draw Things, and the once-only offer to bring its things over.
nonisolated enum DrawThingsApp {
  private static let offeredKey = "drawThingsImportOffered"

  /// Where Draw Things keeps its Documents on this Mac. macOS guards another app's container, and
  /// asks nobody: reading it fails with "Operation not permitted" until the person picks it.
  /// There's no such thing to look at on iPad, where apps can't see each other.
  static var documents: URL? {
    #if os(macOS)
      // The account's real home, not `homeDirectoryForCurrentUser`, which follows CFFIXED_USER_HOME:
      // Draw Things stays where it is when Atelier runs against a scratch home for testing.
      getpwuid(getuid()).flatMap { URL(fileURLWithFileSystemRepresentation: $0.pointee.pw_dir, isDirectory: true, relativeTo: nil) }?
        .appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Documents", isDirectory: true)
    #else
      nil
    #endif
  }

  /// Whether Draw Things has run here: its container's own folder can be seen, if not read.
  static var isDetected: Bool {
    guard let documents else { return false }
    let container = documents.deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: container.path)
  }

  /// True the first time it's asked on a Mac with Draw Things. Scripted runs aren't offered it.
  static func takeFirstRunOffer() -> Bool {
    guard SessionState.isEnabled, isDetected, !UserDefaults.standard.bool(forKey: offeredKey) else { return false }
    UserDefaults.standard.set(true, forKey: offeredKey)
    return true
  }
}

/// The import sheet's state: nothing here changes anything until `run()`.
@MainActor
@Observable
final class DrawThingsImporter {
  private(set) var selection = DrawThingsSelection()
  private(set) var unmatched: [DrawThingsContents.UnmatchedFile] = []
  private(set) var configurations: [Preset] = []
  private(set) var isScanning = false
  private(set) var isImporting = false
  /// Lines saying what the import did, once it's finished.
  private(set) var summary: [String]?
  /// The family chosen for each converted file, as a `ModelVersion` raw value. Nothing's written
  /// until Import.
  var families: [URL: String] = [:]
  /// A model of each family to take a converted file's encoders and defaults from.
  private(set) var templates: [String: ModelZoo.Specification] = [:]
  /// Set when the community catalog couldn't be reached, so `unmatched` may list catalog models.
  private(set) var catalogMissing = false
  /// Why the last folder chosen can't be used.
  private(set) var problem: String?
  var sharesModels = false
  var importsConfigurations = false
  var importsProjects = false
  /// Hold picked folders open while they're being read (iPad).
  private var access: [URL: ScopedAccess] = [:]

  var canImport: Bool {
    !isImporting && summary == nil && !isScanning && (!families.isEmpty || usesConfigurations || usesProjects || sharesModels && !selection.modelsFolders.isEmpty)
  }

  var usesConfigurations: Bool { importsConfigurations && !configurations.isEmpty }
  var usesProjects: Bool { importsProjects && !selection.projects.isEmpty }

  /// Adds a folder to what's being imported. One that can't be used leaves the others as they are.
  func add(_ url: URL, create: CreateModel) async {
    problem = nil
    guard !selection.contains(url) else { return }
    let opened = ScopedAccess(url)
    isScanning = true
    defer { isScanning = false }
    let scanned = await Self.scan(url)
    guard scanned.isReadable else {
      problem = "Atelier couldn't read that folder. On a Mac, macOS may not allow it: see Import from Draw Things in the Getting Started guide."
      return
    }
    let found = scanned.contents
    guard found.modelsFolder != nil || !found.projects.isEmpty else {
      problem = "\(url.lastPathComponent) has no models or projects from Draw Things. Choose the folder that holds its Models folder, or the folder you keep its models in."
      return
    }
    access[url] = opened
    selection.folders.append(found)
    await update(create: create)
  }

  func remove(_ contents: DrawThingsContents, create: CreateModel) async {
    selection.folders.removeAll { $0.folder == contents.folder }
    access[contents.folder] = nil
    problem = nil
    await update(create: create)
  }

  /// Rereads what the folders add up to. A part that just found something gets ticked, but one
  /// already showing keeps what the person chose. Draw Things' own Models can be nearly empty when
  /// its models live on another drive, so one with nothing in it isn't ticked.
  private func update(create: CreateModel) async {
    let hadModels = !sharesModelsCandidates.isEmpty
    let hadConfigurations = !configurations.isEmpty
    let hadProjects = importsProjects
    sharesModelsCandidates = selection.modelsFolders
      .filter { $0.isWorthSharing && !Self.isInUse($0.modelsFolder!, create: create) }
      .compactMap(\.modelsFolder)
    var found: [Preset] = []
    for file in selection.configurationsFiles {
      guard let data = try? Data(contentsOf: file) else { continue }
      for preset in DrawThingsJSON.presets(fromFile: data, named: "Draw Things") where !found.contains(preset) {
        found.append(preset)
      }
    }
    configurations = found
    if sharesModelsCandidates.isEmpty { sharesModels = false } else if !hadModels { sharesModels = true }
    if configurations.isEmpty { importsConfigurations = false } else if !hadConfigurations { importsConfigurations = true }
    if selection.projects.isEmpty { importsProjects = false } else if !hadProjects { importsProjects = true }
    // Files any catalog explains. The community list is what most downloads are in.
    let live = await CommunityCatalog.specifications()
    catalogMissing = live == nil
    let community = live ?? CommunityCatalog.shipped
    unmatched = await Self.unmatched(in: selection, known: Self.knownFiles(community: community))
    families = families.filter { entry in unmatched.contains { $0.url == entry.key } }
    templates = Self.templates(from: ModelZoo.availableSpecifications + ModelZoo.builtinSpecifications + community)
  }

  /// The families a converted file can be listed under: for a model, those with a catalog model to
  /// start from; for a LoRA, every family, since it needs nothing else.
  func familyChoices(for file: DrawThingsContents.UnmatchedFile) -> [(version: String, name: String)] {
    file.isLoRA ? ModelLibrary.families : ModelLibrary.families.filter { templates[$0.version] != nil }
  }

  /// Whether Atelier will be able to read this file after Import, so that listing it means something.
  func canList(_ file: DrawThingsContents.UnmatchedFile, create: CreateModel) -> Bool {
    let folder = file.url.deletingLastPathComponent()
    return Self.isInUse(folder, create: create) || sharesModels && foldersToShare(create: create).contains { $0.standardizedFileURL == folder.standardizedFileURL }
  }

  /// One catalog model per family, the plainest: variants tuned for few steps or for editing would
  /// hand their defaults to a model that isn't tuned that way.
  nonisolated static func templates(from specifications: [ModelZoo.Specification]) -> [String: ModelZoo.Specification] {
    let special = ["turbo", "lightning", "lcm", "distill", "fast", "instant", "hyper", "kontext", "fill", "edit", "inpaint", "fl2va", "ref2va", "dmd"]
    func cost(_ specification: ModelZoo.Specification) -> Int {
      let file = specification.file.lowercased()
      return special.filter { file.contains($0) }.count * 2 + (file.hasSuffix("_f16.ckpt") ? 0 : 1)
    }
    var templates: [String: ModelZoo.Specification] = [:]
    for specification in specifications where specification.remoteApiModelConfig == nil {
      let version = specification.version.rawValue
      if let current = templates[version], cost(current) <= cost(specification) { continue }
      templates[version] = specification
    }
    return templates
  }

  /// The folders worth sharing that Atelier doesn't read yet.
  private var sharesModelsCandidates: [URL] = []

  /// The folders Import would share, in order.
  func foldersToShare(create: CreateModel) -> [URL] {
    selection.foldersToShare { Self.isInUse($0, create: create) }
  }

  /// Whether sharing makes the first folder the models folder (downloads go there), with any others
  /// added: an untouched default folder has nothing to lose, but one with models in it stays first.
  func replacesModelsFolder(create: CreateModel) -> Bool {
    guard create.modelsDirectory == AppSettings.defaultModelsDirectory else { return false }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: create.modelsDirectory)) ?? []
    return !names.contains { ModelLibrary.checkpointExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
  }

  func run(create: CreateModel, presets: PresetStore, history: HistoryStore, library: ModelLibrary) async {
    guard canImport else { return }
    isImporting = true
    defer { isImporting = false }
    var lines: [String] = []
    // Before the folders are shared, which reads their custom.json.
    let listed = list(library: library, create: create, lines: &lines)
    var folders = sharesModels ? foldersToShare(create: create) : []
    if !folders.isEmpty {
      for folder in folders {
        FolderBookmarks.remember(folder)
      }
      if replacesModelsFolder(create: create) {
        create.setModelsDirectory(folders.removeFirst().path)
        lines.append("Atelier now uses a Draw Things models folder. Nothing was copied.")
      }
      if !folders.isEmpty {
        create.setAdditionalModelsDirectories(create.additionalModelsDirectories + folders.map(\.path))
        lines.append("Added \(folders.count) additional models folder\(folders.count == 1 ? "" : "s"). Nothing was copied.")
      }
    }
    if usesConfigurations {
      do {
        let saved = try presets.importPresets(configurations)
        lines.append(saved.isEmpty ? "All the saved configurations were already presets." : "Added \(saved.count) preset\(saved.count == 1 ? "" : "s").")
      } catch {
        lines.append("Couldn't add the presets: \(error.localizedDescription)")
      }
    }
    if usesProjects {
      let result = await DrawThingsContents.copy(selection.projects, to: HistoryStore.projectsDirectory)
      if !result.copied.isEmpty { lines.append("Copied \(result.copied.count) project\(result.copied.count == 1 ? "" : "s"). The originals are untouched.") }
      if !result.skipped.isEmpty { lines.append("\(result.skipped.count) project\(result.skipped.count == 1 ? " was" : "s were") already here.") }
      if !result.failed.isEmpty { lines.append("Couldn't copy: \(result.failed.joined(separator: ", ")).") }
      await history.reload()
    }
    if listed { await create.reloadModels() }
    summary = lines
  }

  /// Writes the families chosen for converted files. Returns whether any was listed.
  private func list(library: ModelLibrary, create: CreateModel, lines: inout [String]) -> Bool {
    var listed: [String] = []
    var failed: [String] = []
    for file in unmatched where canList(file, create: create) {
      guard let family = families[file.url], let version = ModelVersion(rawValue: family) else { continue }
      let folder = file.url.deletingLastPathComponent()
      do {
        if file.isLoRA {
          try library.registerConverted(loRA: file.name, in: folder, version: version)
        } else if let template = templates[family] {
          try library.registerConverted(file: file.name, in: folder, template: template)
        }
        listed.append(file.name)
      } catch {
        failed.append(file.name)
      }
    }
    if !listed.isEmpty { lines.append("Listed \(listed.count) file\(listed.count == 1 ? "" : "s") under the family you chose.") }
    if !failed.isEmpty { lines.append("Couldn't list: \(failed.joined(separator: ", ")).") }
    return !listed.isEmpty
  }

  private static func isInUse(_ folder: URL, create: CreateModel) -> Bool {
    ([create.modelsDirectory] + create.additionalModelsDirectories).contains {
      URL(fileURLWithPath: $0).standardizedFileURL.path == folder.standardizedFileURL.path
    }
  }

  @concurrent private nonisolated static func scan(_ url: URL) async -> (contents: DrawThingsContents, isReadable: Bool) {
    let isReadable = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    return (DrawThingsContents.scan(url), isReadable)
  }

  @concurrent private nonisolated static func unmatched(in selection: DrawThingsSelection, known: Set<String>) async -> [DrawThingsContents.UnmatchedFile] {
    selection.unmatchedFiles(known: known)
  }

  /// Every file the engine's lists account for. Control nets, textual inversions and the rest count
  /// here so they aren't reported as strays, though Atelier doesn't import them yet.
  static func knownFiles(community: [ModelZoo.Specification]) -> Set<String> {
    var files = Set<String>()
    for specification in ModelZoo.availableSpecifications + ModelZoo.builtinSpecifications + community {
      files.formUnion(ModelLibrary.files(of: specification))
    }
    if let url = Bundle.main.url(forResource: "models", withExtension: "json"), let data = try? Data(contentsOf: url) {
      for specification in CommunityCatalog.parse(data) { files.formUnion(ModelLibrary.files(of: specification)) }
    }
    files.formUnion(LoRAZoo.availableSpecifications.map(\.file))
    files.formUnion(ControlNetZoo.availableSpecifications.flatMap { [$0.file] + [$0.imageEncoder, $0.preprocessor].compactMap(\.self) })
    files.formUnion(TextualInversionZoo.availableSpecifications.map(\.file))
    files.formUnion(UpscalerZoo.availableSpecifications.map(\.file))
    files.formUnion(EverythingZoo.availableSpecifications.map(\.file))
    return files
  }
}
