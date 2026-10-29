"""Score a finished cut with one continuous MMAudio soundtrack.

Spike for Atelier's Video Editor: MMAudio is trained on 8 s clips, so a long
cut is scored in overlapping windows that share a prompt and seed and are
joined with equal-power crossfades. Run from an environment where the MMAudio
repo (https://github.com/hkchengrex/MMAudio) is installed:

    python score_cut.py --video cut.mp4 --prompt "rain on a tin roof" --out scored.mp4
"""

import argparse
import logging
import math
import subprocess
import time
from pathlib import Path

import numpy as np
import soundfile
import torch

from mmaudio.eval_utils import all_model_cfg, generate, load_video, setup_eval_logging
from mmaudio.model.flow_matching import FlowMatching
from mmaudio.model.networks import get_my_mmaudio
from mmaudio.model.utils.features_utils import FeaturesUtils

log = logging.getLogger()


def windows(duration, length, overlap):
    """(start, end) pairs covering [0, duration] with `overlap` seconds shared."""
    if duration <= length:
        return [(0.0, duration)]
    step = length - overlap
    count = math.ceil((duration - overlap) / step)
    starts = [min(i * step, duration - length) for i in range(count)]
    return [(s, s + length) for s in starts]


def crossfade_join(pieces, sample_rate):
    """pieces: [(start_sec, samples)] in order; overlapping parts are equal-power faded."""
    out = pieces[0][1].astype(np.float32)
    for start, audio in pieces[1:]:
        begin = round(start * sample_rate)
        fade = min(len(out) - begin, len(audio))
        t = np.linspace(0, 1, fade, dtype=np.float32) * np.pi / 2
        out[begin:begin + fade] = out[begin:begin + fade] * np.cos(t) + audio[:fade] * np.sin(t)
        out = np.concatenate([out[:begin + fade], audio[fade:]])
    return out


@torch.inference_mode()
def main():
    setup_eval_logging()
    parser = argparse.ArgumentParser()
    parser.add_argument('--video', type=Path, required=True)
    parser.add_argument('--prompt', default='')
    parser.add_argument('--negative-prompt', default='music')
    parser.add_argument('--variant', default='large_44k_v2')
    parser.add_argument('--window', type=float, default=8.0)
    parser.add_argument('--overlap', type=float, default=1.0)
    parser.add_argument('--steps', type=int, default=25)
    parser.add_argument('--cfg', type=float, default=4.5)
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--keep-original', action='store_true',
                        help="mix the cut's own audio (dialogue) over the score, ducking the score")
    parser.add_argument('--bed-gain', type=float, default=0.6)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()

    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    dtype = torch.bfloat16
    model = all_model_cfg[args.variant]
    model.download_if_needed()
    seq_cfg = model.seq_cfg

    started = time.time()
    net = get_my_mmaudio(model.model_name).to(device, dtype).eval()
    net.load_weights(torch.load(model.model_path, map_location=device, weights_only=True))
    features = FeaturesUtils(tod_vae_ckpt=model.vae_path, synchformer_ckpt=model.synchformer_ckpt,
                             enable_conditions=True, mode=model.mode,
                             bigvgan_vocoder_ckpt=model.bigvgan_16k_path,
                             need_vae_encoder=False).to(device, dtype).eval()
    log.info('Loaded %s on %s in %.1f s', args.variant, device, time.time() - started)

    # Load the whole cut once at MMAudio's two frame rates, then slice per window.
    video = load_video(args.video, float('inf'), load_all_frames=False)
    duration = video.duration_sec
    clip_fps, sync_fps = 8.0, 25.0
    fm = FlowMatching(min_sigma=0, inference_mode='euler', num_steps=args.steps)

    pieces = []
    for start, end in windows(duration, args.window, args.overlap):
        t0 = time.time()
        clip = video.clip_frames[round(start * clip_fps):round(end * clip_fps)]
        sync = video.sync_frames[round(start * sync_fps):round(end * sync_fps)]
        seq_cfg.duration = min(clip.shape[0] / clip_fps, sync.shape[0] / sync_fps)
        net.update_seq_lengths(seq_cfg.latent_seq_len, seq_cfg.clip_seq_len, seq_cfg.sync_seq_len)
        rng = torch.Generator(device=device).manual_seed(args.seed)
        audio = generate(clip.unsqueeze(0), sync.unsqueeze(0), [args.prompt],
                         negative_text=[args.negative_prompt], feature_utils=features, net=net,
                         fm=fm, rng=rng, cfg_strength=args.cfg)
        pieces.append((start, audio.float().cpu()[0].mean(0).numpy()))
        log.info('Window %.1f-%.1f s took %.1f s', start, end, time.time() - t0)

    track = crossfade_join(pieces, seq_cfg.sampling_rate)
    track = track[:round(duration * seq_cfg.sampling_rate)]
    peak = float(np.abs(track).max())
    if peak > 0.98:
        track *= 0.98 / peak
    wav = args.out.with_suffix('.wav')
    soundfile.write(wav, track, seq_cfg.sampling_rate)
    if args.keep_original:
        # The cut's own audio (dialogue) stays on top; the score ducks under it.
        mix = ['-filter_complex',
               f'[0:a]aformat=sample_rates={seq_cfg.sampling_rate}:channel_layouts=stereo,asplit[voice][key];'
               f'[1:a]aformat=channel_layouts=stereo,volume={args.bed_gain}[bed];'
               '[bed][key]sidechaincompress=threshold=0.03:ratio=8:attack=20:release=400[ducked];'
               '[voice][ducked]amix=inputs=2:normalize=0[a]',
               '-map', '0:v', '-map', '[a]']
    else:
        mix = ['-map', '0:v', '-map', '1:a']
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(args.video), '-i', str(wav),
                    *mix, '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest',
                    str(args.out)], check=True)
    log.info('Scored %.1f s of video in %.1f s total -> %s', duration, time.time() - started, args.out)


if __name__ == '__main__':
    main()
