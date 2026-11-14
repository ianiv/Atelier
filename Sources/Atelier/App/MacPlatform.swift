#if os(macOS)
import AppKit
import SwiftUI

// Every AppKit use in Atelier lives in this file: the few things SwiftUI has no equivalent for
// that keeps the Mac app working as it does. Everything else is SwiftUI or a cross-platform
// framework.

/// AppKit's system colors that SwiftUI has no name for.
extension Color {
  static let underPageBackground = Color(nsColor: .underPageBackgroundColor)
  static let textBackground = Color(nsColor: .textBackgroundColor)
  static let quaternaryLabel = Color(nsColor: .quaternaryLabelColor)
  static let separator = Color(nsColor: .separatorColor)
}

/// Quits when the last window closes. A single `Window` scene would do that in SwiftUI, but it
/// drops File ▸ New Window, which the `WindowGroup` offers.
///
/// Also asks before quitting while work is under way (`AppLifecycle.workUnderway`). SwiftUI has no
/// hook for a quit about to happen, and its alerts need a window, which is already gone when
/// closing the last one is what quits; so this asks with an app-wide `NSAlert`.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
    guard !AppLifecycle.isQuittingWithoutAsking, let work = AppLifecycle.workUnderway?() else {
      return .terminateNow
    }
    let alert = NSAlert()
    alert.messageText = "Quit while Atelier is working?"
    alert.informativeText =
      "\(work) Quitting stops it. Queued generations come back paused next time you open Atelier; exports don't."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
  }
}

/// The general clipboard. SwiftUI's copy and paste act on the focused view (`.copyable`,
/// `.pasteDestination`) or need a control of their own (`PasteButton`); Atelier copies and pastes
/// from menu items and buttons.
@MainActor
enum Clipboard {
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  static var string: String? {
    NSPasteboard.general.string(forType: .string)
  }

  /// One image, as PNG and TIFF, which other apps paste most reliably.
  static func copyImage(png: Data?, tiff: Data?) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if let png { pasteboard.setData(png, forType: .png) }
    if let tiff { pasteboard.setData(tiff, forType: .tiff) }
  }

  /// Several images, one clipboard item each.
  static func copyImages(_ images: [(png: Data?, tiff: Data?)]) {
    let entries = images.map { image in
      let entry = NSPasteboardItem()
      if let png = image.png { entry.setData(png, forType: .png) }
      if let tiff = image.tiff { entry.setData(tiff, forType: .tiff) }
      return entry
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(entries)
  }

  /// A copied image's PNG or TIFF data.
  static var imageData: Data? {
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
      if let data = NSPasteboard.general.data(forType: type) { return data }
    }
    return nil
  }

  /// A copied file's URL, such as an image copied in Finder.
  static var fileURL: URL? {
    (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
  }
}

/// App activation and quitting. SwiftUI's `scenePhase` follows windows, not the app: it doesn't
/// change when another app comes to the front, and has no "about to quit".
@MainActor
enum AppLifecycle {
  static var isActive: Bool { NSApp.isActive }

  /// What quitting now would stop, in a sentence, or nil to quit without asking.
  static var workUnderway: (@MainActor () -> String?)?

  private static var observations: [any NSObjectProtocol] = []

  /// The block-based observer rather than `addObserver(of:for:)`, whose NSApplication messages need
  /// macOS 27. A nil queue runs it as the notification posts, and NSApplication posts these on the
  /// main thread, so will-terminate work finishes before the app exits.
  private static func observe(_ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
    observations.append(
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
        MainActor.assumeIsolated { action() }
      })
  }

  /// Runs before the app exits, delivered on the main actor as it posts, unlike anything that hops
  /// to a task: this is what saves the session and the queue.
  static func onWillTerminate(_ action: @escaping @MainActor () -> Void) {
    observe(NSApplication.willTerminateNotification, action)
  }

  static func onResignActive(_ action: @escaping @MainActor () -> Void) {
    observe(NSApplication.didResignActiveNotification, action)
  }

  static func onBecomeActive(_ action: @escaping @MainActor () -> Void) {
    observe(NSApplication.didBecomeActiveNotification, action)
  }

  /// A drive was connected or ejected (folders on it come and go).
  static func onVolumesChanged(_ action: @escaping @MainActor () -> Void) {
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      observations.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { action() }
        })
    }
  }

  /// Set by `quit()`, which scripted runs call, so they don't stop to ask.
  fileprivate static var isQuittingWithoutAsking = false

  /// Quits normally, so will-terminate work (saving the session and queue) still runs, without
  /// asking about work under way.
  static func quit() {
    isQuittingWithoutAsking = true
    NSApp.terminate(nil)
  }

  /// Hides the app, then shows it again, for `--cleanup-check`. True when it was at the front.
  static func hideAndShowForCheck() async -> Bool {
    NSApp.activate()
    try? await Task.sleep(for: .seconds(1))
    guard NSApp.isActive else { return false }
    NSApp.hide(nil)
    try? await Task.sleep(for: .seconds(1))
    NSApp.unhide(nil)
    NSApp.activate()
    try? await Task.sleep(for: .seconds(1))
    return true
  }
}

/// The screen, which SwiftUI doesn't describe to a view on the Mac.
@MainActor
enum ScreenSpace {
  /// The room on the screen the app's front window is on, the menu bar and Dock aside, for
  /// fitting a sheet that opens at a remembered size; nil with no screen.
  static var visibleSize: CGSize? {
    ((NSApp.keyWindow ?? NSApp.mainWindow)?.screen ?? NSScreen.main)?.visibleFrame.size
  }
}

/// Reports the size of the view it's behind each time the person finishes dragging its window
/// (a sheet) to a new size. SwiftUI can say a view's size changed, but not why, and a sheet's
/// size also changes when it opens and when the system fits it to a screen; only AppKit's live
/// resize, which is a drag by hand and nothing else, says the size is one the person chose.
struct SheetResizeObserver: NSViewRepresentable {
  let onResize: @MainActor (CGSize) -> Void

  func makeNSView(context _: Context) -> Probe { Probe(onResize: onResize) }
  func updateNSView(_ view: Probe, context _: Context) { view.onResize = onResize }

  final class Probe: NSView {
    var onResize: @MainActor (CGSize) -> Void
    private var observation: (any NSObjectProtocol)?

    init(onResize: @escaping @MainActor (CGSize) -> Void) {
      self.onResize = onResize
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    /// Follows the window it's in, and stops when it leaves it (the sheet closed).
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observation { NotificationCenter.default.removeObserver(observation) }
      observation = nil
      guard let window else { return }
      // A nil queue runs it as the notification posts, which AppKit does on the main thread.
      observation = NotificationCenter.default.addObserver(
        forName: NSWindow.didEndLiveResizeNotification, object: window, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.bounds.width > 0, self.bounds.height > 0 else { return }
          self.onResize(self.bounds.size)
        }
      }
    }
  }
}

/// Finder. SwiftUI's `openURL` opens a folder but can't select files in it.
@MainActor
enum Finder {
  static let revealTitle = "Reveal in Finder"
  static let showTitle = "Show in Finder"

  /// Opens Finder windows with these files selected.
  static func reveal(_ urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }
}

/// The windows Automation snapshots and resizes. `ImageRenderer` draws a SwiftUI view but not a
/// window's toolbar, sheets or AppKit-backed controls, and can't host the UI while the screen is
/// locked and SwiftUI puts no window up.
@MainActor
enum AutomationWindows {
  /// Hosts the content off screen; it has no toolbar.
  private static var offscreenWindow: NSWindow?

  private static var visibleWindow: NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.contentView != nil }
  }

  /// Puts the content in an off-screen window when no window is visible (the screen is locked),
  /// so snapshots still show the UI.
  static func ensureWindow(_ content: () -> some View, size: CGSize) {
    guard !NSApp.windows.contains(where: \.isVisible), offscreenWindow == nil else { return }
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: content())
    offscreenWindow = window
  }

  /// Renders the main window, toolbar included, into a PNG; needs no screen-recording permission.
  static func snapshot(to url: URL) {
    guard let view = (visibleWindow ?? offscreenWindow)?.contentView?.superview else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? png(of: view)?.write(to: url)
  }

  static var mainWindowNumber: Int { visibleWindow?.windowNumber ?? 0 }

  /// The Settings window's number, for `screencapture -l`.
  static var otherWindowNumber: Int {
    NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.canBecomeKey && $0.title != "Atelier" }?.windowNumber ?? 0
  }

  /// The number of the window showing a sheet (a sheet is captured with its window).
  static var sheetWindowNumber: Int {
    NSApp.windows.first { $0.isSheet && $0.isVisible }?.windowNumber ?? 0
  }

  /// The size of the sheet on screen, or nil when there's none.
  static var sheetSize: CGSize? { NSApp.windows.first { $0.isSheet && $0.isVisible }?.frame.size }

  static var isSheetUp: Bool { NSApp.windows.contains { $0.isSheet && $0.isVisible } }

  /// How many windows are up, sheets aside.
  static var windowCount: Int { NSApp.windows.filter { $0.isVisible && !$0.isSheet && $0.canBecomeKey }.count }

  /// Renders the visible window that isn't the main one (Settings) into a PNG; false when there's
  /// none.
  static func snapshotOtherWindow(to url: URL) -> Bool {
    guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.canBecomeKey && $0.title != "Atelier" }),
      let view = window.contentView?.superview ?? window.contentView, let png = png(of: view)
    else { return false }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? png.write(to: url)
    return true
  }

  /// Renders `content` in a window of its own, off screen, into a PNG (for views shown as sheets
  /// that Automation can't present, such as Upscale Video). False when it can't.
  static func snapshot(_ content: some View, size: CGSize, to url: URL) -> Bool {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    // Swift owns it; AppKit releasing it on close as well would free it twice.
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: content)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    defer { window.close() }
    guard let view = window.contentView?.superview ?? window.contentView, let png = png(of: view) else { return false }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (try? png.write(to: url)) != nil
  }

  /// Renders the sheet on screen into a PNG; false when there's none.
  static func snapshotSheet(to url: URL) -> Bool {
    guard let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }),
      // The frame view, for the sheet's background: light text on no background doesn't show.
      let view = sheet.contentView?.superview ?? sheet.contentView, let png = png(of: view)
    else { return false }
    try? png.write(to: url)
    return true
  }

  /// Resizes the visible window back and forth, laying out and drawing each frame. Returns the
  /// average and worst seconds per frame, or nil with no visible window.
  static func resizeBench(frames: Int) -> (average: Double, worst: Double)? {
    guard let window = visibleWindow else { return nil }
    let origin = window.frame.origin
    let start = Date()
    var worst = 0.0
    for frame in 0..<frames {
      let t = Date()
      let width = 1100 + 500 * abs(sin(Double(frame) / 15))
      window.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: 860), display: true)
      window.contentView?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      worst = max(worst, Date().timeIntervalSince(t))
    }
    return (Date().timeIntervalSince(start) / Double(frames), worst)
  }

  private static func png(of view: NSView) -> Data? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }
}
#endif
