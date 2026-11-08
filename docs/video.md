# Making videos

Pick a video model in Create and the same screen makes videos: the prompt, inspector, canvas, moodboard, queue and History all work as they do for images. There's no separate mode to switch on.

## Video models

| Family | What it takes | Sound |
| --- | --- | --- |
| LTX-2, LTX-2.3 | The prompt; in Edit mode, the canvas as the first frame | Makes its own soundtrack |
| MiniMax H3 (FL2VA) | The canvas as the first frame and the first moodboard image as the last | Makes its own soundtrack |
| MiniMax H3 (Ref2VA), FastH3 Omni | The canvas and moodboard images as references, and an audio file | Makes its own soundtrack, following the audio you give it |
| Wan 2.1, Wan 2.2, SkyReels, Hunyuan Video | The prompt (T2V models); the canvas as the first frame (I2V models) | None |
| Stable Video Diffusion | An image to animate | None |
| LongCat Video Avatar | An image and a voice to lip-sync to | Keeps the voice you give it |

FastH3 Omni is a fast MiniMax H3 Ref2VA: it starts at 1280×768, 8 steps and guidance 1.

### HyperFlow H3 Flash

[HyperFlow H3 Flash](https://huggingface.co/VideoRebirthAI/hyperflow-h3-flash) is a compressed MiniMax H3 (FL2VA or Ref2VA) that makes a clip in a few steps. It isn't in the catalog: you convert its GGUF file and import it.

1. Download a GGUF from the `fl2va_gguf` or `ref2va_gguf` folder (Q8_0 is about 15 GB) and that folder's partner `config.json` from `fl2va_int8_convrot` or `ref2va_int8_convrot`.
2. Convert it with `Scripts/hyperflow/hyperflow_gguf_to_safetensors.py` from the engine fork (needs Python with `gguf` and `numpy`):
   `python hyperflow_gguf_to_safetensors.py <file>.gguf hyperflow_h3_flash_fl2va.safetensors --config config.json`. Keep `hyperflow` in the output name, and put `ref2va` in it for the Ref2VA file. The result is about 28 GB.
3. Import the `.safetensors` file in **Models** (see [Importing a checkpoint](models-and-loras.md#importing-a-checkpoint)). It uses the MiniMax H3 text encoder and VAE.
4. Select it in **Models** and click **Make 8-bit S Copy** (see [Make 8-bit Copy](models-and-loras.md#make-8-bit-copy-moss-and-minimax-h3-models)). The copy is about half the size and needs half the memory; use it in Create and move the full-precision one to the Trash if you like.

It starts at 1344×768, 124 frames, 6 steps, guidance 1 and shift 12. It's trained for exactly 4, 6 or 8 steps (4 is fastest, 8 best) and always runs its own sampler on those steps; any other step count falls back to a plain linear schedule and looks worse. Leave guidance at 1 and the negative prompt empty.

The weights are under the MiniMax H3 Community License: it doesn't cover the EU, the UK, South Korea or the US without MiniMax's permission, and asks that what you share be marked as AI-generated.

LongCat starts at 832×512, 8 steps, guidance 1 and 93 frames (3.7 seconds at 25 fps). It always runs at guidance 1, and the audio is cut or padded to the clip's length. It also needs the 1.3 GB Whisper voice encoder, which downloads with it.

Download them from **Models** like any other model. They're large, and a video takes minutes, not seconds.

## Length

The inspector's **Video** layout (from the menu at the top of the inspector) shows what most videos need: length, the second pass, the refiner, TeaCache and tiled decoding, with the rest one search away.


The inspector's **Video** section starts with **Length**: the number of frames, with how many seconds that plays for beside it. Each model only takes some frame counts (LTX one more than a multiple of 8, Wan one more than a multiple of 4, MiniMax H3 5 plus a multiple of 17), so the length snaps to the nearest one, and the stepper moves between them. Videos play at the rate the model was trained at (25 frames a second for LTX, 24 for MiniMax H3, 16 for Wan 2.1).

Longer and larger videos take much longer and need much more memory. Try a short, small one first.

MiniMax H3 models (including FastH3 Omni and HyperFlow H3 Flash) always decode in 256-pixel tiles, whatever the Tiled Decoding tile size says: larger tiles leave a grid of small blocks over the video.

## Starting from an image

- **First frame.** With a model that takes one, put an image on the canvas and switch to **Edit**, as you would to edit an image. The video starts from what's inside the frame.
- **Last frame (MiniMax H3 FL2VA).** The moodboard column is titled **Last Frame**: the first image on it is where the video ends.
- **References (MiniMax H3 Ref2VA).** The column is titled **References**, and each image says which picture it is. In Edit mode the canvas is Picture 1 and the moodboard images follow. Refer to them in the prompt as `<Picture 1>`, `<Picture 2>` and so on.

## Audio

Models that take an audio file show an **Audio** box at the top of the moodboard column. Drop an audio file on it or click **Choose Audio…**; it shows the file's name, length and waveform. For MiniMax H3 Ref2VA, refer to it in the prompt as `<Audio 1>`. Each queued video keeps the audio it was given, and **Use Settings** on a video brings its audio back.

LTX and MiniMax H3 make a soundtrack with the video. It's saved with the video, plays with it and is in the files you export. For MiniMax H3 models, **Audio Shift** (next to Shift in the inspector) shifts the soundtrack's noise schedule the way Shift does the video's.

## While it runs

The canvas plays the run's preview as it forms, frame by frame, and the status bar shows the step. Saving a long video takes a few seconds after the last step.

## Watching and reusing a video

A finished video waits on the canvas until you press Play, then loops. Right-click it for:

- **Save Video…** and **Save to Photos**.
- **Use This Frame as Input**: pauses on the frame on screen and puts it on the canvas in Edit mode. The next run follows that frame. From the last frame, that continues the video; from any other frame, it starts a branch there.
- **Use Last Frame as Input**: the same, from the last frame, to make the next part of a longer video.
- **Copy Frame** and **Add Frame to Moodboard**.

While a video is on the canvas, Edit mode doesn't send it: pick a frame with one of the items above.

## In History

A video is one tile in History, with a film badge showing its length (and a speaker when it has sound). On the Mac, moving the pointer across the tile scrubs through its frames. The detail panel plays it and lists its length, frame count and frame rate. **Export Video…** saves it as an MP4, as it is or upscaled (see [Exporting videos](#exporting-videos)), and dragging it out of Atelier drags the MP4. Use **Images / Videos** in the toolbar to show only one kind. **Add to Timeline** puts it on a timeline, to make a longer video from several (see [Putting videos together](video-editor.md)). Deleting a video deletes all of its frames.

Videos are stored in the project the way Draw Things stores them: one step per frame, plus the soundtrack, so Draw Things can open them too. That makes them large: a few seconds of video at 720p adds as much to the project file as a hundred images.

## Upscaling videos

To make a larger, sharper copy of a video, right-click it in History and choose **Upscale…**, or click **Upscale…** in its detail panel. Pick a method and a scale; the sheet shows the size it will make.

- **Quality** uses FlashVSR+, which restores the whole video as one stream, each part with the parts before it in view, so detail stays steady from frame to frame instead of shimmering. Pick **Turbo** (faster) or **Base** (slower, a little more detail). The first time, click **Download FlashVSR+** in the sheet: it downloads about 7 GB per version from Hugging Face into a **FlashVSR+** folder in the models folder. It makes videos up to 1920×1152 and takes a few seconds a frame.
- **Fast** uses Apple Super Resolution on the Neural Engine and takes seconds. macOS downloads its model the first time you use it. It offers only the scales your device supports (on some Macs, only 4×), for videos up to 1920×1080.

### Getting FlashVSR+

Atelier looks for FlashVSR+ in a **FlashVSR+** folder inside your models folder (Settings ▸ Models), and Quality is available for a version once all its files are there. **Download FlashVSR+** in the Upscale or Export Video sheet fetches whatever is missing, with its progress in the sheet; files already there are skipped, so an interrupted download picks up where it left off.

To download them yourself instead, for example on another machine, get these from [ruchangyao/FlashVSR_plus](https://huggingface.co/ruchangyao/FlashVSR_plus) on Hugging Face and lay them out like this:

```
Models/
  FlashVSR+/
    turbo/dit.safetensors        (Turbo, 5.7 GB)
    turbo/lq_proj_in.safetensors (Turbo, 1.2 GB)
    base/dit.safetensors         (Base, 5.7 GB)
    base/lq_proj_in.safetensors  (Base, 1.2 GB)
    TCDecoder.ckpt               (both, 189 MB)
    posi_prompt.pth              (both, 4 MB)
```

You only need the folder for the version you use (`turbo/` or `base/`), plus the two files both share. `posi_prompt.pth` is in [deAPI-ai/flashvsr-v1-1](https://huggingface.co/deAPI-ai/flashvsr-v1-1). Keep the file names as they are; Atelier reads them in place, without converting them.

FlashVSR+ is by OpenImagingLab, and Atelier's version follows T-Go LLC's vpipe port; both are Apache-2.0 (see **Settings ▸ About**).

### When it runs

The upscale runs in the Queue like any other job. The result is a new video after the original, with the same prompt and settings at the new size, and the soundtrack kept.

**Upscale…** makes a new video in History. To save a larger copy as a file instead, use **Export Video…** with an upscale (below).

## Exporting videos

**Export Video…**, on a video in History (its menu or the detail panel) and in the Video Editor, opens one sheet:

- **Upscale**: **None** (as it is), **Fast** or **Quality**, as above, with Quality's **Turbo** or **Base**.
- **Scale**: the scales that work for the video (disabled with None). The sheet shows the size it makes and, when upscaling, about how long it takes.

Then you choose where to save it. As it is, it exports right away. Upscaled, it's a job in the [Queue](queue.md#exports): it waits its turn after what's already queued, shows its progress in the status bar and the Queue, and writes the file when it's done. The video in History (or the timeline) is left as it is.

To upscale a video from outside Atelier, drop its file on the Create canvas. The same sheet opens, without None, and the result is only the file you save: nothing is added to the project or the canvas. Atelier works from a copy of the file, so you can move the original, and HDR video comes out as SDR.

## On another device

Videos, upscales and exports can run on a [paired server](remote.md), chosen with **Run on** in the inspector. A video sends its reference images and audio file and brings back every frame, the soundtrack and the frame rate, and is saved like one made here. **Upscale…** uses the server's FlashVSR+ or Apple Super Resolution rather than this device's: a clip made on that server doesn't need its frames sent back while the server still has them, for up to 7 days. **Export Video…** with an upscale sends the frames there and encodes the file on this device. Upscales and exports aren't picked up again after a quit.

## Files

Videos are saved as MP4, with AAC sound when there is any. **Settings ▸ Images ▸ Video Format** picks **H.264** (plays everywhere, the default) or **HEVC** (smaller files). With **Save Generated Images to Output Folder** on, each new video is also written there. With **Include Generation Settings in Saved Images** on, the MP4 carries its prompt, model, seed and settings, as images do.

## On iPad

Everything above works on iPad; touch and hold a video for its menu. Scrubbing a History tile needs a pointer, so on iPad play the video in the detail panel instead. Fast upscaling takes videos up to 1440×1080 on iPad. iPadOS stops generation in the background, so a video that was being made when you switched away may fail; **Retry** in the Queue runs it again.
