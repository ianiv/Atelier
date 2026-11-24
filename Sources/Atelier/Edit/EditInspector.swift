import SwiftUI
import UniformTypeIdentifiers

/// The Edit screen's inspector: the Look checkbox, then Profile, Match, Grade, LUT, Halation, Lens, Vignette and Grain, in
/// pipeline order but for Lens, listed after Halation though the renderer applies its smear and
/// blur first (`EditPipeline`). Every control is always there; one that can't do anything yet (no image, no
/// reference to match, no LUT, no real noise in the profile) is disabled, with a line saying why
/// where it isn't plain. Sliders show their value beside them, typed into to go past the
/// slider's range (grain.py's own settings aren't capped), as the Create inspector's do.
///
/// Each section is a view of its own, handed only its part of the look (`EditLookSections`):
/// a slider dragged in one ticks every 16 ms, and working out the whole inspector's body (and
/// every slider's) on each tick held up the main thread long enough to make the drag stutter.
/// Now a tick works out the section the slider is in, and the others are left as they are.
///
/// Each settings section has a checkbox in its header (`EditStageHeader`) that turns its stage
/// on and off, its settings kept (`EditOptions.off`); while it's off its controls are disabled,
/// not hidden, so a slider never moves with nothing changing on screen. Above them all, the Look
/// checkbox (`EditLookSwitch`) turns the whole look off and on, leaving the stages' checkboxes
/// as they are (`EditOptions.lookOff`). That's the one exception: with the look off, the
/// sections stay usable (so their checkboxes and settings can be set for when it's back on)
/// though nothing they change shows.
struct EditInspector: View {
  @Environment(EditModel.self) private var edit
  @Environment(CreateModel.self) private var create
  @State private var choosingStep = false
  @State private var error: String?

  var body: some View {
    let _ = EditViewCounts.note("EditInspector")
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        EditLookSwitch()
        EditLookSection(choosingStep: $choosingStep, error: $error)
        EditLookSections(error: $error)
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

  /// A History step as the reference, named by its step when it's in the image's own project.
  private func chooseReference(_ item: HistoryItem) async {
    guard let tensorId = item.imageTensorId, let image = await create.history.project.read({ $0.image(tensorId: tensorId) }) else {
      error = "The image couldn't be read."
      return
    }
    let sameProject = if case .step(let project, _) = edit.source { project == create.history.project.name } else { false }
    await edit.setReference(image: image, name: "Step \(item.id.logicalTime)", tensorId: sameProject ? tensorId : nil)
  }

  /// A menu's label showing a name someone chose (a file's, a profile's): one line, cut in the
  /// middle where file names differ least, so a long one never widens the column.
  static func nameLabel(_ name: String?) -> some View {
    Text(name ?? "None").lineLimit(1).truncationMode(.middle)
  }

  // MARK: Help

  // Tooltips shared by a row's label and its control.
  fileprivate static let profileHelp = "A grain profile from your library: its grain, blur and colour settings, and its grain data. None clears the grain data and keeps the settings."
  fileprivate static let referenceHelp = "An image the matches move toward and Match Reference measures: a file, a photo, the step's input, a moodboard picture or a History step."
  fileprivate static let matchToHelp = "What the matches move toward: the Reference, or Step's Input, the image the step was made from (unavailable when there's none)."
  fileprivate static let histogramOfHelp = "Luma matches brightness only and keeps the image's own colours; RGB matches each channel and takes the target's colour balance. A strong luma match bakes less exactly into an exported LUT in deep shadows."
  fileprivate static let lutHelp = "None, a built-in look, or the LUT loaded from a file. Changing it keeps the Strength."
  fileprivate static let exportLUTHelp = "Bake the matches, grade and LUT, as they are for this image, into a 33³ .cube file for other apps. Blur, halation, vignette and grain aren't included."
  fileprivate static let seedHelp = "The grain's random pattern. A different seed gives a different pattern with the same look."

  // MARK: Rows

  /// A slider with its value beside it, typed into for values past the slider's ends: `value`
  /// is the setting at `path` of the look, as the section has it. No `step:` on the slider
  /// (macOS draws a tick for each); the model snaps.
  static func slider(
    _ title: String, _ value: Double, _ path: WritableKeyPath<EditOptions, Double>, _ range: ClosedRange<Double>, step: Double, digits: Int, help: String
  ) -> some View {
    EditSliderRow(title: title, value: value, path: path, range: range, step: step, digits: digits, help: help).equatable()
  }

  /// An amount from 0 to 1, shown in whole percents.
  static func percentSlider(_ title: String, _ value: Double, _ path: WritableKeyPath<EditOptions, Double>, help: String) -> some View {
    EditSliderRow(title: title, value: value, path: path, range: 0...1, step: nil, digits: 0, help: help).equatable()
  }

  /// A slider row with its label in a fixed column, so every slider on the screen starts at the
  /// same place and has the same width whatever its label's length; `InspectorRow` sizes the
  /// control from what the label leaves, which made a long label's slider shorter. `help` is
  /// the label's and the slider's tooltip, and the slider's VoiceOver hint.
  fileprivate static func sliderRow(_ title: String, help: String, @ViewBuilder slider: () -> some View, @ViewBuilder value: () -> some View) -> some View {
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
}

// MARK: - Look

/// The Profile section: the grain profile and the reference. It reads none of the look's settings, so a
/// slider moving leaves it alone.
private struct EditLookSection: View {
  @Environment(EditModel.self) private var edit
  @Environment(CreateModel.self) private var create
  @Environment(FileDialogs.self) private var fileDialogs
  @Binding var choosingStep: Bool
  @Binding var error: String?

  var body: some View {
    let _ = EditViewCounts.note("EditInspector Look")
    InspectorGroup {
      Text("Profile").help("A grain profile to start from, and a reference image to match to.")
    } content: {
      InspectorRow {
        Text("Profile").layoutPriority(1).help(EditInspector.profileHelp)
      } control: {
        Menu {
          Button("None") { edit.applyProfile(nil) }
          if !edit.profiles.profiles.isEmpty { Divider() }
          ForEach(edit.profiles.profiles, id: \.name) { profile in
            Button(profile.name) { edit.applyProfile(profile) }
          }
        } label: {
          EditInspector.nameLabel(edit.profile?.name)
        }
        .nameMenu(edit.profile?.name)
        .accessibilityHint(EditInspector.profileHelp)
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
        Text("Reference").layoutPriority(1).help(EditInspector.referenceHelp)
      } control: {
        referenceMenu.nameMenu(edit.reference?.name)
          .accessibilityHint(EditInspector.referenceHelp)
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
      EditInspector.nameLabel(edit.reference?.name)
    }
  }

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
}

// MARK: - The look's settings

/// The sections of the look's settings, each handed its own part of `EditModel.options`. This
/// view reads the options, so it's worked out again on every change, but its body is only the
/// sections; each is `Equatable` on its part, so the sections whose part didn't change are
/// left as they are rather than worked out again with all their sliders.
private struct EditLookSections: View {
  @Environment(EditModel.self) private var edit
  @Binding var error: String?

  var body: some View {
    let _ = EditViewCounts.note("EditInspector settings")
    let options = edit.options
    EditMatchSection(match: options.match, histogram: options.histogram, isOn: options.isOn(.match)).equatable()
    EditGradeSection(grade: options.grade, isOn: options.isOn(.grade)).equatable()
    EditLUTSection(lut: options.lut, isOn: options.isOn(.lut), error: $error).equatable()
    EditHalationSection(halation: options.halation, isOn: options.isOn(.halation)).equatable()
    EditLensSection(lens: options.lens, isOn: options.isOn(.lens)).equatable()
    EditVignetteSection(vignette: options.vignette, isOn: options.isOn(.vignette)).equatable()
    EditGrainSection(grain: options.grain, isOn: options.isOn(.grain)).equatable()
  }
}

/// A settings section's header: the checkbox that turns its stage on and off, with the title as
/// its label, as the Create inspector's feature sections have them. Clicking the title flips it,
/// as a checkbox's label does; on iPad, where it's a switch, tapping the title does too. One
/// control, named by the title. The checkbox reads `isOn`, the stage as the section has it, not
/// `options`, so it doesn't tie the section to the whole look.
private struct EditStageHeader: View {
  @Environment(EditModel.self) private var edit
  let stage: EditOptions.Stage
  let isOn: Bool
  /// What the section does, the header's tooltip.
  let help: String

  var body: some View {
    EditTitleToggle(
      title: stage.title, isOn: Binding(get: { isOn }, set: { edit.setStage(stage, on: $0) }),
      help: "\(help) Turning it off keeps its settings.")
  }
}

/// The Look checkbox above the sections: the whole look off and on (`EditModel.setLook(on:)`),
/// each stage's checkbox and setting left as it is, so they stay clickable while it's off and
/// turning it back on brings back the stages that were on. Styled as a section's header.
private struct EditLookSwitch: View {
  @Environment(EditModel.self) private var edit

  var body: some View {
    let lookOn = !edit.options.lookOff
    EditTitleToggle(
      title: "Look", isOn: Binding(get: { lookOn }, set: { edit.setLook(on: $0) }),
      help: "The whole look. Turning it off shows and saves the image without it, and keeps every section's checkbox and settings.")
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 4)
  }
}

/// A checkbox with a title as its label: clicking the title flips it, as a checkbox's label
/// does; on iPad, where it's a switch, tapping the title does too. One control, named by the
/// title.
private struct EditTitleToggle: View {
  let title: String
  let isOn: Binding<Bool>
  let help: String

  var body: some View {
    #if os(macOS)
      Toggle(isOn: isOn) { Text(title) }
        .checkboxToggleStyle()
        .help(help)
    #else
      // A switch's label doesn't flip it, and the switch goes before the title as the Mac's
      // checkbox does: the title is a tap target of its own, hidden from VoiceOver, which
      // reads the switch by the title.
      HStack(spacing: 6) {
        Toggle(title, isOn: isOn)
          .checkboxToggleStyle()
          .labelsHidden()
        Text(title)
          .contentShape(Rectangle())
          .onTapGesture { isOn.wrappedValue.toggle() }
          .accessibilityHidden(true)
      }
      .help(help)
    #endif
  }
}

extension EditModel {
  /// A binding to one setting of the look for a section handed its part of it: it reads `value`,
  /// the part as the section has it, rather than `options` (which would make every control
  /// depend on the whole look), and writes through `options`, snapped as ever.
  func binding<Part, Value>(_ value: Part, _ part: WritableKeyPath<EditOptions, Part>, _ setting: WritableKeyPath<Part, Value>) -> Binding<Value> {
    let path = part.appending(path: setting)
    return Binding(get: { value[keyPath: setting] }, set: { self.options[keyPath: path] = $0 })
  }
}

private struct EditMatchSection: View, Equatable {
  @Environment(EditModel.self) private var edit
  let match: EditOptions.Match
  let histogram: EditOptions.Histogram
  let isOn: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.match == rhs.match && lhs.histogram == rhs.histogram && lhs.isOn == rhs.isOn }

  var body: some View {
    let _ = EditViewCounts.note("EditInspector Match")
    // `EditModel.matchTarget`, from the target as this section has it.
    let target = match.target == .reference ? edit.reference : edit.original
    let noLab = target?.lab == nil
    let noHistogram = target?.histogram == nil
    InspectorGroup {
      EditStageHeader(stage: .match, isOn: isOn, help: "Moves the image's colours and tones toward a reference or the step's input.")
    } content: {
      Group {
        InspectorRow {
          Text("Match to").lineLimit(1).fixedSize().help(EditInspector.matchToHelp)
        } control: {
          MatchTargetControl(
            target: Binding(get: { match.target }, set: { edit.setMatchTarget($0) }),
            hasReference: edit.reference != nil, hasInput: edit.original != nil)
            .help(EditInspector.matchToHelp)
            .accessibilityHint(EditInspector.matchToHelp)
        }
        Text(noLab ? (match.target == .reference ? "Choose a reference to match to." : "This image wasn't made from an input image.") : "Moves the colours toward \(target?.name ?? "it").")
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(2, reservesSpace: true)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        EditInspector.percentSlider("Tint", match.tint, \.match.tint, help: "How far the colour cast moves toward the target's, in Lab, from 0% (leave it) to 100% (match it).").disabled(noLab)
        EditInspector.percentSlider("Saturation", match.saturation, \.match.saturation, help: "How far the colourfulness moves toward the target's, in Lab, from 0% to 100%.").disabled(noLab)
        EditInspector.percentSlider("Brightness", match.brightness, \.match.brightness, help: "How far the average brightness moves toward the target's, in Lab, from 0% to 100%.").disabled(noLab)
        EditInspector.percentSlider("Contrast", match.contrast, \.match.contrast, help: "How far the spread of brightness moves toward the target's, in Lab, from 0% to 100%.").disabled(noLab)
        EditInspector.percentSlider("Histogram", histogram.amount, \.histogram.amount, help: "Reshapes the image's tones to the target's distribution, blended in by this amount.").disabled(noHistogram)
        InspectorRow {
          Text("Histogram of").help(EditInspector.histogramOfHelp)
        } control: {
          Picker("Histogram of", selection: edit.binding(histogram, \.histogram, \.space)) {
            Text("Luma").tag(EditOptions.Histogram.Space.luma)
            Text("RGB").tag(EditOptions.Histogram.Space.rgb)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          .help(EditInspector.histogramOfHelp)
          .accessibilityHint(EditInspector.histogramOfHelp)
        }
        .disabled(noHistogram)
        EditInspector.slider("Profile Colour", match.colour, \.match.colour, 0...1, step: 0.01, digits: 2, help: "Moves each RGB channel's average and spread toward the loaded profile's reference photo, 0 to 1. Ignores Match to, and needs a profile with colour data; Match Reference sets it to 0.6.")
          .disabled(edit.context.refStats == nil)
      }
      .disabled(!isOn)
    }
  }
}

private struct EditGradeSection: View, Equatable {
  @Environment(EditModel.self) private var edit
  let grade: EditOptions.Grade
  let isOn: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.grade == rhs.grade && lhs.isOn == rhs.isOn }

  var body: some View {
    let _ = EditViewCounts.note("EditInspector Grade")
    InspectorGroup {
      EditStageHeader(stage: .grade, isOn: isOn, help: "Basic colour and tone adjustments, applied in this order.")
    } content: {
      Group {
        EditInspector.slider("Exposure", grade.exposure, \.grade.exposure, EditOptions.Grade.exposureRange, step: 0.01, digits: 2, help: "Brightens or darkens the image in stops: +1 doubles the light, −1 halves it.")
        EditInspector.slider("Temperature", grade.temperature, \.grade.temperature, EditOptions.Grade.temperatureRange, step: 1, digits: 0, help: "Warms (+) or cools (−) the white balance, −100 to 100.")
        EditInspector.slider("Tint", grade.tint, \.grade.tint, EditOptions.Grade.tintRange, step: 0.1, digits: 1, help: "Shifts the colour toward green (−) or magenta (+).")
        EditInspector.slider("Contrast", grade.contrast, \.grade.contrast, EditOptions.Grade.unitRange, step: 0.01, digits: 2, help: "Raises (+) or lowers (−) contrast around mid grey, −1 to 1.")
        EditInspector.slider("Saturation", grade.saturation, \.grade.saturation, EditOptions.Grade.unitRange, step: 0.01, digits: 2, help: "Makes colours stronger (+) or weaker (−); −1 is black and white.")
        EditInspector.slider("Vibrance", grade.vibrance, \.grade.vibrance, EditOptions.Grade.unitRange, step: 0.01, digits: 2, help: "Saturation that boosts muted colours more than vivid ones and mostly spares skin tones, −1 to 1.")
      }
      .disabled(!isOn)
    }
  }
}

private struct EditLUTSection: View, Equatable {
  @Environment(EditModel.self) private var edit
  @Environment(FileDialogs.self) private var fileDialogs
  let lut: EditOptions.LUTRef
  let isOn: Bool
  @Binding var error: String?

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.lut == rhs.lut && lhs.isOn == rhs.isOn }

  var body: some View {
    let _ = EditViewCounts.note("EditInspector LUT")
    InspectorGroup {
      EditStageHeader(stage: .lut, isOn: isOn, help: "A 3D colour lookup table, built in or loaded from a .cube file.")
    } content: {
      // The LUT's own controls; Export LUT… stays usable with the LUT off, as it bakes the
      // match and grade too (without the LUT, as they render).
      Group {
        InspectorRow {
          Text("LUT").layoutPriority(1).help(EditInspector.lutHelp)
        } control: {
          lutMenu.nameMenu(edit.lut?.name)
            .accessibilityHint(EditInspector.lutHelp)
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
        EditInspector.percentSlider("Strength", lut.strength, \.lut.strength, help: "How much of the LUT's look is blended in, from 0% to 100%.").disabled(edit.lut == nil)
      }
      .disabled(!isOn)
      InspectorRow {
        Text("Match and Grade as a LUT").font(.caption).foregroundStyle(.secondary).help(EditInspector.exportLUTHelp)
      } control: {
        Button("Export LUT…") { exportLUT() }
          .controlSize(.small)
          .disabled(edit.isExporting)
          .help(EditInspector.exportLUTHelp)
      }
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
      EditInspector.nameLabel(edit.lut?.name)
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
}

private struct EditHalationSection: View, Equatable {
  @Environment(EditModel.self) private var edit
  let halation: EditOptions.Halation
  let isOn: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.halation == rhs.halation && lhs.isOn == rhs.isOn }

  var body: some View {
    let _ = EditViewCounts.note("EditInspector Halation")
    InspectorGroup {
      EditStageHeader(stage: .halation, isOn: isOn, help: "A warm glow around highlights, as film gives.")
    } content: {
      Group {
        EditInspector.percentSlider("Amount", halation.amount, \.halation.amount, help: "How strong the glow around highlights is, as film gives.")
        EditInspector.slider("Threshold", halation.threshold, \.halation.threshold, 0...1, step: 0.01, digits: 2, help: "How bright light must be before it starts to glow, 0 to 1. Only the light past it glows, more the further past it is.")
        EditInspector.slider("Radius", halation.radius, \.halation.radius, EditOptions.Halation.radiusRange, step: 0.1, digits: 1, help: "How far the glow spreads, in pixels at full size.")
        EditInspector.percentSlider("Warmth", halation.warmth, \.halation.warmth, help: "The glow's colour, from the highlight's own colour (0%) to film's red-orange (100%).")
      }
      .disabled(!isOn)
    }
  }
}

private struct EditLensSection: View, Equatable {
  @Environment(EditModel.self) private var edit
  let lens: EditOptions.Lens
  let isOn: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.lens == rhs.lens && lhs.isOn == rhs.isOn }

  var body: some View {
    let _ = EditViewCounts.note("EditInspector Lens")
    InspectorGroup {
      EditStageHeader(stage: .lens, isOn: isOn, help: "Motion smear and softening, applied before everything else.")
    } content: {
      Group {
        EditInspector.slider("Motion", lens.motion, \.lens.motion, EditOptions.Lens.motionRange, step: 0.1, digits: 1, help: "The length of a slow-shutter motion smear, in pixels at full size. Below 2 there's none.")
        EditInspector.slider("Angle", lens.angle, \.lens.angle, EditOptions.Lens.angleRange, step: 1, digits: 0, help: "The direction of the motion smear, in degrees; 0 is horizontal.")
        EditInspector.slider("Blur", lens.blur, \.lens.blur, EditOptions.Lens.blurRange, step: 0.01, digits: 2, help: "Softens the image before the grain is added, in pixels. The default is 3.")
      }
      .disabled(!isOn)
    }
  }
}

private struct EditVignetteSection: View, Equatable {
  @Environment(EditModel.self) private var edit
  let vignette: EditOptions.Vignette
  let isOn: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.vignette == rhs.vignette && lhs.isOn == rhs.isOn }

  var body: some View {
    let _ = EditViewCounts.note("EditInspector Vignette")
    InspectorGroup {
      EditStageHeader(stage: .vignette, isOn: isOn, help: "Darkens or brightens toward the corners.")
    } content: {
      Group {
        EditInspector.slider("Amount", vignette.amount, \.vignette.amount, -1...1, step: 0.01, digits: 2, help: "Darkens the corners; below 0 it brightens the edges instead.")
        EditInspector.percentSlider("Size", vignette.size, \.vignette.size, help: "Where the falloff starts, from the centre (0%) to the corners (100%).")
        EditInspector.percentSlider("Softness", vignette.softness, \.vignette.softness, help: "How gradual the falloff is, from a hard edge (0%) to the softest (100%).")
      }
      .disabled(!isOn)
    }
  }
}

private struct EditGrainSection: View, Equatable {
  @Environment(EditModel.self) private var edit
  let grain: EditOptions.Grain
  let isOn: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.grain == rhs.grain && lhs.isOn == rhs.isOn }

  var body: some View {
    let _ = EditViewCounts.note("EditInspector Grain")
    InspectorGroup {
      EditStageHeader(stage: .grain, isOn: isOn, help: "Film grain, plus the profile's real noise.")
    } content: {
      Group {
        EditInspector.slider("Grain", grain.lum, \.grain.lum, EditOptions.Grain.strengthRange, step: 0.1, digits: 1, help: "The strength of the brightness grain. The default is 9.")
        EditInspector.slider("Size", grain.size, \.grain.size, EditOptions.Grain.sizeRange, step: 0.01, digits: 2, help: "How coarse the grain is; 1 is the default, higher is coarser.")
        EditInspector.slider("Colour Noise", grain.chroma, \.grain.chroma, EditOptions.Grain.strengthRange, step: 0.1, digits: 1, help: "The strength of the coloured grain. The default is 3.")
        EditInspector.slider("Colour Size", grain.csize, \.grain.csize, EditOptions.Grain.sizeRange, step: 0.01, digits: 2, help: "How large the colour noise blotches are; 1 is the default.")
        EditInspector.slider("Real Noise", grain.real, \.grain.real, EditOptions.Grain.realRange, step: 0.01, digits: 2, help: "Adds the profile's real noise, sampled from its reference photo; 1 is the reference's amount. Needs a profile with real noise.")
          .disabled(edit.context.realNoise == nil)
        Text(edit.missingDataNote ?? (edit.context.realNoise == nil ? "Real Noise needs a profile with real noise (Match Reference makes one)." : " "))
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(2, reservesSpace: true)
          .fixedSize(horizontal: false, vertical: true)
        InspectorRow {
          Text("Seed").help(EditInspector.seedHelp)
        } control: {
          HStack(spacing: 6) {
            TextField("", value: bind(\.seed), format: .number.grouping(.never))
              .labelsHidden()
              .accessibilityLabel("Seed")
              .accessibilityHint(EditInspector.seedHelp)
              .help(EditInspector.seedHelp)
              .multilineTextAlignment(.trailing)
              .frame(width: 80)
            Button("New Grain") { edit.newGrain() }
              .controlSize(.small)
              .help("Pick a new random seed: a different grain pattern with the same look")
          }
        }
      }
      .disabled(!isOn)
    }
  }

  private func bind<Value>(_ setting: WritableKeyPath<EditOptions.Grain, Value>) -> Binding<Value> { edit.binding(grain, \.grain, setting) }
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

/// A slider row of the inspector (`EditInspector.slider`, `percentSlider`), a view of its own
/// that's `Equatable` on its value: a section worked out again on a tick of one of its sliders
/// leaves its other rows, and their AppKit slider and text field, as they are.
private struct EditSliderRow: View, Equatable {
  @Environment(EditModel.self) private var edit
  let title: String
  let value: Double
  let path: WritableKeyPath<EditOptions, Double>
  let range: ClosedRange<Double>
  /// The slider's snap; nil for an amount from 0 to 1 shown in whole percents.
  let step: Double?
  let digits: Int
  let help: String

  // The path and help go with the title in a row's place, so they aren't compared.
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.value == rhs.value && lhs.title == rhs.title && lhs.range == rhs.range && lhs.step == rhs.step && lhs.digits == rhs.digits
  }

  var body: some View {
    let _ = EditViewCounts.note("EditSliderRow")
    let value = value, path = path, range = range, edit = edit
    if let step {
      EditInspector.sliderRow(title, help: help) {
        EditSlider(title: title, value: min(max(value, range.lowerBound), range.upperBound), range: range) {
          edit.options[keyPath: path] = EditOptions.snap($0, step: step)
        }
      } value: {
        TextField("", value: Binding(get: { value }, set: { edit.options[keyPath: path] = $0 }), format: .number.precision(.fractionLength(0...digits)))
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .accessibilityLabel(title)
      }
    } else {
      EditInspector.sliderRow(title, help: help) {
        EditSlider(title: title, value: value, range: 0...1) { edit.options[keyPath: path] = EditOptions.snap($0, 0...1) }
      } value: {
        Text("\(Int((value * 100).rounded()))%")
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }
}

/// The inspector's slider: a `Slider` that says while it's being dragged (`EditModel.isAdjusting`)
/// and marks its changes as not final (`EditModel.sliderChange`), so the preview knows when its
/// value is final.
private struct EditSlider: View {
  @Environment(EditModel.self) private var edit
  let title: String
  /// The value shown, and what a move sets: a value and a setter rather than a binding, so the
  /// slider is worked out only when its row is (its value changed).
  let value: Double
  let range: ClosedRange<Double>
  let set: (Double) -> Void
  @State private var dragging = false

  var body: some View {
    let _ = EditViewCounts.note("EditSlider")
    let value = value, set = set, edit = edit
    Slider(value: Binding(get: { value }, set: { new in edit.sliderChange { set(new) } }), in: range) { Text(title) } onEditingChanged: { editing in
      guard editing != dragging else { return }
      dragging = editing
      edit.adjusting(editing)
    }
    // Gone mid-drag (its section disabled, the screen left), it won't say it was let go.
    .onDisappear {
      if dragging {
        dragging = false
        edit.adjusting(false)
      }
    }
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
