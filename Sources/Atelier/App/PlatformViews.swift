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

  /// The size of a sheet that opens at `idealSize`. The Mac's can be dragged larger or down to the
  /// minimums; an iPad sheet can't be dragged, so it's `sheetFrame` there.
  ///
  /// With `rememberedAs`, the Mac's opens next time at the size it was last dragged to, kept in
  /// the settings under that name (`RememberedSheetSize`). An iPad's has no size of its own to
  /// remember.
  @ViewBuilder
  func resizableSheetFrame(minWidth: CGFloat, minHeight: CGFloat, idealSize: CGSize, rememberedAs key: String? = nil) -> some View {
    #if os(macOS)
      if let key {
        modifier(RememberedSheetSize(key: key, minSize: CGSize(width: minWidth, height: minHeight), idealSize: idealSize))
      } else {
        frame(
          minWidth: minWidth, idealWidth: idealSize.width, maxWidth: .infinity,
          minHeight: minHeight, idealHeight: idealSize.height, maxHeight: .infinity
        )
        .presentationSizing(.fitted)
      }
    #else
      sheetFrame(width: idealSize.width, height: idealSize.height)
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
struct ToolbarPickerMenu<Picker: View, Actions: View>: View {
  let title: String
  let width: CGFloat
  @ViewBuilder var picker: Picker
  /// Commands under the choices.
  @ViewBuilder var actions: Actions

  var body: some View {
    Menu {
      picker.pickerStyle(.inline).labelsHidden()
      actions
    } label: {
      Text(title)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: width, alignment: .leading)
        .padding(.leading, 6)
    }
  }
}

extension ToolbarPickerMenu where Actions == EmptyView {
  init(title: String, width: CGFloat, @ViewBuilder picker: () -> Picker) {
    self.init(title: title, width: width, picker: picker, actions: { EmptyView() })
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

#if os(macOS)
  /// A resizable sheet that opens at the size it was last dragged to, or at `idealSize` until it
  /// has been, made smaller when that no longer fits the screen (a smaller display, or the
  /// laptop's own after a desk's).
  ///
  /// Only a drag is remembered (`SheetResizeObserver` hears the end of one): the size a small
  /// screen brought it down to isn't written back, so the sheet is its remembered size again on
  /// a screen with room for it.
  struct RememberedSheetSize: ViewModifier {
    let minSize: CGSize
    /// 0 until the sheet has been dragged to a size.
    @AppStorage private var width: Double
    @AppStorage private var height: Double
    /// Decided once, as the sheet opens: a sheet takes its size from the ideal then, and one
    /// that changed under it as a drag is remembered could move it again.
    @State private var opening: CGSize

    /// The settings a sheet's size is remembered in, under its name.
    static func widthKey(_ key: String) -> String { "\(key)Width" }
    static func heightKey(_ key: String) -> String { "\(key)Height" }

    /// The room left around a sheet at its largest, in all, each way: enough that its edges
    /// stay clear of the screen's, where they can still be dragged.
    static let screenMargin: CGFloat = 40

    init(key: String, minSize: CGSize, idealSize: CGSize) {
      self.minSize = minSize
      _width = AppStorage(wrappedValue: 0, Self.widthKey(key))
      _height = AppStorage(wrappedValue: 0, Self.heightKey(key))
      let defaults = UserDefaults.standard
      let stored = CGSize(width: defaults.double(forKey: Self.widthKey(key)), height: defaults.double(forKey: Self.heightKey(key)))
      let wanted = stored.width > 0 && stored.height > 0 ? stored : idealSize
      _opening = State(initialValue: Self.fitted(wanted, minSize: minSize, screen: ScreenSpace.visibleSize))
    }

    /// `size` brought within the screen less the margin, and never under the minimum, which
    /// wins on a screen smaller than it. With no screen known, it's only kept to the minimum.
    static func fitted(_ size: CGSize, minSize: CGSize, screen: CGSize?) -> CGSize {
      var size = size
      if let screen {
        size.width = min(size.width, screen.width - screenMargin)
        size.height = min(size.height, screen.height - screenMargin)
      }
      return CGSize(width: max(size.width, minSize.width).rounded(), height: max(size.height, minSize.height).rounded())
    }

    func body(content: Content) -> some View {
      content
        .frame(
          minWidth: minSize.width, idealWidth: opening.width, maxWidth: .infinity,
          minHeight: minSize.height, idealHeight: opening.height, maxHeight: .infinity
        )
        .background {
          SheetResizeObserver { size in
            width = size.width.rounded()
            height = size.height.rounded()
          }
        }
        .presentationSizing(.fitted)
    }
  }
#endif
