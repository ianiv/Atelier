import SwiftUI
import UniformTypeIdentifiers

/// The Edit screen's inspector: Look, Match, Grade, LUT, Halation, Lens, Vignette and Grain, in
/// pipeline order. Every control is always there; one that can't do anything yet (no image, no
/// reference to match, no LUT, no real noise in the profile) is disabled, with a line saying why
/// where it isn't plain. Sliders show their value beside them, typed into to go past the
/// slider's range (grain.py's own settings aren't capped), as the Create inspector's do.
struct EditInspector: View {
  @Environment(EditModel.self) private var edit
  @Environment(CreateModel.self) private var create
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var choosingStep = false
  @State private var error: String?

  var body: some View {
    @Bindable var edit = edit
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        look
        match($edit.options)
        grade($edit.options.grade)
        lut($edit.options.lut)
        halation($edit.options.halation)
        lens($edit.options.lens)
        vignette($edit.options.vignette)
        grain($edit.options.grain)
      }
      .padding(10)
      .disabled(!edit.hasSource)
    }
    .sheet(isPresented: $choosingStep) {
      EditStepPicker { item in
        Task { await chooseReference(item) }
      }
    }
    .alert(
      "Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
      actions: { Button("OK") { error = nil } }, message: { Text(error ?? "") })
  }

  // MARK: Look

  private var look: some View {
    InspectorGroup {
      Text("Look")
    } content: {
      InspectorRow {
        Text("Profile").layoutPriority(1)
      } control: {
        Menu {
          Button("None") { edit.applyProfile(nil) }
          if !edit.profiles.profiles.isEmpty { Divider() }
          ForEach(edit.profiles.profiles, id: \.name) { profile in
            Button(profile.name) { edit.applyProfile(profile) }
          }
        } label: {
          Self.nameLabel(edit.profile?.name)
        }
        .nameMenu(edit.profile?.name)
      }
      HStack(spacing: 6) {
        Button("Open Profile…") { openProfile() }
        Button("Save Profile…") { saveProfile() }
        Button("Add to Library") {
          do { try edit.addProfileToLibrary() } catch { self.error = error.localizedDescription }
        }
        .disabled(edit.profileIsInLibrary)
      }
      .controlSize(.small)
      .padding(.vertical, 4)
      Divider().padding(.vertical, 4)
      InspectorRow {
        Text("Reference").layoutPriority(1)
      } control: {
        referenceMenu.nameMenu(edit.reference?.name)
      }
      HStack(spacing: 6) {
        Button("Match Reference") { Task { await edit.matchReference() } }
          .disabled(!edit.canMatchReference)
          .help("Measure the reference's grain and colour noise and take them on, as grain.py --match does")
        // Always there, shown only while measuring, so the row never shifts.
        ProgressView().controlSize(.small)
          .opacity(edit.isMeasuring ? 1 : 0)
          .accessibilityHidden(!edit.isMeasuring)
      }
      .controlSize(.small)
      .padding(.vertical, 4)
      // Two lines kept for it so a short status doesn't move what's below; a long name or the
      // match report wraps onto more.
      ZStack(alignment: .topLeading) {
        Text(" \n ").hidden().accessibilityHidden(true)
        Text(referenceStatus)
          .lineLimit(6)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, 4)
    }
  }

  /// What the reference line says: how close Match Reference came, else what the reference is.
  private var referenceStatus: String {
    if edit.isMeasuring { return "Measuring the reference…" }
    if let report = edit.matchReport { return report }
    guard let reference = edit.reference else { return "No reference: matches go to the original when it has one." }
    return reference.image == nil
      ? "Matched to “\(reference.name)” when it was saved."
      : "“\(reference.name)”. Match Reference takes on its grain."
  }

  private var referenceMenu: some View {
    Menu {
      Button("Choose File…") { chooseReferenceFile() }
      Button("From Photos…") { chooseReferencePhoto() }
      Button("Original of This Step") {
        if let original = edit.original, let image = original.image {
          Task { await edit.setReference(image: image, name: "Original", tensorId: original.tensorId) }
        }
      }
      .disabled(edit.originalImage == nil)
      Menu("Moodboard") {
        ForEach(Array(create.moodboard.items.enumerated()), id: \.element.id) { index, item in
          Button("Picture \(index + 1)") { Task { await edit.setReference(image: item.image, name: "Moodboard picture \(index + 1)") } }
        }
      }
      .disabled(create.moodboard.items.isEmpty)
      Button("Choose History Step…") { choosingStep = true }
        .disabled(create.history.items.isEmpty)
      Divider()
      Button("None") { edit.clearReference() }
        .disabled(edit.reference == nil)
    } label: {
      Self.nameLabel(edit.reference?.name)
    }
  }

  /// None, the built-in looks, and the LUT loaded from a file when there is one.
  private var lutMenu: some View {
    let builtIn = edit.builtInLUTName
    return Menu {
      Toggle("None", isOn: Binding(get: { edit.lut == nil }, set: { if $0 { edit.chooseLUT(nil) } }))
      ForEach(BuiltInLUTs.names, id: \.self) { name in
        Toggle(name, isOn: Binding(get: { builtIn == name }, set: { if $0 { edit.chooseBuiltInLUT(name) } }))
      }
      if let file = edit.fileLUT {
        Divider()
        Toggle(file.name, isOn: Binding(get: { edit.lut != nil && builtIn == nil }, set: { if $0 { edit.chooseLUT(file) } }))
      }
    } label: {
      Self.nameLabel(edit.lut?.name)
    }
  }

  /// A menu's label showing a name someone chose (a file's, a profile's): one line, cut in the
  /// middle where file names differ least, so a long one never widens the column.
  static func nameLabel(_ name: String?) -> some View {
    Text(name ?? "None").lineLimit(1).truncationMode(.middle)
  }

  // MARK: Sections

  private func match(_ options: Binding<EditOptions>) -> some View {
    let target = edit.matchTarget
    let noLab = target?.lab == nil
    let noHistogram = target?.histogram == nil
    return InspectorGroup {
      Text("Match")
    } content: {
      InspectorRow {
        Text("Match to")
      } control: {
        Picker("Match to", selection: Binding(get: { edit.options.match.target }, set: { edit.setMatchTarget($0) })) {
          Text("Reference").tag(EditOptions.Match.Target.reference)
          Text("Original").tag(EditOptions.Match.Target.original)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      Text(noLab ? (edit.options.match.target == .reference ? "Choose a reference to match to." : "This image has no original to match to.") : "Moves the colours toward \(target?.name ?? "it").")
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Self.percentSlider("Tint", options.match.tint).disabled(noLab)
      Self.percentSlider("Saturation", options.match.saturation).disabled(noLab)
      Self.percentSlider("Brightness", options.match.brightness).disabled(noLab)
      Self.percentSlider("Contrast", options.match.contrast).disabled(noLab)
      Self.percentSlider("Histogram", options.histogram.amount).disabled(noHistogram)
      InspectorRow {
        Text("Histogram of")
      } control: {
        Picker("Histogram of", selection: options.histogram.space) {
          Text("Luma").tag(EditOptions.Histogram.Space.luma)
          Text("RGB").tag(EditOptions.Histogram.Space.rgb)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      .disabled(noHistogram)
      Self.slider("Profile Colour", options.match.colour, 0...1, step: 0.01, digits: 2)
        .disabled(edit.context.refStats == nil)
        .help("grain.py's colour match: moves the RGB means and spreads toward the profile's reference")
    }
  }

  private func grade(_ grade: Binding<EditOptions.Grade>) -> some View {
    InspectorGroup {
      Text("Grade")
    } content: {
      Self.slider("Exposure", grade.exposure, EditOptions.Grade.exposureRange, step: 0.01, digits: 2)
      Self.slider("Temperature", grade.temperature, EditOptions.Grade.temperatureRange, step: 1, digits: 0)
      Self.slider("Tint", grade.tint, EditOptions.Grade.tintRange, step: 0.1, digits: 1)
      Self.slider("Contrast", grade.contrast, EditOptions.Grade.unitRange, step: 0.01, digits: 2)
      Self.slider("Saturation", grade.saturation, EditOptions.Grade.unitRange, step: 0.01, digits: 2)
      Self.slider("Vibrance", grade.vibrance, EditOptions.Grade.unitRange, step: 0.01, digits: 2)
    }
  }

  private func lut(_ lut: Binding<EditOptions.LUTRef>) -> some View {
    InspectorGroup {
      Text("LUT")
    } content: {
      InspectorRow {
        Text("LUT").layoutPriority(1)
      } control: {
        lutMenu.nameMenu(edit.lut?.name)
      }
      HStack(spacing: 6) {
        Button("Load .cube…") { loadLUT() }
        Button("Remove") { edit.removeLUT() }
          .disabled(edit.lut == nil && edit.fileLUT == nil)
      }
      .controlSize(.small)
      .padding(.vertical, 4)
      Self.percentSlider("Strength", lut.strength).disabled(edit.lut == nil)
      InspectorRow {
        Text("Match and Grade as a LUT").font(.caption).foregroundStyle(.secondary)
      } control: {
        Button("Export LUT…") { exportLUT() }
          .controlSize(.small)
          .disabled(edit.isExporting)
          .help("Bake the matches, grade and LUT for this image into a 33³ .cube file")
      }
    }
  }

  private func halation(_ halation: Binding<EditOptions.Halation>) -> some View {
    InspectorGroup {
      Text("Halation")
    } content: {
      Self.percentSlider("Amount", halation.amount)
      Self.slider("Threshold", halation.threshold, 0...1, step: 0.01, digits: 2)
      Self.slider("Radius", halation.radius, EditOptions.Halation.radiusRange, step: 0.1, digits: 1)
      Self.percentSlider("Warmth", halation.warmth)
    }
  }

  private func lens(_ lens: Binding<EditOptions.Lens>) -> some View {
    InspectorGroup {
      Text("Lens")
    } content: {
      Self.slider("Motion", lens.motion, EditOptions.Lens.motionRange, step: 0.1, digits: 1)
      Self.slider("Angle", lens.angle, EditOptions.Lens.angleRange, step: 1, digits: 0)
      Self.slider("Blur", lens.blur, EditOptions.Lens.blurRange, step: 0.01, digits: 2)
    }
  }

  private func vignette(_ vignette: Binding<EditOptions.Vignette>) -> some View {
    InspectorGroup {
      Text("Vignette")
    } content: {
      Self.slider("Amount", vignette.amount, -1...1, step: 0.01, digits: 2)
      Self.percentSlider("Size", vignette.size)
      Self.percentSlider("Softness", vignette.softness)
    }
  }

  private func grain(_ grain: Binding<EditOptions.Grain>) -> some View {
    InspectorGroup {
      Text("Grain")
    } content: {
      Self.slider("Grain", grain.lum, EditOptions.Grain.strengthRange, step: 0.1, digits: 1)
      Self.slider("Size", grain.size, EditOptions.Grain.sizeRange, step: 0.01, digits: 2)
      Self.slider("Colour Noise", grain.chroma, EditOptions.Grain.strengthRange, step: 0.1, digits: 1)
      Self.slider("Colour Size", grain.csize, EditOptions.Grain.sizeRange, step: 0.01, digits: 2)
      Self.slider("Real Noise", grain.real, EditOptions.Grain.realRange, step: 0.01, digits: 2)
        .disabled(edit.context.realNoise == nil)
      Text(edit.missingDataNote ?? (edit.context.realNoise == nil ? "Real Noise needs a profile with real noise (Match Reference makes one)." : " "))
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .fixedSize(horizontal: false, vertical: true)
      InspectorRow {
        Text("Seed")
      } control: {
        HStack(spacing: 6) {
          TextField("", value: grain.seed, format: .number.grouping(.never))
            .labelsHidden()
            .accessibilityLabel("Seed")
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
          Button("New Grain") { edit.newGrain() }
            .controlSize(.small)
        }
      }
    }
  }

  // MARK: Rows

  /// A slider with its value beside it, typed into for values past the slider's ends. No
  /// `step:` on the slider (macOS draws a tick for each); the model snaps.
  static func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, digits: Int) -> some View {
    InspectorRow {
      Text(title)
    } control: {
      HStack(spacing: 6) {
        Slider(
          value: Binding(get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) }, set: { value.wrappedValue = EditOptions.snap($0, step: step) }),
          in: range
        ) { Text(title) }
          .labelsHidden()
          .controlSize(.small)
          .frame(minWidth: 80, maxWidth: 150)
        TextField("", value: value, format: .number.precision(.fractionLength(0...digits)))
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 52)
          .accessibilityLabel(title)
      }
    }
  }

  /// An amount from 0 to 1, shown in whole percents.
  static func percentSlider(_ title: String, _ value: Binding<Double>) -> some View {
    InspectorRow {
      Text(title)
    } control: {
      HStack(spacing: 6) {
        Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = EditOptions.snap($0, 0...1) }), in: 0...1) { Text(title) }
          .labelsHidden()
          .controlSize(.small)
          .frame(minWidth: 80, maxWidth: 150)
        Text("\(Int((value.wrappedValue * 100).rounded()))%")
          .monospacedDigit()
          .frame(width: 52, alignment: .trailing)
      }
    }
  }

  // MARK: Files

  private func openProfile() {
    fileDialogs.open = FileDialogs.Open(types: [.json]) { urls in
      guard let url = urls.first else { return }
      do { try edit.openProfile(at: url) } catch { self.error = error.localizedDescription }
    }
  }

  private func saveProfile() {
    let profile = edit.profileToSave
    fileDialogs.save = FileDialogs.Save(
      file: ExportedFile(type: .json) { try profile.encoded() }, name: "\(profile.name).\(GrainProfile.fileExtension)"
    ) { result in
      if case .failure(let error) = result { self.error = error.localizedDescription }
    }
  }

  private func loadLUT() {
    fileDialogs.open = FileDialogs.Open(types: UTType.cubeLUTFiles) { urls in
      guard let url = urls.first else { return }
      do { try edit.loadLUT(from: url) } catch { self.error = error.localizedDescription }
    }
  }

  private func exportLUT() {
    let name = edit.exportName
    fileDialogs.save = FileDialogs.Save(
      file: ExportedFile(type: .cubeLUT) { try await edit.exportLUT(name: name) }, name: name + ".cube"
    ) { result in
      if case .failure(let error) = result { self.error = error.localizedDescription }
    }
  }

  @concurrent private nonisolated static func decode(_ url: URL) async -> CGImage? {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    return ImageLoader.image(at: url)
  }

  private func chooseReferenceFile() {
    fileDialogs.open = FileDialogs.Open(types: [.image]) { urls in
      guard let url = urls.first else { return }
      Task {
        // Read off the main actor: a large file takes a while to decode.
        guard let image = await Self.decode(url) else {
          error = "“\(url.lastPathComponent)” couldn't be read as an image."
          return
        }
        await edit.setReference(image: image, name: url.deletingPathExtension().lastPathComponent)
      }
    }
  }

  private func chooseReferencePhoto() {
    fileDialogs.photos = FileDialogs.Photos { photos, _ in
      Task {
        guard let data = photos.first, let image = await EditModel.decode(data) else {
          error = "The photo couldn't be loaded."
          return
        }
        await edit.setReference(image: image, name: "Photo")
      }
    }
  }

  /// A History step as the reference, named by its step when it's in the image's own project.
  private func chooseReference(_ item: HistoryItem) async {
    guard let tensorId = item.imageTensorId, let image = await create.history.project.read({ $0.image(tensorId: tensorId) }) else {
      error = "The image couldn't be read."
      return
    }
    let sameProject = if case .step(let project, _) = edit.source { project == create.history.project.name } else { false }
    await edit.setReference(image: image, name: "Step \(item.id.logicalTime)", tensorId: sameProject ? tensorId : nil)
  }
}

private extension View {
  /// A menu showing a chosen name, laid out as the Create inspector's file pickers are: no wider
  /// than they go, shrinking with the column rather than setting its width, with the whole
  /// name in its help.
  func nameMenu(_ name: String?) -> some View {
    frame(maxWidth: 190, alignment: .trailing)
      .help(name ?? "")
  }
}

/// Choose History Step…: the current project's images, newest first, to take one as the reference.
private struct EditStepPicker: View {
  @Environment(HistoryStore.self) private var history
  @Environment(\.dismiss) private var dismiss
  let choose: (HistoryItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Choose a Reference").font(.headline)
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
          ForEach(history.items.filter { !$0.isVideo && $0.hasImage }, id: \.tensorId) { item in
            Button {
              choose(item)
              dismiss()
            } label: {
              Thumbnail(item: item)
                .frame(width: 110, height: 110)
                .clipShape(.rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(item.sidecar.prompt)
          }
        }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .sheetPadding()
    .frame(minWidth: 520, minHeight: 420)
  }
}
