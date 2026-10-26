#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The iPad side of MacPlatform.swift: every UIKit use in Atelier lives in this file, with the same
// API as the Mac's.

/// UIKit's counterparts of the Mac's system colors in MacPlatform.swift.
extension Color {
  static let underPageBackground = Color(uiColor: .systemGroupedBackground)
  static let textBackground = Color(uiColor: .systemBackground)
  static let quaternaryLabel = Color(uiColor: .quaternaryLabel)
  static let separator = Color(uiColor: .separator)
}

/// The general clipboard, as on the Mac. iPadOS asks "Allow Paste?" when Atelier reads it from its
/// own menu items and buttons (Paste Settings, Paste Image), unless Settings ▸ Apps ▸ Atelier
/// allows pasting from other apps; copying never asks.
@MainActor
enum Clipboard {
  static func copy(_ text: String) {
    UIPasteboard.general.string = text
  }

  static var string: String? {
    UIPasteboard.general.string
  }

  /// One image, as PNG and TIFF, which other apps paste most reliably.
  static func copyImage(png: Data?, tiff: Data?) {
    copyImages([(png, tiff)])
  }

  /// Several images, one clipboard item each.
  static func copyImages(_ images: [(png: Data?, tiff: Data?)]) {
    UIPasteboard.general.items = images.map { image in
      var item: [String: Any] = [:]
      if let png = image.png { item[UTType.png.identifier] = png }
      if let tiff = image.tiff { item[UTType.tiff.identifier] = tiff }
      return item
    }
  }

  /// A copied image's data. Photos and Safari copy JPEG and HEIC as well as PNG and TIFF.
  static var imageData: Data? {
    for type in [UTType.png, .tiff, .jpeg, .heic] {
      if let data = UIPasteboard.general.data(forPasteboardType: type.identifier) { return data }
    }
    return nil
  }

  /// A copied file's URL, such as an image copied in Files.
  static var fileURL: URL? {
    UIPasteboard.general.url
  }
}

/// App activation, as on the Mac. iPadOS has no quitting: an app moves to the background and may
/// be ended there, so resigning active is the moment to save.
@MainActor
enum AppLifecycle {
  static var isActive: Bool { UIApplication.shared.applicationState == .active }

  static func onWillTerminate(_ action: @escaping @MainActor () -> Void) {
    observe(UIApplication.willTerminateNotification, action)
  }

  static func onResignActive(_ action: @escaping @MainActor () -> Void) {
    observe(UIApplication.willResignActiveNotification, action)
  }

  static func onBecomeActive(_ action: @escaping @MainActor () -> Void) {
    observe(UIApplication.didBecomeActiveNotification, action)
  }

  static func onEnterBackground(_ action: @escaping @MainActor () -> Void) {
    observe(UIApplication.didEnterBackgroundNotification, action)
  }

  static func onEnterForeground(_ action: @escaping @MainActor () -> Void) {
    observe(UIApplication.willEnterForegroundNotification, action)
  }

  /// Keeps the screen from dimming and locking, for while an image is being made.
  static func keepScreenAwake(_ awake: Bool) {
    UIApplication.shared.isIdleTimerDisabled = awake
  }

  private static func observe(_ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { action() }
    }
  }
}

/// The Files app, in place of Finder. It opens a folder but can't select files in it, so this shows
/// the folder holding the first file.
@MainActor
enum Finder {
  static let revealTitle = "Show in Files"
  static let showTitle = "Show in Files"

  static func reveal(_ urls: [URL]) {
    guard let url = urls.first else { return }
    let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    let folder = isFolder ? url : url.deletingLastPathComponent()
    // Files opens a local folder from its path with the shareddocuments scheme.
    var components = URLComponents()
    components.scheme = "shareddocuments"
    components.path = folder.path
    if let files = components.url { UIApplication.shared.open(files) }
  }
}
#if DEBUG
  /// For checking layouts at window sizes the simulator can't be dragged to (it has no way to
  /// resize an app's window from a script). Launched with `-AtelierWindowSize 600x800`, the app
  /// draws in a window of its own that size at the top left of the screen, scaled down to fit when
  /// it's larger, with the horizontal size class iPadOS gives a window that wide. Sheets and
  /// popovers present inside it, as in a real window that size.
  struct LayoutCheckFrame<Content: View>: View {
    @ViewBuilder var content: Content

    static var size: CGSize? {
      guard let text = UserDefaults.standard.string(forKey: "AtelierWindowSize") else { return nil }
      let sides = text.split(separator: "x").compactMap { Double($0) }
      return sides.count == 2 ? CGSize(width: sides[0], height: sides[1]) : nil
    }

    var body: some View {
      if let size = Self.size {
        Color.gray.ignoresSafeArea()
          .background(SizedWindow(size: size, content: content))
      } else {
        content
      }
    }
  }

  /// Puts the content in a second window of the scene, sized and placed by hand.
  private struct SizedWindow<Content: View>: UIViewRepresentable {
    let size: CGSize
    let content: Content

    func makeUIView(context: Context) -> Anchor { Anchor(size: size, content: content) }
    func updateUIView(_ view: Anchor, context: Context) {}

    final class Anchor: UIView {
      let size: CGSize
      let content: Content
      private var sized: UIWindow?

      init(size: CGSize, content: Content) {
        self.size = size
        self.content = content
        super.init(frame: .zero)
      }

      required init?(coder: NSCoder) { fatalError() }

      override func didMoveToWindow() {
        super.didMoveToWindow()
        guard sized == nil, let scene = window?.windowScene else { return }
        let screen = scene.screen.bounds.size
        let scale = min(1, screen.width / size.width, screen.height / size.height)
        let sized = UIWindow(windowScene: scene)
        // iPadOS makes a window compact below roughly half a 13-inch screen's width.
        sized.traitOverrides.horizontalSizeClass = size.width < 640 ? .compact : .regular
        sized.rootViewController = FixedSizeController(size: size, content: content)
        sized.makeKeyAndVisible()
        self.sized = sized
        // Placed once the window is up: making it key sizes it to the scene.
        place(sized, scale: scale)
        DispatchQueue.main.async { self.place(sized, scale: scale) }
      }

      private func place(_ sized: UIWindow, scale: CGFloat) {
        sized.transform = .identity
        sized.frame = CGRect(origin: .zero, size: size)
        sized.transform = CGAffineTransform(scaleX: scale, y: scale)
        sized.center = CGPoint(x: size.width * scale / 2, y: size.height * scale / 2)
      }
    }
  }

  /// Keeps the hosted content at a fixed size whatever size UIKit gives the root view.
  private final class FixedSizeController<Content: View>: UIViewController {
    let size: CGSize
    let host: UIHostingController<Content>

    init(size: CGSize, content: Content) {
      self.size = size
      host = UIHostingController(rootView: content)
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .gray
      addChild(host)
      view.addSubview(host.view)
      host.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      host.view.frame = CGRect(origin: .zero, size: size)
    }
  }
#endif
#endif
