import Foundation
import _MediaGenerationKit

/// User-facing settings persisted in UserDefaults.
enum AppSettings {
  private static let modelsDirectoryKey = "modelsDirectory"

  /// Models directory: the saved setting, else `DRAWTHINGS_MODELS_DIR`, else ~/Documents/Models
  /// (MGK's own default).
  static var modelsDirectory: String {
    get {
      if let saved = UserDefaults.standard.string(forKey: modelsDirectoryKey), !saved.isEmpty {
        return saved
      }
      if let env = ProcessInfo.processInfo.environment["DRAWTHINGS_MODELS_DIR"], !env.isEmpty {
        return env
      }
      return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Models", isDirectory: true).path
    }
    set {
      UserDefaults.standard.set(newValue, forKey: modelsDirectoryKey)
    }
  }

  /// Whether exported, saved and dragged images carry their generation settings (on by default).
  static let embedsSettingsKey = "embedSettingsInImages"
  static var embedsSettings: Bool {
    UserDefaults.standard.object(forKey: embedsSettingsKey) as? Bool ?? true
  }

  /// Root of the history folder: one subfolder per day.
  static var historyDirectory: URL {
    FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier", isDirectory: true)
  }
}

/// Engine settings from Draw Things' Machine Settings. Each is stored in UserDefaults and handed to
/// the engine under the dictionary key and raw values Draw Things uses (`ModelPreloader.swift`).
/// No value means Automatic: the engine picks from the device, as Draw Things does.
enum PerformanceSetting: String, CaseIterable, Identifiable {
  case jitWeightsLoading = "external_store_v2"
  case weightsCacheSize = "total_weights_cache"
  case metalFlashAttention = "use_mfa_v4"
  case appleNeuralEngine = "use_mfa_apple_neural_engine_v2"
  case mergeLoRA = "merge_lora"

  var id: String { rawValue }

  /// UserDefaults key; `automatic` (-1) or no value means Automatic.
  var defaultsKey: String { "performance." + rawValue }
  static let automatic = -1

  var value: Int? {
    let saved = UserDefaults.standard.object(forKey: defaultsKey) as? Int
    return saved == Self.automatic ? nil : saved
  }

  var title: String {
    switch self {
    case .jitWeightsLoading: "JIT Weights Loading"
    case .weightsCacheSize: "Weights Cache Size"
    case .metalFlashAttention: "Metal Flash Attention"
    case .appleNeuralEngine: "Use Apple Neural Engine for 8-bit S Models"
    case .mergeLoRA: "Merge LoRA"
    }
  }

  var detail: String {
    switch self {
    case .jitWeightsLoading:
      "Loads weights only when they're needed. Saves RAM on smaller Macs at some cost in speed."
    case .weightsCacheSize:
      "Keeps copies of model weights in memory so large models reload in under a second instead of several. Lower it to use less RAM."
    case .metalFlashAttention:
      "Faster attention on Apple silicon. Quantized attention is faster still on M5 and later."
    case .appleNeuralEngine:
      "Runs 8-bit S models on the Neural Engine. Usually faster on M4; on M5 often slower but more power efficient."
    case .mergeLoRA:
      "Merging LoRA weights into the model is 10–30% faster. Running them separately keeps quantized weights and uses less RAM."
    }
  }

  /// Choices as (raw value, label), in Draw Things' order.
  var options: [(value: Int, label: String)] {
    switch self {
    case .jitWeightsLoading:
      [(1, "Always (Partial)"), (2, "Always"), (3, "Never")]
    case .weightsCacheSize:
      // Stored in units of 8 GiB, like the engine; offered up to the Mac's RAM less 8 GiB.
      (0..<max(Int(ProcessInfo.processInfo.physicalMemory >> 33), 1)).map {
        ($0, $0 == 0 ? "Off" : "\($0 * 8) GiB")
      }
    case .metalFlashAttention:
      [(0, "No"), (1, "Yes, Prefer Quantized Attention"), (2, "Yes, Prefer Non-Quantized Attention")]
    case .appleNeuralEngine:
      [(0, "No"), (1, "Yes, Prefer Apple Neural Engine Only"), (2, "Yes, Prefer Apple Neural Engine and GPU")]
    case .mergeLoRA:
      [(0, "Never"), (1, "Always")]
    }
  }

  /// What the engine picks on this Mac when nothing is set (`ModelPreloader.update…(nil)`).
  var automaticValue: Int {
    switch self {
    case .jitWeightsLoading: 0
    case .weightsCacheSize: Int(DeviceCapability.maxTotalWeightsCacheSize >> 33)
    case .metalFlashAttention: DeviceCapability.isMFASupported ? 1 : 0
    case .appleNeuralEngine: DeviceCapability.isMFAAppleNeuralEngineFaster ? 2 : 0
    case .mergeLoRA: 0
    }
  }

  var automaticLabel: String {
    // Automatic JIT loading decides per model and device; the others resolve to one choice.
    if self == .jitWeightsLoading { return "Automatic" }
    let label = options.first { $0.value == automaticValue }?.label ?? "\(automaticValue)"
    return "Automatic (\(label))"
  }

  /// Decode step previews with the tiny autoencoder (TAESD, on the Neural Engine when it can)
  /// instead of the low-resolution latent preview. The default is the engine's
  /// `DeviceCapability.isTAESDPreferred`.
  static let highResolutionPreviewKey = "performance.highResolutionPreview"
  static var highResolutionPreview: Bool {
    UserDefaults.standard.object(forKey: highResolutionPreviewKey) as? Bool
      ?? DeviceCapability.isTAESDPreferred
  }
}
