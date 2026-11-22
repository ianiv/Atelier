@testable import Atelier
@preconcurrency import Downloader
import Foundation
import Testing

/// Importing from Hugging Face links: what links parse to, the API's JSON, which rows a repo's
/// files become (split sets, Diffusers denoisers and precisions, encoders left out), and that the
/// token only goes to Hugging Face itself.
@Suite(.tags(.smoke))
struct HuggingFaceLinkTests {
  private func link(_ text: String) -> HuggingFaceLink? { HuggingFaceLink.parse(text) }

  @Test func parsesRepoPagesFilesAndDownloads() {
    #expect(link("https://huggingface.co/black-forest-labs/FLUX.1-dev") == HuggingFaceLink(repo: "black-forest-labs/FLUX.1-dev"))
    #expect(link("https://huggingface.co/black-forest-labs/FLUX.1-dev/blob/main/ae.safetensors")
      == HuggingFaceLink(repo: "black-forest-labs/FLUX.1-dev", revision: "main", path: "ae.safetensors"))
    #expect(link("https://huggingface.co/a/b/resolve/0123abc/unet/diffusion_pytorch_model.fp16.safetensors?download=true")
      == HuggingFaceLink(repo: "a/b", revision: "0123abc", path: "unet/diffusion_pytorch_model.fp16.safetensors"))
    #expect(link("https://huggingface.co/a/b/tree/main/transformer") == HuggingFaceLink(repo: "a/b", revision: "main", path: "transformer"))
    #expect(link("https://huggingface.co/a/b/tree/main") == HuggingFaceLink(repo: "a/b", revision: "main", path: nil))
    #expect(link("https://hf.co/a/b") == HuggingFaceLink(repo: "a/b"))
    #expect(link("huggingface.co/a/b") == HuggingFaceLink(repo: "a/b"))
    #expect(link("https://huggingface.co/models/a/b") == HuggingFaceLink(repo: "a/b"))
    #expect(link("  a/b  ") == HuggingFaceLink(repo: "a/b"))
    #expect(link("hf://a/b/vae/model.safetensors") == HuggingFaceLink(repo: "a/b", path: "vae/model.safetensors"))
    #expect(link("hf://a/b@v2/x.safetensors") == HuggingFaceLink(repo: "a/b", revision: "v2", path: "x.safetensors"))
    // A revision with slashes is one encoded part; a file name with a space is decoded.
    #expect(link("https://huggingface.co/a/b/blob/refs%2Fpr%2F3/my%20file.safetensors")
      == HuggingFaceLink(repo: "a/b", revision: "refs/pr/3", path: "my file.safetensors"))
    // Other pages of a repo still name it.
    #expect(link("https://huggingface.co/a/b/discussions/4") == HuggingFaceLink(repo: "a/b"))
  }

  @Test func rejectsWhatIsntAModelRepo() {
    #expect(link("https://huggingface.co/datasets/a/b") == nil)
    #expect(link("https://huggingface.co/spaces/a/b") == nil)
    #expect(link("hf://datasets/a/b") == nil)
    #expect(link("https://civitai.com/models/123") == nil)
    #expect(link("https://huggingface.co.evil.com/a/b") == nil)
    #expect(link("https://huggingface.co/a") == nil)
    #expect(link("ftp://huggingface.co/a/b") == nil)
    #expect(link("a/b/c") == nil)
    #expect(link("not a link") == nil)
    #expect(link("a/b c") == nil)
    #expect(link("a/<b>") == nil)
    #expect(link("") == nil)
  }

  @Test func buildsDownloadAndAPIURLs() {
    #expect(HuggingFaceLink.resolveURL(repo: "a/b", revision: "abc", path: "unet/my file.safetensors").absoluteString
      == "https://huggingface.co/a/b/resolve/abc/unet/my%20file.safetensors")
    #expect(HuggingFaceLink.infoURL(repo: "a/b", revision: "refs/pr/3").absoluteString
      == "https://huggingface.co/api/models/a/b/revision/refs%2Fpr%2F3")
    #expect(HuggingFaceLink.treeURL(repo: "a/b", sha: "abc").absoluteString.hasPrefix("https://huggingface.co/api/models/a/b/tree/abc?recursive=true"))
  }

  @Test func decodesRepoInfo() throws {
    let gated = try HuggingFaceRepoInfo.decode(Data(#"{"id":"a/b","sha":"0123","gated":"manual","private":false}"#.utf8))
    #expect(gated == HuggingFaceRepoInfo(sha: "0123", isGated: true, isPrivate: false))
    let open = try HuggingFaceRepoInfo.decode(Data(#"{"id":"a/b","sha":"4567","gated":false,"private":true}"#.utf8))
    #expect(open == HuggingFaceRepoInfo(sha: "4567", isGated: false, isPrivate: true))
    #expect(throws: HuggingFaceError.self) { try HuggingFaceRepoInfo.decode(Data(#"{"error":"Repository not found"}"#.utf8)) }
  }

  @Test func decodesTreeAndPages() throws {
    let json = #"""
    [{"type":"directory","oid":"1","size":0,"path":"unet"},
     {"type":"file","oid":"2","size":547,"path":"unet/config.json"},
     {"type":"file","oid":"3","size":135,"path":"unet/diffusion_pytorch_model.safetensors",
      "lfs":{"oid":"ab12","size":3438167534,"pointerSize":135}}]
    """#
    let files = try HuggingFaceRepoInfo.decodeTree(Data(json.utf8))
    #expect(files == [
      HuggingFaceRepoFile(path: "unet/config.json", size: 547, sha256: nil),
      HuggingFaceRepoFile(path: "unet/diffusion_pytorch_model.safetensors", size: 3_438_167_534, sha256: "ab12"),
    ])
    #expect(HuggingFaceRepoInfo.nextPage(link: #"<https://huggingface.co/api/models/a/b/tree/x?cursor=Y>; rel="next""#)?.absoluteString
      == "https://huggingface.co/api/models/a/b/tree/x?cursor=Y")
    #expect(HuggingFaceRepoInfo.nextPage(link: nil) == nil)
  }

  private func file(_ path: String, _ size: Int64 = 1000) -> HuggingFaceRepoFile {
    HuggingFaceRepoFile(path: path, size: size, sha256: path.hasSuffix(".json") ? nil : "sha-" + path)
  }

  @Test func groupsSplitSafetensorsIntoOneRow() {
    let files = (1...3).map { file("model-0000\($0)-of-00003.safetensors") }
      + [file("model.safetensors.index.json"), file("README.md"), file("config.json")]
    let listing = HuggingFaceListing.make(repo: "a/big-model", files: files, modelIndex: nil)
    #expect(listing.diffusers == nil)
    #expect(listing.entries.count == 1)
    let entry = listing.entries[0]
    #expect(entry.merges && entry.weights.count == 3 && entry.index == "model.safetensors.index.json")
    #expect(entry.modelOutput == "big-model.safetensors")
    #expect(entry.modelProblem == nil && entry.loraProblem != nil)
    #expect(entry.size == 4000)
  }

  @Test func incompleteSplitSetIsListedWithTheReason() {
    let files = [file("x-00001-of-00003.safetensors"), file("x-00003-of-00003.safetensors")]
    let entry = HuggingFaceListing.make(repo: "a/b", files: files, modelIndex: nil).entries.first
    #expect(entry?.modelProblem?.contains("2 of its 3") == true)
  }

  @Test func listsEveryCheckpointAndDisablesWhatCantImport() {
    let files = [
      file("flux1-dev.safetensors"), file("ae.safetensors"), file("model.gguf"),
      file("text_encoder/model.safetensors"), file("text_encoder/flax_model.msgpack"),
      file("split_files/vae/minimax_h3_image_vae_fp16.safetensors"),
      file("split_files/vae/other_vae.safetensors"), file("pytorch_lora_weights.bin"), file("notes.txt"),
    ]
    let listing = HuggingFaceListing.make(repo: "a/repo", files: files, modelIndex: nil)
    func entry(_ path: String) -> HuggingFaceListing.Entry? { listing.entries.first { $0.id == path } }
    #expect(entry("notes.txt") == nil)
    #expect(entry("flux1-dev.safetensors")?.modelProblem == nil)
    #expect(entry("model.gguf")?.modelProblem != nil)
    #expect(entry("text_encoder/model.safetensors")?.modelProblem == HuggingFaceListing.usesOwnEncoders)
    #expect(entry("text_encoder/flax_model.msgpack")?.modelProblem == HuggingFaceListing.usesOwnEncoders)
    #expect(entry("split_files/vae/other_vae.safetensors")?.modelProblem == HuggingFaceListing.usesOwnEncoders)
    // The H3 Image VAE is converted by the app, so it can come from vae/.
    #expect(entry("split_files/vae/minimax_h3_image_vae_fp16.safetensors")?.modelProblem == nil)
    // A .bin is a PyTorch pickle: the model importer reads it as .ckpt, a LoRA keeps it.
    #expect(entry("pytorch_lora_weights.bin")?.modelOutput == "repo.ckpt")
    #expect(entry("pytorch_lora_weights.bin")?.loraOutput == "repo.bin")
    // Importable rows come first.
    #expect(listing.entries.prefix(3).allSatisfy { $0.modelProblem == nil })
  }

  @Test func picksTheDiffusersDenoiserAndPrecision() {
    let files = [
      file("model_index.json"),
      file("unet/diffusion_pytorch_model.bin"), file("unet/diffusion_pytorch_model.safetensors"),
      file("unet/diffusion_pytorch_model.fp16.safetensors", 500), file("unet/diffusion_pytorch_model.fp16.bin"),
      file("unet/diffusion_pytorch_model.non_ema.safetensors"), file("unet/config.json"),
      file("text_encoder/model.safetensors"), file("vae/diffusion_pytorch_model.safetensors"),
      file("v1-5-pruned-emaonly.safetensors"),
    ]
    let index: [String: Any] = ["_class_name": "StableDiffusionPipeline", "unet": ["diffusers", "UNet2DConditionModel"], "vae": ["diffusers", "AutoencoderKL"]]
    let listing = HuggingFaceListing.make(repo: "o/stable-diffusion-v1-5", files: files, modelIndex: index)
    let diffusers = listing.diffusers
    #expect(diffusers?.className == "StableDiffusionPipeline" && diffusers?.folder == "unet")
    #expect(diffusers?.variants.map(\.name) == ["fp16", nil, "non_ema"])
    let fp16 = diffusers?.variants.first?.entry
    #expect(fp16?.files.map(\.path) == ["unet/diffusion_pytorch_model.fp16.safetensors"])
    #expect(fp16?.modelOutput == "stable-diffusion-v1-5.safetensors")
    // Safetensors before .bin for the default files too.
    #expect(diffusers?.variants[1].entry.files.map(\.path) == ["unet/diffusion_pytorch_model.safetensors"])
    // The denoiser's own files aren't rows of their own; the others are.
    #expect(!listing.entries.contains { $0.id.hasPrefix("unet/") })
    #expect(listing.entries.contains { $0.id == "v1-5-pruned-emaonly.safetensors" && $0.modelProblem == nil })
    #expect(listing.entries.first { $0.id == "vae/diffusion_pytorch_model.safetensors" }?.modelProblem == HuggingFaceListing.usesOwnEncoders)
  }

  @Test func prefersBF16OverDefaultAndJoinsSplitTransformers() {
    let files = [
      file("model_index.json"),
      file("transformer/diffusion_pytorch_model-00001-of-00002.safetensors"),
      file("transformer/diffusion_pytorch_model-00002-of-00002.safetensors"),
      file("transformer/diffusion_pytorch_model.safetensors.index.json"),
      file("transformer/diffusion_pytorch_model.bf16-00001-of-00002.safetensors"),
      file("transformer/diffusion_pytorch_model.bf16-00002-of-00002.safetensors"),
      file("transformer/diffusion_pytorch_model.safetensors.index.bf16.json"),
    ]
    let index: [String: Any] = ["_class_name": "FluxPipeline", "transformer": ["diffusers", "FluxTransformer2DModel"], "unet": [NSNull(), NSNull()]]
    let diffusers = HuggingFaceListing.make(repo: "o/flux", files: files, modelIndex: index).diffusers
    #expect(diffusers?.folder == "transformer")
    #expect(diffusers?.variants.map(\.name) == ["bf16", nil])
    let bf16 = diffusers?.variants.first?.entry
    #expect(bf16?.merges == true && bf16?.index == "transformer/diffusion_pytorch_model.safetensors.index.bf16.json")
    #expect(bf16?.weights.count == 2 && bf16?.modelProblem == nil)
    #expect(diffusers?.variants.last?.entry.index == "transformer/diffusion_pytorch_model.safetensors.index.json")
  }

  @Test func priorDecoderPipelinesHaveNoDenoiser() {
    let index: [String: Any] = ["_class_name": "StableCascadeCombinedPipeline", "prior": ["diffusers", "x"], "decoder": ["diffusers", "y"], "unet": [NSNull(), NSNull()]]
    let listing = HuggingFaceListing.make(repo: "o/cascade", files: [file("model_index.json"), file("prior/model.safetensors")], modelIndex: index)
    #expect(listing.diffusers?.folder == nil && listing.diffusers?.variants.isEmpty == true)
  }

  @Test func splitBinCantBeJoined() {
    let files = [file("pytorch_model-00001-of-00002.bin"), file("pytorch_model-00002-of-00002.bin")]
    let entry = HuggingFaceListing.make(repo: "a/b", files: files, modelIndex: nil).entries.first
    #expect(entry?.modelProblem?.contains("can't be joined") == true)
  }

  @Test func guessesLoRAs() {
    let small = HuggingFaceListing.Entry(
      id: "x", title: "x.safetensors", detail: "", files: [file("x.safetensors", 100_000)], index: nil, merges: false,
      modelOutput: "x.safetensors", loraOutput: "x.safetensors")
    #expect(HuggingFaceListing.guessesLoRA(repo: "a/b", entry: small))
    var large = small
    large.files = [file("x.safetensors", 6_000_000_000)]
    #expect(!HuggingFaceListing.guessesLoRA(repo: "a/b", entry: large))
    #expect(HuggingFaceListing.guessesLoRA(repo: "a/some-lora", entry: large))
  }

  @Test func tokenGoesOnlyToHuggingFaceOverHTTPS() throws {
    let bearer = ["Authorization": "Bearer hf_x"]
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "https://huggingface.co/a/b/resolve/x/y")), token: "hf_x") == bearer)
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "https://hf.co/api/whoami-v2")), token: "hf_x") == bearer)
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "https://HuggingFace.co/a")), token: "hf_x") == bearer)
    // CDN hosts get signed URLs, never the token; nor does anyone else or plain HTTP.
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "https://cdn-lfs.hf.co/x")), token: "hf_x").isEmpty)
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "https://cas-bridge.xethub.hf.co/x")), token: "hf_x").isEmpty)
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "https://huggingface.co.evil.com/x")), token: "hf_x").isEmpty)
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "http://huggingface.co/a")), token: "hf_x").isEmpty)
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "https://static.libnnc.org/x")), token: "hf_x").isEmpty)
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "https://huggingface.co/a")), token: nil).isEmpty)
    #expect(HuggingFaceAuth.headers(for: try #require(URL(string: "https://huggingface.co/a")), token: "").isEmpty)
  }

  @Test func onlyFullLinksAreTakenFromTheClipboard() {
    #expect(HuggingFaceLink.isExplicitLink("https://huggingface.co/a/b"))
    #expect(HuggingFaceLink.isExplicitLink(" https://hf.co/a/b/blob/main/x.safetensors "))
    #expect(HuggingFaceLink.isExplicitLink("hf://a/b"))
    #expect(!HuggingFaceLink.isExplicitLink("a/b"))
    #expect(!HuggingFaceLink.isExplicitLink("huggingface.co/a/b"))
    #expect(!HuggingFaceLink.isExplicitLink("http://huggingface.co/a/b"))
    #expect(!HuggingFaceLink.isExplicitLink("https://huggingface.co/datasets/a/b"))
  }

  @Test func treePathsOutsideTheRepoAreIgnored() throws {
    let json = #"""
    [{"type":"file","size":1,"path":"../escape.safetensors"},
     {"type":"file","size":1,"path":"/etc/x.safetensors"},
     {"type":"file","size":1,"path":"a/../../b.safetensors"},
     {"type":"file","size":1,"path":"a//b.safetensors"},
     {"type":"file","size":1,"path":"./c.safetensors"},
     {"type":"file","size":1,"path":"ok/model.safetensors"}]
    """#
    #expect(try HuggingFaceRepoInfo.decodeTree(Data(json.utf8)).map(\.path) == ["ok/model.safetensors"])
    #expect(HuggingFaceRepoFile.isSafePath("unet/diffusion_pytorch_model..fp16.safetensors"))
    #expect(!HuggingFaceRepoFile.isSafePath(""))
    #expect(!HuggingFaceRepoFile.isSafePath("~/x"))
  }

  @Test func outputNamesAreUniqueAcrossItems() {
    func item(_ path: String, output: String) -> LinkDownloadRecord.Item {
      LinkDownloadRecord.Item(title: path, files: [file(path)], index: nil, merges: false, output: output)
    }
    let items = ModelLibrary.uniqueOutputs([
      item("repo.safetensors", output: "repo.safetensors"),
      item("sub/model.safetensors", output: "repo.safetensors"),
      item("other/model.safetensors", output: "repo.safetensors"),
      item("x/sub/model.safetensors", output: "repo.safetensors"),
    ])
    #expect(items.map(\.output) == ["repo.safetensors", "repo-sub.safetensors", "repo-other.safetensors", "repo-2.safetensors"])
    // An output can't land on a file another item downloads.
    let clash = ModelLibrary.uniqueOutputs([
      item("sub/x.safetensors", output: "x.safetensors"),
      item("x.safetensors", output: "x.safetensors"),
    ])
    #expect(clash.map(\.output) == ["x-sub.safetensors", "x.safetensors"])
    // The same input gives the same names, so a resume finds the files.
    #expect(ModelLibrary.uniqueOutputs(items) == items)
  }

  @Test func downloadErrorsSayWhatToDo() {
    let unauthorized = Downloader.ResumableDownloader.DownloadError.server(401)
    #expect(ModelLibrary.describe(unauthorized, repo: "a/b", user: nil, hasToken: false) == HuggingFaceError.needsToken.localizedDescription)
    #expect(ModelLibrary.describe(unauthorized, repo: "a/b", user: "me", hasToken: true) == HuggingFaceError.tokenRejected.localizedDescription)
    #expect(ModelLibrary.isCancellation(URLError(.cancelled)))
    #expect(ModelLibrary.isCancellation(Downloader.ResumableDownloader.DownloadError.local(URLError(.cancelled))))
    #expect(ModelLibrary.isCancellation(CancellationError()))
    #expect(!ModelLibrary.isCancellation(URLError(.timedOut)))
  }

  @Test func spaceNeededByKind() {
    #expect(ModelLibrary.requiredSpace(downloadSize: 10_000, kind: .model, companionBytes: 500) == 21_500)
    #expect(ModelLibrary.requiredSpace(downloadSize: 10_000, kind: .lora, companionBytes: 500) == 12_000)
  }
}
