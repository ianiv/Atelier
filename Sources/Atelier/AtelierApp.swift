import SwiftUI

@main
struct AtelierApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @State private var create = CreateModel()

  var body: some Scene {
    WindowGroup("Atelier") {
      ContentView()
        .environment(create)
        .frame(minWidth: 960, minHeight: 640)
        .task { Automation.runIfRequested(create) }
    }
    Settings {
      SettingsView()
        .environment(create)
    }
  }
}

/// A bare SwiftPM executable starts as a background process; make it a regular foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
