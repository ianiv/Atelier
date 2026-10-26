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

  /// A checkbox on the Mac, a switch on iPad.
  func checkboxToggleStyle() -> some View {
    #if os(macOS)
      toggleStyle(.checkbox)
    #else
      self
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
