// swift-tools-version:5.9
import Foundation
import PackageDescription

// The Command Line Tools toolchain ships no SwiftUI macro plugin, and in the macOS 27 SDK
// `@State` is a macro. Borrow Xcode's plugin (same compiler build) when it's installed.
let swiftUIPluginPath =
  "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
let swiftUIPluginFlags: [SwiftSetting] =
  FileManager.default.fileExists(atPath: swiftUIPluginPath + "/libSwiftUIMacros.dylib")
  ? [.unsafeFlags(["-plugin-path", swiftUIPluginPath])] : []

let package = Package(
  name: "Atelier",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Atelier", targets: ["Atelier"])
  ],
  dependencies: [
    // Official engine repo, pinned. Bump deliberately to pick up new models.
    .package(
      url: "https://github.com/drawthingsai/draw-things-community",
      revision: "8dbbb5c69b83c6312eb10622611d46a943de6f88")
  ],
  targets: [
    .executableTarget(
      name: "Atelier",
      dependencies: [
        .product(name: "_MediaGenerationKit", package: "draw-things-community")
      ],
      path: "Sources/Atelier",
      swiftSettings: swiftUIPluginFlags
    )
  ]
)
