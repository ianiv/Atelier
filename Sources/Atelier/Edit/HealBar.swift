import SwiftUI

/// The Heal tool's bar, over the bottom of the image: Set Source, a hint that says what the next
/// click or tap does, how many spots there are and Clear Heal. Every control is always there,
/// disabled when it can't act; the hint is one text whose wording changes, never a control that
/// comes and goes. Undo (⌘Z) takes back a stroke, so there's no per-spot button.
struct HealBar: View {
  @Environment(EditModel.self) private var edit
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    @Bindable var edit = edit
    let count = edit.retouch.heal.strokes.count
    ToolBarPanel {
      Toggle(isOn: $edit.isSettingHealSource) {
        Label("Set Source", systemImage: "scope")
      }
      .toggleStyle(.button)
      .disabled(!edit.hasSource)
      .help(Self.setSourceHelp)
      Text(Self.hint(settingSource: edit.isSettingHealSource, hasSource: edit.healSource != nil))
        .foregroundStyle(.secondary)
      // A readout, not a control.
      Text(count == 1 ? "1 spot" : "\(count) spots")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityLabel("Heal spots")
      Button("Clear Heal") { edit.clearHeal(undoManager: undoManager) }
        .disabled(count == 0)
        .help("Take every heal stroke off this image (Undo brings them back)")
    }
  }

  #if os(macOS)
  static let setSourceHelp = "The next click on the image sets where Heal copies from (Option-click does it any time)"
  #else
  static let setSourceHelp = "The next tap on the image sets where Heal copies from"
  #endif

  /// What the next click or tap does: set the source, or paint once there's one to paint from.
  static func hint(settingSource: Bool, hasSource: Bool) -> String {
    #if os(macOS)
    if settingSource { return "Click where to copy from" }
    return hasSource ? "Source set: paint over the mark" : "Option-click or use Set Source to pick where to copy from"
    #else
    if settingSource { return "Tap where to copy from" }
    return hasSource ? "Source set: paint over the mark" : "Tap Set Source, then tap where to copy from"
    #endif
  }
}
