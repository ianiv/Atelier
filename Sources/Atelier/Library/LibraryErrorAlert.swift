import SwiftUI

extension View {
  /// Shows ModelLibrary's error message as an alert.
  func libraryErrorAlert() -> some View {
    modifier(LibraryErrorAlert())
  }
}

private struct LibraryErrorAlert: ViewModifier {
  @Environment(ModelLibrary.self) private var library

  func body(content: Content) -> some View {
    content.alert(
      "Something went wrong",
      isPresented: Binding(
        get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } }),
      actions: { Button("OK") { library.errorMessage = nil } },
      message: { Text(library.errorMessage ?? "") })
  }
}
