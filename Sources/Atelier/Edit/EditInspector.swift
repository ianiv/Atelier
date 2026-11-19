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
      Text("Look").help("A grain profile to start from, and a reference image to match to.")
    } content: {
      InspectorRow {
        Text("Profile").layoutPriority(1).help(Self.profileHelp)
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
        .accessibilityHint(Self.profileHelp)
      }
      HStack(spacing: 6) {
        Button("Open Profile…") { openProfile() }
          .help("Open a .grain.json profile from anywhere, such as one saved by another copy of Atelier")
        Button("Save Profile…") { saveProfile() }
          .help("Save the current look as a .grain.json profile")
        Button("Add to Library") {
          do { try edit.addProfileToLibrary() } catch { self.error = error.localizedDescription }
        }
        .disabled(edit.profileIsInLibrary)
        .help("Add the current look to your profile library, so it's in the Profile menu")
      }
      .controlSize(.small)
      .padding(.vertical, 4)
      Divider().padding(.vertical, 4)
      InspectorRow {
        Text("Reference").layoutPriority(1).help(Self.referenceHelp)
      } control: {
        referenceMenu.nameMenu(edit.reference?.name)
          .accessibilityHint(Self.referenceHelp)
      }
      HStack(spacing: 6) {
        Button("Match Reference") { Task { await edit.matchReference() } }
          .disabled(!edit.canMatchReference)
          .help("Measure the reference photo's grain and colour, then set the grain sliders and Profile Colour to match it")
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
    guard let reference = edit.reference else { return "No reference chosen." }
    return reference.image == nil
      ? "Matched to “\(reference.name)” when it was saved."
      : "“\(reference.name)”. Match Reference takes on its grain."
  }

  private var referenceMenu: some View {
    Menu {
      Button("Choose File…") { chooseReferenceFile() }
      Button("From Photos…") { chooseReferencePhoto() }
      Button("Step's Input") {
        if let original = edit.original, let image = original.image {
          Task { await edit.setReference(image: image, name: "Step's Input", tensorId: original.tensorId) }
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
      Text("Match").help("Moves the image's colours and tones toward a reference or the step's input.")
    } content: {
      InspectorRow {
        Text("Match to").lineLimit(1).fixedSize().help(Self.matchToHelp)
      } control: {
        MatchTargetControl(
          target: Binding(get: { edit.options.match.target }, set: { edit.setMatchTarget($0) }),
          hasReference: edit.reference != nil, hasInput: edit.original != nil)
          .help(Self.matchToHelp)
          .accessibilityHint(Self.matchToHelp)
      }
      Text(noLab ? (edit.options.match.target == .reference ? "Choose a reference to match to." : "This image wasn't made from an input image.") : "Moves the colours toward \(target?.name ?? "it").")
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Self.percentSlider("Tint", options.match.tint, help: "How far the colour cast moves toward the target's, in Lab, from 0% (leave it) to 100% (match it).").disabled(noLab)
      Self.percentSlider("Saturation", options.match.saturation, help: "How far the colourfulness moves toward the target's, in Lab, from 0% to 100%.").disabled(noLab)
      Self.percentSlider("Brightness", options.match.brightness, help: "How far the average brightness moves toward the target's, in Lab, from 0% to 100%.").disabled(noLab)
      Self.percentSlider("Contrast", options.match.contrast, help: "How far the spread of brightness moves toward the target's, in Lab, from 0% to 100%.").disabled(noLab)
      Self.percentSlider("Histogram", options.histogram.amount, help: "Reshapes the image's tones to the target's distribution, blended in by this amount.").disabled(noHistogram)
      InspectorRow {
        Text("Histogram of").help(Self.histogramOfHelp)
      } control: {
        Picker("Histogram of", selection: options.histogram.space) {
          Text("Luma").tag(EditOptions.Histogram.Space.luma)
          Text("RGB").tag(EditOptions.Histogram.Space.rgb)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(Self.histogramOfHelp)
        .accessibilityHint(Self.histogramOfHelp)
      }
      .disabled(noHistogram)
      Self.slider("Profile Colour", options.match.colour, 0...1, step: 0.01, digits: 2, help: "Moves each RGB channel's average and spread toward the loaded profile's reference photo, 0 to 1. Ignores Match to, and needs a profile with colour data; Match Reference sets it to 0.6.")
        .disabled(edit.context.refStats == nil)
    }
  }

  private func grade(_ grade: Binding<EditOptions.Grade>) -> some View {
    InspectorGroup {
      Text("Grade").help("Basic colour and tone adjustments, applied in this order.")
    } content: {
      Self.slider("Exposure", grade.exposure, EditOptions.Grade.exposureRange, step: 0.01, digits: 2, help: "Brightens or darkens the image in stops: +1 doubles the light, −1 halves it.")
      Self.slider("Temperature", grade.temperature, EditOptions.Grade.temperatureRange, step: 1, digits: 0, help: "Warms (+) or cools (−) the white balance, −100 to 100.")
      Self.slider("Tint", grade.tint, EditOptions.Grade.tintRange, step: 0.1, digits: 1, help: "Shifts the colour toward green (−) or magenta (+).")
      Self.slider("Contrast", grade.contrast, EditOptions.Grade.unitRange, step: 0.01, digits: 2, help: "Raises (+) or lowers (−) contrast around mid grey, −1 to 1.")
      Self.slider("Saturation", grade.saturation, EditOptions.Grade.unitRange, step: 0.01, digits: 2, help: "Makes colours stronger (+) or weaker (−); −1 is black and white.")
      Self.slider("Vibrance", grade.vibrance, EditOptions.Grade.unitRange, step: 0.01, digits: 2, help: "Saturation that boosts muted colours more than vivid ones and mostly spares skin tones, −1 to 1.")
    }
  }

  private func lut(_ lut: Binding<EditOptions.LUTRef>) -> some View {
    InspectorGroup {
      Text("LUT").help("A 3D colour lookup table, built in or loaded from a .cube file.")
    } content: {
      InspectorRow {
        Text("LUT").layoutPriority(1).help(Self.lutHelp)
      } control: {
        lutMenu.nameMenu(edit.lut?.name)
          .accessibilityHint(Self.lutHelp)
      }
      HStack(spacing: 6) {
        Button("Load .cube…") { loadLUT() }
          .help("Load a 3D LUT in the Adobe/Resolve .cube format and apply it at full strength")
        Button("Remove") { edit.removeLUT() }
          .disabled(edit.lut == nil && edit.fileLUT == nil)
          .help("Take the LUT off and drop the loaded file's LUT from the menu")
      }
      .controlSize(.small)
      .padding(.vertical, 4)
      Self.percentSlider("Strength", lut.strength, help: "How much of the LUT's look is blended in, from 0% to 100%.").disabled(edit.lut == nil)
      InspectorRow {
        Text("Match and Grade as a LUT").font(.caption).foregroundStyle(.secondary).help(Self.exportLUTHelp)
      } control: {
        Button("Export LUT…") { exportLUT() }
          .controlSize(.small)
          .disabled(edit.isExporting)
          .help(Self.exportLUTHelp)
      }
    }
  }

  private func halation(_ halation: Binding<EditOptions.Halation>) -> some View {
    InspectorGroup {
      Text("Halation").help("A warm glow around highlights, as film gives.")
    } content: {
      Self.percentSlider("Amount", halation.amount, help: "How strong the glow around highlights is, as film gives.")
      Self.slider("Threshold", halation.threshold, 0...1, step: 0.01, digits: 2, help: "How bright light must be before it glows, 0 to 1. Lower makes more of the image glow.")
      Self.slider("Radius", halation.radius, EditOptions.Halation.radiusRange, step: 0.1, digits: 1, help: "How far the glow spreads, in pixels at full size.")
      Self.percentSlider("Warmth", halation.warmth, help: "The glow's colour, from the highlight's own colour (0%) to film's red-orange (100%).")
    }
  }

  private func lens(_ lens: Binding<EditOptions.Lens>) -> some View {
    InspectorGroup {
      Text("Lens").help("Motion smear and softening, applied before everything else.")
    } content: {
      Self.slider("Motion", lens.motion, EditOptions.Lens.motionRange, step: 0.1, digits: 1, help: "The length of a slow-shutter motion smear, in pixels at full size. Below 2 there's none.")
      Self.slider("Angle", lens.angle, EditOptions.Lens.angleRange, step: 1, digits: 0, help: "The direction of the motion smear, in degrees; 0 is horizontal.")
      Self.slider("Blur", lens.blur, EditOptions.Lens.blurRange, step: 0.01, digits: 2, help: "Softens the image before the grain is added, in pixels. The default is 3.")
    }
  }

  private func vignette(_ vignette: Binding<EditOptions.Vignette>) -> some View {
    InspectorGroup {
      Text("Vignette").help("Darkens or brightens toward the corners.")
    } content: {
      Self.slider("Amount", vignette.amount, -1...1, step: 0.01, digits: 2, help: "Darkens the corners; below 0 it brightens the edges instead.")
      Self.percentSlider("Size", vignette.size, help: "Where the falloff starts, from the centre (0%) to the corners (100%).")
      Self.percentSlider("Softness", vignette.softness, help: "How gradual the falloff is, from a hard edge (0%) to the softest (100%).")
    }
  }

  private func grain(_ grain: Binding<EditOptions.Grain>) -> some View {
    InspectorGroup {
      Text("Grain").help("Film grain, plus the profile's real noise.")
    } content: {
      Self.slider("Grain", grain.lum, EditOptions.Grain.strengthRange, step: 0.1, digits: 1, help: "The strength of the brightness grain. The default is 9.")
      Self.slider("Size", grain.size, EditOptions.Grain.sizeRange, step: 0.01, digits: 2, help: "How coarse the grain is; 1 is the default, higher is coarser.")
      Self.slider("Colour Noise", grain.chroma, EditOptions.Grain.strengthRange, step: 0.1, digits: 1, help: "The strength of the coloured grain. The default is 3.")
      Self.slider("Colour Size", grain.csize, EditOptions.Grain.sizeRange, step: 0.01, digits: 2, help: "How large the colour noise blotches are; 1 is the default.")
      Self.slider("Real Noise", grain.real, EditOptions.Grain.realRange, step: 0.01, digits: 2, help: "Adds the profile's real noise, sampled from its reference photo; 1 is the reference's amount. Needs a profile with real noise.")
        .disabled(edit.context.realNoise == nil)
      Text(edit.missingDataNote ?? (edit.context.realNoise == nil ? "Real Noise needs a profile with real noise (Match Reference makes one)." : " "))
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .fixedSize(horizontal: false, vertical: true)
      InspectorRow {
        Text("Seed").help(Self.seedHelp)
      } control: {
        HStack(spacing: 6) {
          TextField("", value: grain.seed, format: .number.grouping(.never))
            .labelsHidden()
            .accessibilityLabel("Seed")
            .accessibilityHint(Self.seedHelp)
            .help(Self.seedHelp)
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
          Button("New Grain") { edit.newGrain() }
            .controlSize(.small)
            .help("Pick a new random seed: a different grain pattern with the same look")
        }
      }
    }
  }

  // MARK: Help

  // Tooltips shared by a row's label and its control.
  private static let profileHelp = "A grain profile from your library: its grain, blur and colour settings, and its grain data. None clears the grain data and keeps the settings."
  private static let referenceHelp = "An image the matches move toward and Match Reference measures: a file, a photo, the step's input, a moodboard picture or a History step."
  private static let matchToHelp = "What the matches move toward: the Reference, or Step's Input, the image the step was made from (unavailable when there's none)."
  private static let histogramOfHelp = "Luma matches brightness only and keeps the image's own colours; RGB matches each channel and takes the target's colour balance. A strong luma match bakes less exactly into an exported LUT in deep shadows."
  private static let lutHelp = "None, a built-in look, or the LUT loaded from a file. Changing it keeps the Strength."
  private static let exportLUTHelp = "Bake the matches, grade and LUT, as they are for this image, into a 33³ .cube file for other apps. Blur, halation, vignette and grain aren't included."
  private static let seedHelp = "The grain's random pattern. A different seed gives a different pattern with the same look."

  // MARK: Rows

  /// A slider with its value beside it, typed into for values past the slider's ends. No
  /// `step:` on the slider (macOS draws a tick for each); the model snaps.
  static func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, digits: Int, help: String) -> some View {
    sliderRow(title, help: help) {
      Slider(
        value: Binding(get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) }, set: { value.wrappedValue = EditOptions.snap($0, step: step) }),
        in: range
      ) { Text(title) }
    } value: {
      TextField("", value: value, format: .number.precision(.fractionLength(0...digits)))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(title)
    }
  }

  /// An amount from 0 to 1, shown in whole percents.
  static func percentSlider(_ title: String, _ value: Binding<Double>, help: String) -> some View {
    sliderRow(title, help: help) {
      Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = EditOptions.snap($0, 0...1) }), in: 0...1) { Text(title) }
    } value: {
      Text("\(Int((value.wrappedValue * 100).rounded()))%")
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  /// A slider row with its label in a fixed column, so every slider on the screen starts at the
  /// same place and has the same width whatever its label's length; `InspectorRow` sizes the
  /// control from what the label leaves, which made a long label's slider shorter. `help` is
  /// the label's and the slider's tooltip, and the slider's VoiceOver hint.
  private static func sliderRow(_ title: String, help: String, @ViewBuilder slider: () -> some View, @ViewBuilder value: () -> some View) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: sliderLabelWidth, alignment: .leading)
        .help(help)
      slider()
        .labelsHidden()
        .controlSize(.small)
        .frame(minWidth: 60, maxWidth: .infinity)
        .help(help)
        .accessibilityHint(help)
      value()
        .frame(width: 52)
    }
    .frame(minHeight: 28)
    .padding(.vertical, 2)
  }

  #if os(macOS)
  private static let sliderLabelWidth: CGFloat = 92
  #else
  private static let sliderLabelWidth: CGFloat = 112
  #endif

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

/// Reference / Step's Input, drawn like a segmented picker. A stock segmented `Picker` ignores
/// `.disabled` on its segments, and each target has to be unavailable when there's nothing to
/// match to: Reference until one is chosen, Step's Input for a step made from no image.
private struct MatchTargetControl: View {
  @Binding var target: EditOptions.Match.Target
  let hasReference: Bool
  let hasInput: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    HStack(spacing: 0) {
      segment("Reference", .reference, available: hasReference)
      segment("Step's Input", .original, available: hasInput)
    }
    .padding(2)
    .background(.fill.tertiary, in: .capsule)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Match to")
  }

  private func segment(_ title: String, _ option: EditOptions.Match.Target, available: Bool) -> some View {
    let selected = target == option
    let enabled = isEnabled && available
    return Text(title)
      .lineLimit(1)
      .padding(.horizontal, Self.horizontalPadding)
      .padding(.vertical, Self.verticalPadding)
      .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      .background {
        if selected {
          Capsule()
            .fill(colorScheme == .dark ? Color.white.opacity(enabled ? 0.22 : 0.1) : Color.white.opacity(enabled ? 1 : 0.6))
            .shadow(color: .black.opacity(colorScheme == .dark || !enabled ? 0 : 0.12), radius: 1, y: 0.5)
        }
      }
      .contentShape(.capsule)
      .onTapGesture { if enabled { target = option } }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction { if enabled { target = option } }
      .disabled(!available)
  }

  #if os(macOS)
  private static let horizontalPadding: CGFloat = 10
  private static let verticalPadding: CGFloat = 3
  #else
  private static let horizontalPadding: CGFloat = 12
  private static let verticalPadding: CGFloat = 6
  #endif
}
