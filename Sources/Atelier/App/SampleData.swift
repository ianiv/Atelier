import SwiftUI

#if DEBUG
  import CoreGraphics
  import Foundation

  /// Sample images for checking layouts (Scripts/ipad-layout-shots.sh), in Debug builds only.
  /// Launched with `--project NAME -AtelierSampleData YES`, an empty project NAME gets a dozen
  /// generated pictures with prompts, sizes and a branch, so History has something to lay out.
  /// `--project` keeps them out of the user's own projects.
  extension HistoryStore {
    func addSampleImagesIfAsked() async {
      guard UserDefaults.standard.bool(forKey: "AtelierSampleData"), items.isEmpty,
        CommandLine.arguments.contains("--project")
      else { return }
      let prompts = [
        "a lighthouse at dusk, watercolor", "a red fox in fresh snow, telephoto",
        "isometric cozy reading nook with plants", "neon city street in the rain at night",
        "portrait of an old fisherman, dramatic light", "a bowl of ramen, top-down food photo",
        "misty pine forest at sunrise", "retro poster of a rocket launch",
        "a glass terrarium with tiny mushrooms", "desert canyon under the milky way",
        "a cat wearing a knitted scarf", "art deco hotel lobby, symmetrical",
      ]
      let sizes = [(512, 512), (768, 512), (512, 768), (640, 640)]
      var previous: Int64?
      for (index, prompt) in prompts.enumerated() {
        let (width, height) = sizes[index % sizes.count]
        guard let image = Self.sampleImage(width: width, height: height, seed: index),
          let tensor = ImageTensor.tensor(from: image)
        else { continue }
        // The last three branch off the fourth image.
        let parent = index >= 9 ? items.dropFirst(index - 4).first?.tensorId : previous
        let item = try? await project.append(
          tensor: tensor, model: "sd_xl_base_1.0_f16.ckpt", prompt: prompt,
          negativePrompt: index.isMultiple(of: 3) ? "blurry, low quality" : "",
          seed: UInt32(1000 + index * 7919),
          settings: [
            "width": .number(Double(width)), "height": .number(Double(height)),
            "steps": .number(20), "guidanceScale": .number(5), "shift": .number(1),
          ],
          createdAt: Date(timeIntervalSinceNow: Double(index - prompts.count) * 600),
          duration: Double(12 + index), after: parent)
        previous = item?.tensorId
        await reload()
      }
    }

    /// A soft two-colour gradient with a few circles, different for each seed.
    static func sampleImage(width: Int, height: Int, seed: Int) -> CGImage? {
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return nil }
      func hue(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
        let h6 = (h.truncatingRemainder(dividingBy: 1)) * 6
        let c = b * s, x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1)), m = b - c
        let (r, g, bl): (Double, Double, Double) =
          switch Int(h6) {
          case 0: (c, x, 0)
          case 1: (x, c, 0)
          case 2: (0, c, x)
          case 3: (0, x, c)
          case 4: (x, 0, c)
          default: (c, 0, x)
          }
        return CGColor(srgbRed: r + m, green: g + m, blue: bl + m, alpha: 1)
      }
      let base = Double(seed) * 0.137
      let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [hue(base, 0.55, 0.95), hue(base + 0.3, 0.7, 0.45)] as CFArray, locations: [0, 1])!
      context.drawLinearGradient(
        gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
      for circle in 0..<5 {
        let t = Double(seed * 5 + circle)
        let radius = Double(min(width, height)) * (0.08 + 0.05 * Double(circle % 3))
        let center = CGPoint(
          x: Double(width) * (0.5 + 0.4 * sin(t * 1.7)), y: Double(height) * (0.5 + 0.4 * cos(t * 1.3)))
        context.setFillColor(hue(base + 0.5 + Double(circle) * 0.08, 0.6, 1).copy(alpha: 0.75)!)
        context.fillEllipse(
          in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
      }
      return context.makeImage()
    }
  }

  /// Opens a sheet or popover at launch for layout checks: `-AtelierShow NAME` presents the one
  /// registered under NAME, once the screen has settled.
  struct DebugPresent: ViewModifier {
    let name: String
    @Binding var isPresented: Bool
    var prepare: () -> Void = {}

    func body(content: Content) -> some View {
      content.task {
        guard UserDefaults.standard.string(forKey: "AtelierShow") == name else { return }
        prepare()
        try? await Task.sleep(for: .seconds(1.5))
        isPresented = true
      }
    }
  }
#endif

extension View {
  /// In Debug builds, `-AtelierShow NAME` opens this sheet or popover at launch (SampleData.swift);
  /// `prepare` sets up what it shows first.
  func debugPresents(_ name: String, _ isPresented: Binding<Bool>, prepare: @escaping () -> Void = {})
    -> some View
  {
    #if DEBUG
      modifier(DebugPresent(name: name, isPresented: isPresented, prepare: prepare))
    #else
      self
    #endif
  }
}
