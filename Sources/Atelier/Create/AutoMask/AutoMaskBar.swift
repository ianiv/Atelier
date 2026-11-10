import SwiftUI

/// The Select tool's controls, over the bottom of the canvas while Select is the tool: Select
/// Subject (Vision, nothing to download), SAM 2.1's size and download, a text prompt (not
/// available yet), then Add / Subtract / Replace to put the preview into the mask, and Clear
/// Points. Every control stays; ones that can't act are disabled.
struct AutoMaskBar: View {
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager
  private var download = SAMDownload.shared
  @State private var text = ""

  var body: some View {
    VStack(spacing: 4) {
      // One row when the canvas is wide enough, else two (an iPad in portrait, a narrow window).
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          selecting
          Divider().frame(height: 18)
          committing
        }
        VStack(spacing: 6) {
          HStack(spacing: 8) { selecting }
          HStack(spacing: 8) { committing }
        }
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .fixedSize()
      if let failure = model.autoMask.failure ?? download.failure {
        Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
      }
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
    .help(Self.gestureHelp)
    .onAppear { download.refresh() }
  }

  /// Select Subject, SAM's size and download, the iPad's include/exclude choice.
  @ViewBuilder private var selecting: some View {
    @Bindable var session = model.autoMask
    let paints = model.canPaintMask
    let installed = download.isInstalled(session.size)
    let downloading = download.size
    Button("Select Subject", systemImage: "person.crop.rectangle") {
      model.autoMask.selectSubject(model: model)
    }
    .help("Selects the image's main subjects, with Apple's subject detection. Nothing to download.")
    .disabled(!paints || session.isBusy)
    Divider().frame(height: 18)
    Menu {
      Picker("SAM 2.1 Size", selection: $session.size) {
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
      .disabled(installed)
      .help("Downloads SAM 2.1 \(session.size.title) into \(SAMFiles.folderName) in the models folder, from Hugging Face. Clicking and dragging a box to select need it.")
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
      .disabled(!paints || !installed)
    #endif
  }

  /// The text prompt (not available yet), Add / Subtract / Replace and Clear Points.
  @ViewBuilder private var committing: some View {
    let session = model.autoMask
    let paints = model.canPaintMask
    let hasPreview = session.preview != nil
    TextField("Select:", text: $text, prompt: Text("Select: describe it"))
      .textFieldStyle(.roundedBorder)
      .frame(width: 150)
      .disabled(true)
      .help("Selecting by description isn't available yet.")
    ProgressView().controlSize(.small).opacity(session.isBusy ? 1 : 0)
    ForEach(AutoMaskMode.allCases, id: \.self) { mode in
      Button(mode.title) {
        model.commitAutoMaskPreview(mode: mode, undoManager: undoManager)
      }
      .disabled(!hasPreview || session.isBusy || (mode == .subtract ? model.canvasMask == nil : !paints))
      .help(Self.help(mode))
    }
    Button("Clear Points", systemImage: "xmark.circle") {
      model.autoMask.clearPoints()
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

  private static var gestureHelp: String {
    #if os(iOS)
      "Tap to mark what to select (or what to leave out, with − chosen); drag a box with Apple Pencil. Fingers move and zoom."
    #else
      "Click to mark what to select, Option-click what to leave out, or drag a box. Hold Space to drag the image."
    #endif
  }

  private static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}
