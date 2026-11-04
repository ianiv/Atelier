import SwiftUI
import UniformTypeIdentifiers

/// The Characters screen (docs/characters.md): the library on the left, the saved image or a
/// preview with the Previews strip in the centre, and the knob panel on the right.
struct CharactersView: View {
  @Environment(CharacterStore.self) private var store
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var pendingDelete: UUID?
  @State private var message: (title: String, text: String)?

  private static let libraryWidth: CGFloat = 260

  private var selected: SavedCharacter? { store.character(id: store.selection) }

  private var filtered: [SavedCharacter] {
    let query = store.screenSearch.trimmed
    guard !query.isEmpty else { return store.characters }
    return store.characters.filter { character in
      character.name.localizedCaseInsensitiveContains(query)
        || character.kind(in: store.knobs).localizedCaseInsensitiveContains(query)
        || character.notes.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      library.frame(width: Self.libraryWidth)
      Divider()
      Group {
        if let selected {
          CharacterStage(character: selected)
        } else {
          ContentUnavailableView {
            Label(store.characters.isEmpty ? "No Characters" : "No Selection", systemImage: "person.2")
          } description: {
            Text("A character is a saved description you build with knobs, then render in any of your styles.")
          } actions: {
            Button("New Character") { store.newCharacter() }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .detailInspector(selection: store.selection, isEmpty: selected == nil, clearSelection: { store.selection = nil }) {
      Group {
        if let selected {
          CharacterPanel(character: selected).id(selected.id)
        } else {
          ContentUnavailableView("No Selection", systemImage: "person.2", description: Text("Select a character to turn its knobs."))
        }
      }
      .inspectorColumnWidth(min: 340, ideal: 400, max: 560)
    }
    .confirmationDialog(
      "Delete “\(store.character(id: pendingDelete)?.name ?? "this character")”?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    ) {
      Button("Delete", role: .destructive) {
        if let pendingDelete { store.delete(pendingDelete) }
        pendingDelete = nil
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      Text("Its knobs, saved image and previews go with it. This can't be undone. Export it first to keep a copy.")
    }
    .alert(
      message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    ) {
      Button("OK") { message = nil }
    } message: {
      Text(message?.text ?? "")
    }
    .onDisappear { store.flush() }
  }

  // MARK: - The library

  private var library: some View {
    @Bindable var store = store
    return VStack(spacing: 0) {
      HStack(spacing: 8) {
        SearchField(text: $store.screenSearch, prompt: "Search")
        Picker("View", selection: $store.screenGrid) {
          Label("List", systemImage: "list.bullet").tag(false)
          Label("Grid", systemImage: "square.grid.2x2").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Show the characters as a list or a grid of portraits")
      }
      .padding(8)
      Divider()
      Group {
        if store.screenGrid { grid } else { list }
      }
      .frame(maxHeight: .infinity)
      Divider()
      buttons.padding(8)
    }
  }

  private var list: some View {
    @Bindable var store = store
    return List(filtered, selection: $store.selection) { character in
      HStack(spacing: 10) {
        CharacterPortrait(id: character.id, side: 44)
        VStack(alignment: .leading, spacing: 1) {
          Text(character.name).fontWeight(.medium).lineLimit(1)
          Text(caption(character)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .tag(character.id)
      .contextMenu { menu(character) }
    }
    .listStyle(.plain)
    .deleteCommand { pendingDelete = store.selection }
  }

  private var grid: some View {
    ScrollView {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 2), spacing: 8) {
        ForEach(filtered) { character in
          VStack(alignment: .leading, spacing: 3) {
            CharacterPortrait(id: character.id, side: (Self.libraryWidth - 56) / 2)
            Text(character.name).font(.callout).lineLimit(1)
          }
          .padding(6)
          .background(store.selection == character.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
          .contentShape(.rect)
          .onTapGesture { store.selection = character.id }
          .contextMenu { menu(character) }
          .help(character.name)
        }
      }
      .padding(8)
    }
    .deleteCommand { pendingDelete = store.selection }
  }

  private func caption(_ character: SavedCharacter) -> String {
    let kind = character.kind(in: store.knobs)
    return kind.isEmpty ? " " : kind
  }

  @ViewBuilder
  private func menu(_ character: SavedCharacter) -> some View {
    Button("Duplicate") { store.duplicate(character.id) }
    Button("Export…") { export([character.id], name: character.name) }
    Divider()
    Button("Delete…", role: .destructive) { pendingDelete = character.id }
  }

  private var buttons: some View {
    HStack(spacing: 12) {
      Button("New Character", systemImage: "plus") { store.newCharacter() }
        .help("Add a character")
      Button("Duplicate", systemImage: "plus.square.on.square") {
        if let id = store.selection { store.duplicate(id) }
      }
      .disabled(selected == nil)
      .help("Copy the selected character, with its saved image")
      Button("Delete", systemImage: "trash") { pendingDelete = store.selection }
        .disabled(selected == nil)
        .help("Delete the selected character")
      Spacer()
      Menu {
        Button("Import Characters…", systemImage: "square.and.arrow.down") { chooseFiles() }
        Button("Export Selected…", systemImage: "square.and.arrow.up") {
          if let selected { export([selected.id], name: selected.name) }
        }
        .disabled(selected == nil)
        Button("Export All…", systemImage: "square.and.arrow.up") {
          export(store.characters.map(\.id), name: "Characters")
        }
        .disabled(store.characters.isEmpty)
      } label: {
        Label("Import or Export", systemImage: "square.and.arrow.down.on.square")
      }
      .borderlessMenuStyle()
      .fixedSize()
      .help("Import a characters file, or export characters with their saved images")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
  }

  private func chooseFiles() {
    fileDialogs.open = FileDialogs.Open(types: [.json], multiple: true, message: "Choose characters files to import") { urls in
      var added = 0
      var replaced = 0
      var unreadable: [String] = []
      for url in urls {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), let result = store.importCharacters(data) {
          added += result.added
          replaced += result.replaced
        } else {
          unreadable.append(url.lastPathComponent)
        }
      }
      var text = "\(added) added"
      if replaced > 0 { text += ", \(replaced) replaced (same name)" }
      text += "."
      if !unreadable.isEmpty { text += " \(unreadable.formatted(.list(type: .and))) isn't a characters file." }
      message = ("Imported Characters", text)
    }
  }

  private func export(_ ids: [UUID], name: String) {
    let data = store.exported(ids)
    fileDialogs.save = FileDialogs.Save(file: ExportedFile(type: .json) { data }, name: name + ".json")
  }
}

/// A character's main image as a square, or a placeholder the same size.
struct CharacterPortrait: View {
  let id: UUID
  let side: CGFloat
  @Environment(CharacterStore.self) private var store

  var body: some View {
    SavedImageSquare(image: store.character(id: id)?.mainImageID, side: side)
  }
}

/// A saved image as a square, or a placeholder the same size.
private struct SavedImageSquare: View {
  let image: UUID?
  let side: CGFloat
  @Environment(CharacterStore.self) private var store

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: side / 8)
    Group {
      if let image, let thumbnail = store.thumbnail(image) {
        Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
      } else {
        Image(systemName: "person.crop.square")
          .font(.system(size: side / 3))
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary)
      }
    }
    .frame(width: side, height: side)
    .clipShape(shape)
    .task(id: image) {
      if let image { await store.loadThumbnail(image) }
    }
  }
}

/// The centre: the image shown large (the running render, a preview or a saved image), what can be
/// done with it, and the strip of saved images and previews.
private struct CharacterStage: View {
  let character: SavedCharacter
  @Environment(CharacterStore.self) private var store
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @Environment(\.undoManager) private var undoManager
  @State private var pendingRemove: UUID?
  /// Says Send to Moodboard worked, which nothing else here shows, until another image is picked.
  @State private var moodboardNote: String?

  private var previews: [CharacterPreview] { store.previews[character.id] ?? [] }
  private var chosen: UUID? { store.shownImage[character.id] }
  private var shownPreview: CharacterPreview? {
    chosen.flatMap { id in previews.first { $0.id == id } }
  }

  /// The saved image shown: the one picked, else with no preview picked, the main one.
  private var shownSaved: UUID? {
    if shownPreview != nil { return nil }
    if let chosen, character.images.contains(chosen) { return chosen }
    return character.mainImageID
  }

  /// The image Send to Create acts on.
  private var image: CGImage? { shownPreview?.image ?? shownSaved.flatMap { store.savedImages[$0] } }
  private var info: CharacterImageInfo? { shownPreview?.info ?? shownSaved.flatMap { store.savedInfo[$0] } }
  /// This character's render is on the engine now.
  private var rendering: Bool {
    store.renderRun?.character == character.id && create.queue.running?.characterPreview != nil
  }

  var body: some View {
    VStack(spacing: 0) {
      canvas
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
      // Under the image, not over it. Always laid out, so nothing moves when a render starts.
      ProgressView(value: Double(rendering ? create.step : 0), total: Double(max(create.totalSteps, 1)))
        .opacity(rendering ? 1 : 0)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
      actions
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      Divider()
      strip
    }
    .task(id: shownSaved) {
      if let shownSaved { await store.loadSaved(shownSaved) }
    }
    .confirmationDialog(
      "Remove this saved image?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })
    ) {
      Button("Remove", role: .destructive) {
        if let pendingRemove { store.removeSavedImage(pendingRemove, from: character.id) }
        pendingRemove = nil
      }
      Button("Cancel", role: .cancel) { pendingRemove = nil }
    } message: {
      Text("This can't be undone. Images sent to Create stay in their project.")
    }
  }

  private var canvas: some View {
    ZStack {
      if rendering, let live = create.livePreview {
        Image(decorative: live, scale: 1).resizable().scaledToFit()
      } else if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
      } else {
        ContentUnavailableView {
          Label("No Image Yet", systemImage: "person.crop.artframe")
        } description: {
          Text("Set some knobs and press Render. Renders use the model, settings and seed on Create.")
        }
      }
    }
  }

  private var actions: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(caption)
        .font(.callout)
        .foregroundStyle(store.renderError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        .lineLimit(1, reservesSpace: true)
        .truncationMode(.middle)
        .help(caption)
      // Titles when they fit; the centre can be narrow beside the library and the knobs.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { buttons }.fixedSize()
        HStack(spacing: 10) { buttons }.labelStyle(.iconOnly)
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .onChange(of: chosen) { moodboardNote = nil }
  }

  @ViewBuilder
  private var buttons: some View {
    Button("Make Main Image", systemImage: "star") {
      if let shownSaved { store.makeMain(shownSaved, of: character.id) }
    }
    .labelStyle(.iconOnly)
    .disabled(shownSaved == nil || shownSaved == character.mainImageID)
    .help("Make this saved image the character's portrait in the library, and what shows when you come back to it")
    Button("Remove", systemImage: "trash") { pendingRemove = shownSaved }
      .labelStyle(.iconOnly)
      .disabled(shownSaved == nil)
      .help("Remove this saved image from the character")
    Button("Save to Character", systemImage: "square.and.arrow.down") {
      if let shownPreview { store.save(shownPreview, to: character.id) }
    }
    .disabled(shownPreview == nil || shownPreview.map { store.savedPreviews.contains($0.id) } == true)
    .help(saveHelp)
    Button("Send to Moodboard", systemImage: "photo.on.rectangle.angled") {
      guard let image else { return }
      create.moodboard.add(image)
      moodboardNote = create.usesReferences
        ? "Added to Create's moodboard"
        : "Added to Create's moodboard, which the model on Create doesn't use"
    }
    .disabled(image == nil)
    .help("Add this image to Create's moodboard as a reference. Create's canvas, prompt and settings stay as they are, and the image isn't added to the project.")
    Button("Send to Create", systemImage: "arrow.up.forward.app") {
      guard let image, let info else { return }
      Task {
        await store.sendToCreate(image, info: info, create: create, navigation: navigation, undoManager: undoManager)
      }
    }
    .disabled(image == nil || info == nil)
    .help("Add this image to the current project and load it on Create with its model, settings, seed, style and tag boxes")
  }

  private var saveHelp: String {
    guard let shownPreview else { return "Pick a preview to add it to the character's saved images" }
    return store.savedPreviews.contains(shownPreview.id) ? "This preview is already saved to the character" : "Add this preview to the character's saved images"
  }

  /// What's shown large, or why the last run failed.
  private var caption: String {
    if let error = store.renderError { return error }
    if let moodboardNote { return moodboardNote }
    if let shownPreview {
      return "Preview: \(shownPreview.info.styleName) · \(madeWith(shownPreview.info))"
    }
    guard let shownSaved, image != nil else { return "" }
    let name = shownSaved == character.mainImageID ? "Main image" : "Saved image"
    if let info { return "\(name): \(info.styleName) · \(madeWith(info))" }
    return name
  }

  /// The model, size and seed an image was made with, which may no longer be what's on Create.
  private func madeWith(_ info: CharacterImageInfo) -> String {
    let file = info.source.model ?? "unknown model"
    let name = create.models.first { $0.file == file }?.name ?? file
    return "\(name) · seed \(info.source.seed.map(String.init) ?? "unknown")"
  }

  /// Saved images and previews side by side, each with its heading whether or not it has any.
  private var strip: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: 12) {
        group("Saved", empty: character.images.isEmpty, emptyText: "Save a preview to keep it") {
          ForEach(character.images, id: \.self) { id in
            tile(selected: shownSaved == id, main: id == character.mainImageID, title: store.savedInfo[id]?.styleName ?? (id == character.mainImageID ? "Main" : "Saved"), help: id == character.mainImageID ? "The main image" : "A saved image") {
              store.shownImage[character.id] = id
            } content: {
              SavedImageSquare(image: id, side: Self.tileSide)
            }
            // The tile's caption is the style it was made in.
            .task(id: id) { await store.loadSaved(id) }
          }
        }
        Divider()
        group("Previews", empty: previews.isEmpty, emptyText: "Renders show here until you quit") {
          ForEach(previews) { preview in
            tile(selected: shownPreview?.id == preview.id, main: false, title: preview.info.styleName, help: "\(preview.info.styleName): not saved until you use Save to Character or Send to Create") {
              store.shownImage[character.id] = preview.id
            } content: {
              Image(decorative: preview.image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: Self.tileSide, height: Self.tileSide)
                .clipShape(.rect(cornerRadius: Self.tileSide / 8))
            }
          }
        }
      }
      .padding(10)
    }
    .scrollIndicators(.automatic)
    .frame(height: Self.tileSide + 66)
  }

  private static let tileSide: CGFloat = 72

  private func group(_ title: String, empty: Bool, emptyText: String, @ViewBuilder tiles: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.callout).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 8) {
        if empty {
          Text(emptyText)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(6)
            .frame(width: Self.tileSide * 1.5, height: Self.tileSide)
            .overlay {
              RoundedRectangle(cornerRadius: Self.tileSide / 8)
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4]))
            }
        }
        tiles()
      }
    }
  }

  private func tile(
    selected: Bool, main: Bool, title: String, help: String, action: @escaping () -> Void, @ViewBuilder content: () -> some View
  ) -> some View {
    Button(action: action) {
      VStack(spacing: 2) {
        content()
          .overlay {
            RoundedRectangle(cornerRadius: Self.tileSide / 8)
              .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
          }
          .overlay(alignment: .topTrailing) {
            Image(systemName: "star.fill")
              .font(.caption)
              .foregroundStyle(.yellow)
              .shadow(radius: 1)
              .padding(4)
              .opacity(main ? 1 : 0)
          }
        Text(title)
          .font(.caption)
          .lineLimit(1)
          .frame(width: Self.tileSide)
      }
    }
    .buttonStyle(.plain)
    .help(help)
  }
}
