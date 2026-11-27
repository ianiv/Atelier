import SwiftUI

/// The Select tool's controls, over the bottom of the canvas while Select is the tool: Smart |
/// Rectangle | Lasso (what a drag makes), Select Subject (Vision, nothing to download), SAM 2.1's size and download, then Add / Subtract /
/// Replace to put the preview into the mask, Fill to paint it with the paint color, and Clear Points.
/// Every control stays; ones that can't act are disabled.
struct AutoMaskBar: View {
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager
  private var download = SAMDownload.shared

  var body: some View {
    // One row when the canvas is wide enough, else two (an iPad in portrait, a narrow window).
    ToolBarPanel(help: model.autoMask.selectMode.gestureHelp) {
      selecting
    } second: {
      committing
    } footer: {
      if let failure = model.autoMask.failure ?? download.failure {
        Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
      }
    }
    .onAppear { download.refresh() }
  }

  /// Smart | Rectangle | Lasso, Select Subject, SAM's size and download, the iPad's
  /// include/exclude choice.
  @ViewBuilder private var selecting: some View {
    @Bindable var session = model.autoMask
    let paints = model.canPaintMask
    let installed = download.isInstalled(session.size)
    let downloading = download.size
    Picker("Select", selection: $session.selectMode) {
      ForEach(SelectMode.allCases, id: \.self) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .help("What a drag selects: Smart finds the object (SAM 2.1), Rectangle and Lasso select the shape you draw")
    .disabled(!paints)
    Divider().frame(height: 18)
    Button("Select Subject", systemImage: "person.crop.rectangle") {
      model.autoMask.selectSubject(model: model, undoManager: undoManager)
    }
    .help("Selects the image's main subjects, with Apple's subject detection. Nothing to download.")
    .disabled(!paints || session.isBusy)
    Divider().frame(height: 18)
    Menu {
      Picker(
        "SAM 2.1 Size",
        selection: Binding(get: { session.size }, set: { model.autoMask.setSize($0, model: model, undoManager: undoManager) })
      ) {
        ForEach(SAMFiles.Size.allCases, id: \.self) { size in
          Text("\(size.title) (\(Self.bytes(size.bytes)))").tag(size)
        }
      }
      .pickerStyle(.inline)
    } label: {
      Text("SAM \(session.size.title)").touchTarget()
    }
    .menuIndicator(.visible)
    .fixedSize()
    .help("Which SAM 2.1 model clicks and boxes use: Small is the default; Tiny is faster, Large more exact.")
    .disabled(downloading != nil)
    if let downloading {
      ProgressView(value: download.fraction) {
        Text("Downloading SAM \(downloading.title)…").font(.caption)
      }
      .frame(width: 140)
      Button("Cancel") { download.cancel() }
    } else {
      Button(installed ? "Downloaded" : "Download (\(Self.bytes(download.remainingBytes(session.size))))") {
        download.start(session.size)
      }
      .disabled(installed || download.destination == nil)
      .help(Self.downloadHelp(session.size, into: download.destination))
    }
    #if os(iOS)
      // No Option key: this decides what a tap marks.
      Picker("Point", selection: $session.negative) {
        Label("Include", systemImage: "plus.circle").tag(false)
        Label("Exclude", systemImage: "minus.circle").tag(true)
      }
      .pickerStyle(.segmented)
      .labelStyle(.iconOnly)
      .fixedSize()
      .help("What a tap marks: something to include, or to leave out")
      // Rectangle and Lasso make no points.
      .disabled(!paints || !installed || session.selectMode != .smart)
    #endif
  }

  /// Add / Subtract / Replace, Fill and Clear Points.
  @ViewBuilder private var committing: some View {
    let session = model.autoMask
    let paints = model.canPaintMask
    let hasPreview = session.preview != nil
    ProgressView().controlSize(.small).opacity(session.isBusy ? 1 : 0)
    ForEach(AutoMaskMode.allCases, id: \.self) { mode in
      Button(mode.title) {
        model.commitAutoMaskPreview(mode: mode, undoManager: undoManager)
      }
      .disabled(!hasPreview || session.isBusy || (mode == .subtract ? model.canvasMask == nil : !paints))
      .help(Self.help(mode))
    }
    // Into the paint layer instead of the mask.
    Button("Fill") {
      model.fillAutoMaskPreview(undoManager: undoManager)
    }
    .disabled(!hasPreview || session.isBusy || !model.canPaintColor)
    .help("Fill the selection with the paint color (the Color layer's), leaving the mask as it is")
    Button("Clear Points", systemImage: "xmark.circle") {
      model.autoMask.clearPoints(model: model, undoManager: undoManager)
    }
    .labelStyle(.iconOnly)
    .help("Clear Points (Esc)")
    .disabled(!session.hasPrompt && !hasPreview)
  }

  private static func help(_ mode: AutoMaskMode) -> String {
    switch mode {
    case .add: "Add the selection to the mask"
    case .subtract: "Take the selection out of the mask"
    case .replace: "Make the selection the whole mask"
    }
  }

  /// Where the Download button puts SAM, named so it's no surprise.
  private static func downloadHelp(_ size: SAMFiles.Size, into folder: URL?) -> String {
    guard let folder else {
      return "No models folder can take SAM 2.1 now: connect the models folder's drive, or add a folder in Settings ▸ Models."
    }
    return "Downloads SAM 2.1 \(size.title) from Hugging Face into \(SAMFiles.folderName) in \(folder.path). Clicking and dragging a box to select need it."
  }

  private static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}
