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
    .executable(name: "Atelier", targets: ["Atelier"]),
    // For the app target in the Xcode project (project.yml), which compiles Sources/Atelier itself.
    .library(name: "ProjectFormat", targets: ["ProjectFormat"]),
  ],
  dependencies: [
    // Official engine repo, pinned. Bump deliberately to pick up new models.
    .package(
      url: "https://github.com/drawthingsai/draw-things-community",
      revision: "8dbbb5c69b83c6312eb10622611d46a943de6f88"),
    // Same revisions the engine pins, for the Draw Things project format (ProjectFormat).
    .package(url: "https://github.com/liuliu/dflat.git", revision: "73925e51e4f44add842177a229f9990cb13711ff"),
    .package(
      url: "https://github.com/google/flatbuffers.git",
      revision: "c92e78a9f841a6110ec27180d68d1f7f2afda21d"),
  ],
  targets: [
    // dflat models for Draw Things' project tables, generated from the engine's History schemas
    // by Scripts/generate_project_format.sh. Its own module because its enum names (SamplerType,
    // SeedMode, …) clash with DataModels'.
    .target(
      name: "ProjectFormat",
      dependencies: [
        .product(name: "Dflat", package: "dflat"),
        .product(name: "SQLiteDflat", package: "dflat"),
        .product(name: "FlatBuffers", package: "flatbuffers"),
      ],
      path: "Sources/ProjectFormat"
    ),
    .executableTarget(
      name: "Atelier",
      dependencies: [
        "ProjectFormat",
        .product(name: "_MediaGenerationKit", package: "draw-things-community"),
      ],
      path: "Sources/Atelier",
      swiftSettings: swiftUIPluginFlags
    )
  ]
)
