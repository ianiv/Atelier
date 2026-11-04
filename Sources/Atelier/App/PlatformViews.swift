import SwiftUI

// SwiftUI modifiers that exist on the Mac only, with what an iPad does in their place.

extension View {
  /// The Delete key on the Mac; on iPad, deleting goes through the context menu.
  func deleteCommand(perform action: @escaping () -> Void) -> some View {
    #if os(macOS)
      onDeleteCommand(perform: action)
    #else
      self
    #endif
  }

  /// A checkbox on the Mac, a switch on iPad, kept at its own size so its label doesn't wrap.
  func checkboxToggleStyle() -> some View {
    #if os(macOS)
      toggleStyle(.checkbox)
    #else
      fixedSize()
    #endif
  }

  /// Whether Option is held, on the Mac. iPad has no Option key to hold while tapping.
  func onOptionKeyChanged(_ action: @escaping (Bool) -> Void) -> some View {
    #if os(macOS)
      onModifierKeysChanged(mask: .option) { _, keys in action(keys.contains(.option)) }
    #else
      self
    #endif
  }

  /// A menu drawn as plain text on the Mac; iPad's default menu button is already borderless.
  func borderlessMenuStyle() -> some View {
    #if os(macOS)
      menuStyle(.borderlessButton)
    #else
      self
    #endif
  }

  /// Several buttons in one Form row. On iPad a Form row is one big tap target, so plain buttons
  /// would all fire from a tap anywhere in it; borderless ones each keep their own.
  func formRowButtons() -> some View {
    #if os(macOS)
      self
    #else
      buttonStyle(.borderless)
    #endif
  }

  /// On iPad, a hit area of at least 44 points around a small control, without making it look
  /// bigger; the Mac's pointer needs no more than the control.
  func touchTarget() -> some View {
    #if os(macOS)
      self
    #else
      frame(minWidth: 28, minHeight: 28).contentShape(.rect.inset(by: -8))
    #endif
  }

  /// A segmented control or menu in the toolbar at its own width. iPadOS would otherwise stretch it
  /// to take the bar's spare room.
  func toolbarNaturalWidth() -> some View {
    #if os(macOS)
      self
    #else
      fixedSize()
    #endif
  }

  /// A small segmented control on the Mac; on iPad the large size, which a finger can hit.
  func compactPickerSize() -> some View {
    #if os(macOS)
      controlSize(.small)
    #else
      controlSize(.large)
    #endif
  }

  /// A sheet's margins. An iPad sheet's corners are much rounder, and would crowd the buttons in its
  /// corner at the Mac's margins.
  func sheetPadding() -> some View {
    #if os(macOS)
      padding(20)
    #else
      padding(28)
    #endif
  }

  /// The margins of a footer along a sheet's bottom edge, as `sheetPadding` for the whole sheet.
  func sheetFooterPadding() -> some View {
    #if os(macOS)
      padding()
    #else
      padding(.horizontal, 28).padding(.vertical, 20)
    #endif
  }

  /// A sheet's size: fixed on the Mac. On iPad it's the size the sheet asks for, fitted to the
  /// content, and a narrow window can make it smaller.
  func sheetFrame(width: CGFloat, height: CGFloat? = nil) -> some View {
    #if os(macOS)
      frame(width: width, height: height)
    #else
      frame(idealWidth: width, maxWidth: .infinity, idealHeight: height)
        .presentationSizing(.fitted)
    #endif
  }

  /// A Settings path field's width: wide on the Mac; on iPad it takes what the row leaves, since
  /// a narrow window has no room for a fixed width.
  func settingsFieldWidth() -> some View {
    #if os(macOS)
      frame(minWidth: 320)
    #else
      self
    #endif
  }

  /// A link-styled button on the Mac; on iPad, a borderless button, which is drawn in the tint.
  func linkButtonStyle() -> some View {
    #if os(macOS)
      buttonStyle(.link)
    #else
      buttonStyle(.borderless)
    #endif
  }

  /// The up-down resize pointer on the Mac; iPad's pointer has no resize shapes.
  func rowResizePointer() -> some View {
    #if os(macOS)
      pointerStyle(.rowResize)
    #else
      self
    #endif
  }
}

extension View {
  /// A screen's detail pane, beside its list. Always shown on the Mac and in wide iPad windows;
  /// in a narrower iPad window it opens when you pick something (over the list, or as a sheet in
  /// compact width), and closing it clears the selection.
  func detailInspector<Selection: Equatable, Detail: View>(
    selection: Selection, isEmpty: Bool, clearSelection: @escaping () -> Void,
    @ViewBuilder detail: () -> Detail
  ) -> some View {
    modifier(
      DetailInspector(
        selection: selection, isEmpty: isEmpty, clearSelection: clearSelection, detail: detail()))
  }
}

private struct DetailInspector<Selection: Equatable, Detail: View>: ViewModifier {
  let selection: Selection
  let isEmpty: Bool
  let clearSelection: () -> Void
  let detail: Detail
  #if os(iOS)
    @State private var wide = true
    @State private var opened = false
  #endif

  func body(content: Content) -> some View {
    #if os(macOS)
      content.inspector(isPresented: .constant(true)) { detail }
    #else
      content
        .inspector(
          isPresented: Binding(
            get: { wide || opened },
            set: { shown in
              guard !wide else { return }
              opened = shown
              if !shown { clearSelection() }
            })
        ) { detail }
        // Measured outside the inspector, so showing it doesn't change the answer.
        .onGeometryChange(for: Bool.self) { $0.size.width >= iPadInspectorMinimumWidth } action: {
          wide = $0
          opened = false
        }
        // Picking something opens it; a selection already there when the screen appears doesn't.
        .onChange(of: selection) { opened = !isEmpty }
    #endif
  }
}

extension View {
  /// Exposes something that only responds to a tap as one button to VoiceOver and Full Keyboard
  /// Access, leaving how it looks alone. For views with no controls of their own inside.
  func accessibleButton(
    _ label: String, value: String? = nil, isSelected: Bool = false, action: @escaping () -> Void
  ) -> some View {
    accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityValue(value ?? "")
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction { action() }
  }
}

extension ToolbarContent {
  /// For a segmented control in the toolbar. On iPad it has its own capsule, and the bar's shared one
  /// would draw a second outline around it. On the Mac the shared one is the only one.
  func segmentedToolbarItem() -> some ToolbarContent {
    #if os(macOS)
      self
    #else
      sharedBackgroundVisibility(.hidden)
    #endif
  }
}

/// A picker in the toolbar as a menu titled with its current choice. A menu takes the toolbar's own
/// padding; on the Mac a picker there sits its label almost against the capsule's edge. A fixed
/// width, so the toolbar doesn't shift as the choice changes; a longer title is truncated.
struct ToolbarPickerMenu<Picker: View>: View {
  let title: String
  let width: CGFloat
  @ViewBuilder var picker: Picker

  var body: some View {
    Menu {
      picker.pickerStyle(.inline).labelsHidden()
    } label: {
      Text(title)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: width, alignment: .leading)
        .padding(.leading, 6)
    }
  }
}

/// A row of buttons in a detail pane's Form. On iPad, where buttons take more room, they go one
/// per line when the row doesn't fit; the Mac keeps the row.
struct ButtonRow<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    #if os(macOS)
      HStack { content }
    #else
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) { content }.fixedSize()
        VStack(alignment: .leading, spacing: 12) { content }
      }
      // In a Form row, plain buttons would all fire from one tap anywhere in the row.
      .buttonStyle(.borderless)
    #endif
  }
}

/// Which side an inspector popover opens toward: away from the Mac's inspector, on its leading
/// side; on iPad, wherever iPadOS finds room.
let inspectorPopoverEdge: Edge? = {
  #if os(macOS)
    .leading
  #else
    nil
  #endif
}()

#if os(iOS)
  /// The narrowest iPad window area that fits a screen beside its inspector; narrower, the
  /// inspector would cover the screen.
  nonisolated let iPadInspectorMinimumWidth: CGFloat = 800
#endif

#if !(os(iOS) && DEBUG)
  /// The window's content as it is; iPad debug builds can draw it at a set size instead
  /// (iPadPlatform.swift).
  struct LayoutCheckFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View { content }
  }
#endif
