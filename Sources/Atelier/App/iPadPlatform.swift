#if os(iOS)
import SwiftUI
import UIKit
import os
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

  /// Bytes Atelier can still allocate before iPadOS ends it (raised by the increased memory
  /// limit entitlement).
  static var availableMemory: Int64 {
    Int64(os_proc_available_memory())
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
#endif
