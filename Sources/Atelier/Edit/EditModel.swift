import SwiftUI

/// The Edit screen's state, owned by `AtelierApp` and handed down with `.environment`, as the
/// Video Editor's `TimelineStore` is: the image being edited, its look, and what the look is
/// rendered with. Slice G adds the source, its own canvas, the loaded profile and reference, and
/// the preview cache.
@Observable final class EditModel {
  /// The look being edited.
  var options = EditOptions()
  /// What it's rendered with: the loaded profile's data, the reference's measurements, the LUT.
  var context = EditPipeline.Context.empty

  init() {}
}
