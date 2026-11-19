import SwiftUI

/// The Edit screen (sidebar "Edit"): grain and colour grading of one image, previewed live and
/// saved to History as a new step after it (Slice G fills it).
struct EditScreen: View {
  @Environment(EditModel.self) private var edit

  var body: some View {
    ContentUnavailableView("Edit", systemImage: Edit.symbol, description: Text("Grain and colour grading."))
  }
}
