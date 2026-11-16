#!/usr/bin/env python3
"""Merge LongCat-Video-Avatar 1.6's distillation LoRAs into its base model.

LongCat-Video-Avatar 1.6 (https://huggingface.co/meituan-longcat/LongCat-Video-Avatar-1.6, MIT)
ships a bf16 base DiT and two step-distillation LoRAs: loraA (DMD) and loraB (OPSD). The official
recipe (`run_demo_avatar_single_audio_to_video.py --use_distill --mix_steps 4 --mix_alpha 1.0`)
runs 8 steps with DMD alone for steps 0-3 and OPSD alone for steps 4-7
(`LongCatVideoAvatarTransformer3DModel.set_lora_mix_step`: mix_alpha 1.0 gives DMD multiplier 1
and OPSD 0 below mix_steps, OPSD 1 from there on). The Draw Things engine can't load LongCat
LoRAs (LoRAImporter has no LongCat mapping), so each LoRA is merged into its own copy of the base
model; Atelier runs the DMD copy as the model and the OPSD copy as its refiner, swapping at step 4.

The merge follows `LongCatVideoAvatarTransformer3DModel.merge_lora` exactly:

    W(fp32) += multiplier * alpha_scale * (up @ down)

where alpha_scale is the LoRA file's own `alpha_scale` buffer (load_state_dict(strict=True)
overwrites the 64 / 128 the network is built with; both are 0.5), and for fused projections
(attn.qkv, cross_attn.kv_linear) `lora_up.blocks.N` is matched to chunk N of `lora_down` along
dim 0 and the products are concatenated along dim 0. Multiplier is 1.0, as in the mix recipe.

One deliberate difference: `merge_lora` casts the merged weight back to bf16, but the mix recipe
never merges (it adds the LoRA's output at run time), and the deltas are tiny next to the weights
(mean |delta| ~3e-5 against ~3e-2), so rounding to bf16 drops about three quarters of them. The
merged weights are written as F32 instead; the engine's importer rounds once, to its own f16.

Each output is one .safetensors (Draw Things' ModelImporter takes LongCat from a single file),
written tensor by tensor so the model (60 GB in F32) never has to be in memory at once.

Usage:
  longcat-avatar-merge.py BASE_DIR LORA OUT [LORA OUT ...]

  BASE_DIR  the repo's base_model folder (diffusion_pytorch_model.safetensors.index.json + shards)
  LORA OUT  a LoRA file (loraA/lora.safetensors, loraB/lora.safetensors) and the merged file to write

Needs torch and safetensors; runs on the CPU (336 rank-128 products per LoRA).
"""

import json
import os
import struct
import sys
from collections import defaultdict

import torch
from safetensors import safe_open

LORA_PREFIX = "lora___lorahyphen___"
LORA_HYPHEN = "___lorahyphen___"

DTYPE_NAMES = {torch.bfloat16: "BF16", torch.float16: "F16", torch.float32: "F32"}


def module_name(lora_name):
  """The DiT module a LoRA entry targets, as `LoRANetwork` derives it from the key."""
  return lora_name.replace(LORA_PREFIX, "").replace(LORA_HYPHEN, ".")


class LoRA:
  """One LoRA file, indexed by the base weight each entry targets (`blocks.0.attn.qkv.weight`).

  Deltas are computed on demand: all 336 of them in fp32 would take about 48 GB.
  """

  def __init__(self, path):
    self.path = path
    self.file = safe_open(path, "pt")
    self.keys = set(self.file.keys())
    names = sorted({k.split(".lora_down.weight")[0] for k in self.keys if k.endswith(".lora_down.weight")})
    self.names = {module_name(name) + ".weight": name for name in names}

  def __contains__(self, weight_key):
    return weight_key in self.names

  def __len__(self):
    return len(self.names)

  def alpha_scale(self, weight_key):
    key = self.names[weight_key] + ".alpha_scale"
    return float(self.file.get_tensor(key).float().item()) if key in self.keys else 64 / 128

  def delta(self, weight_key):
    """up @ down in fp32, with fused projections' up blocks matched to chunks of down."""
    name = self.names[weight_key]
    down = self.file.get_tensor(name + ".lora_down.weight").to(torch.float32)
    block_prefix = name + ".lora_up.blocks."
    block_count = sum(1 for k in self.keys if k.startswith(block_prefix))
    if block_count > 0:
      down_chunks = torch.chunk(down, block_count, dim=0)
      return torch.cat(
        [
          torch.mm(self.file.get_tensor(f"{block_prefix}{i}.weight").to(torch.float32), down_chunks[i])
          for i in range(block_count)
        ],
        dim=0,
      )
    return torch.mm(self.file.get_tensor(name + ".lora_up.weight").to(torch.float32), down)

  def delta_shape(self, weight_key):
    name = self.names[weight_key]
    down = self.file.get_slice(name + ".lora_down.weight").get_shape()
    block_prefix = name + ".lora_up.blocks."
    blocks = sorted(k for k in self.keys if k.startswith(block_prefix))
    if blocks:
      return (sum(self.file.get_slice(k).get_shape()[0] for k in blocks), down[1])
    return (self.file.get_slice(name + ".lora_up.weight").get_shape()[0], down[1])


class StreamingWriter:
  """Writes a .safetensors file one tensor at a time from a header computed up front."""

  def __init__(self, path, entries):
    # entries: list of (name, dtype, shape) in write order.
    header = {}
    offset = 0
    self.sizes = {}
    for name, dtype, shape in entries:
      count = 1
      for d in shape:
        count *= d
      size = count * torch.tensor([], dtype=dtype).element_size()
      header[name] = {"dtype": DTYPE_NAMES[dtype], "shape": list(shape), "data_offsets": [offset, offset + size]}
      self.sizes[name] = size
      offset += size
    header["__metadata__"] = {"format": "pt"}
    blob = json.dumps(header, separators=(",", ":")).encode("utf-8")
    blob += b" " * ((8 - len(blob) % 8) % 8)
    self.file = open(path + ".partial", "wb")
    self.path = path
    self.file.write(struct.pack("<Q", len(blob)))
    self.file.write(blob)

  def write(self, name, tensor):
    data = tensor.contiguous().view(torch.uint8).numpy().tobytes() if tensor.numel() else b""
    assert len(data) == self.sizes[name], name
    self.file.write(data)

  def close(self):
    self.file.close()
    os.replace(self.path + ".partial", self.path)


def main(argv):
  if len(argv) < 4 or len(argv) % 2 != 0:
    print(__doc__)
    return 2
  base_dir = argv[1]
  pairs = [(argv[i], argv[i + 1]) for i in range(2, len(argv), 2)]
  with open(os.path.join(base_dir, "diffusion_pytorch_model.safetensors.index.json")) as f:
    weight_map = json.load(f)["weight_map"]
  by_shard = defaultdict(list)
  for name, shard in weight_map.items():
    by_shard[shard].append(name)
  shards = sorted(by_shard)

  # Shapes and dtypes for the headers, in shard order (the write order).
  entries = []
  for shard in shards:
    f = safe_open(os.path.join(base_dir, shard), "pt")
    for name in sorted(by_shard[shard]):
      s = f.get_slice(name)
      entries.append((name, torch.float32, tuple(s.get_shape())))
  shapes = {name: shape for name, _, shape in entries}

  loras = []
  for lora_path, out_path in pairs:
    deltas = LoRA(lora_path)
    missing = [k for k in deltas.names if k not in shapes]
    if missing:
      raise SystemExit(f"{lora_path}: {len(missing)} LoRA targets not in the base model, e.g. {missing[:3]}")
    for k in deltas.names:
      if tuple(deltas.delta_shape(k)) != shapes[k]:
        raise SystemExit(f"{lora_path}: {k} delta {deltas.delta_shape(k)} != weight {shapes[k]}")
    print(f"{lora_path}: {len(deltas)} Linear weights")
    loras.append((deltas, StreamingWriter(out_path, entries), out_path))

  multiplier = 1.0
  merged = [0] * len(loras)
  for shard in shards:
    print(f"  {shard}")
    f = safe_open(os.path.join(base_dir, shard), "pt")
    for name in sorted(by_shard[shard]):
      weight = f.get_tensor(name)
      for index, (deltas, writer, _) in enumerate(loras):
        if name in deltas:
          w = weight.to(torch.float32)
          w += (multiplier * deltas.alpha_scale(name)) * deltas.delta(name)
          writer.write(name, w)
          merged[index] += 1
        else:
          writer.write(name, weight.to(torch.float32))
  for (deltas, writer, out_path), count in zip(loras, merged):
    writer.close()
    assert count == len(deltas)
    print(f"wrote {out_path} ({count} weights merged)")
  return 0


if __name__ == "__main__":
  sys.exit(main(sys.argv))
