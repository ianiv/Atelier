# Making videos

Pick a video model in Create and the same screen makes videos: the prompt, inspector, canvas, moodboard, queue and History all work as they do for images. There's no separate mode to switch on.

## Video models

| Family | What it takes | Sound |
| --- | --- | --- |
| LTX-2, LTX-2.3 | The prompt; in Edit mode, the canvas as the first frame | Makes its own soundtrack |
| MiniMax H3 (FL2VA) | The canvas as the first frame and the first moodboard image as the last (with an empty canvas, the first two moodboard images) | Makes its own soundtrack |
| MiniMax H3 (Ref2VA), FastH3 Omni | The canvas and moodboard images as references, a clip from History as a [reference video](#reference-video-minimax-h3-ref2va), and an audio file | Makes its own soundtrack, following the audio you give it |
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
4. Select it in **Models** and click **Make 8-bit S Copy** (see [Make 8-bit Copy](models-and-loras.md#make-8-bit-copy-moss-minimax-h3-and-longcat-models)). The copy is about half the size and needs half the memory; use it in Create and move the full-precision one to the Trash if you like.

It starts at 1344×768, 124 frames, 6 steps, guidance 1 and shift 12. It's trained for exactly 4, 6 or 8 steps (4 is fastest, 8 best) and always runs its own sampler on those steps; any other step count falls back to a plain linear schedule and looks worse. Leave guidance at 1 and the negative prompt empty.

The weights are under the MiniMax H3 Community License: it doesn't cover the EU, the UK, South Korea or the US without MiniMax's permission, and asks that what you share be marked as AI-generated.

LongCat starts at 832×512, 8 steps, guidance 1 and 93 frames (3.7 seconds at 25 fps). It always runs at guidance 1, and the audio is cut or padded to the clip's length. It also needs the 1.3 GB Whisper voice encoder, which downloads with it.

### LongCat-Video Avatar 1.6

[LongCat-Video Avatar 1.6](https://huggingface.co/meituan-longcat/LongCat-Video-Avatar-1.6) (MIT) is listed beside 1.5 as **LongCat-Video Avatar 1.6 (8-bit S)**. It comes as two files that download together: Meituan distilled 1.6 in two halves, one for the first four of its eight steps and one for the last four, and the second half (**LongCat-Video Avatar 1.6 OPSD (8-bit S)**) is set as its **Refiner**, with **Refiner Start** at 0.10, the value that hands over after step 4 at Shift 7. If you change the steps or Shift, the hand-over moves with them. Leave the refiner on: without it the first half runs all eight steps. The OPSD file only appears in the Refiner setting, not in the model picker or the Models list; it downloads and stays with the first half. If it's missing, a run says so instead of quietly running without it, and its row in Models offers **Download Missing File**. Moving or deleting 1.6 in Models moves or deletes the OPSD file with it. Switching to another model takes the OPSD refiner off; switching to 1.6 puts it back.

1.6 starts with 1.5's settings. Unlike 1.5, it hears the voice at the level you give it: 1.5 evens out the loudness of the audio first, 1.6 doesn't, so a very quiet or very loud recording may lip-sync less well. The files are Atelier's own conversion (`Scripts/longcat-avatar-merge.py` merges each half into the base model) and download from Hugging Face rather than Draw Things' server.

Download them from **Models** like any other model. They're large, and a video takes minutes, not seconds.

## Length

The inspector's **Video** layout (from the menu at the top of the inspector) shows what most videos need: length, the second pass, the refiner, TeaCache, Sol Attention (MiniMax H3) and tiled decoding, with the rest one search away.


The inspector's **Video** section starts with **Length**: the number of frames, with how many seconds that plays for beside it. Each model only takes some frame counts (LTX one more than a multiple of 8, Wan one more than a multiple of 4, MiniMax H3 5 plus a multiple of 17), so the length snaps to the nearest one, and the stepper moves between them. Videos play at the rate the model was trained at (25 frames a second for LTX, 24 for MiniMax H3, 16 for Wan 2.1).

Longer and larger videos take much longer and need much more memory. Try a short, small one first.

MiniMax H3 models (including FastH3 Omni and HyperFlow H3 Flash) always decode in 256-pixel tiles, whatever the Tiled Decoding tile size says: larger tiles leave a grid of small blocks over the video.

## Starting from an image

- **First frame.** With a model that takes one, put an image on the canvas and switch to **Edit**, as you would to edit an image. The video starts from what's inside the frame.
- **Last frame (MiniMax H3 FL2VA).** The moodboard column is titled **Last Frame**: the first image on it is where the video ends. With nothing on the canvas, or in Generate mode (which leaves the canvas out), it's titled **First & Last Frame**: its first image is where the video starts and its second where it ends (one image alone is only the start).
- **References (MiniMax H3 Ref2VA).** The column is titled **References**, and each image says which picture it is. In Edit mode the canvas is Picture 1 and the moodboard images follow. Refer to them in the prompt as `<Picture 1>`, `<Picture 2>` and so on. The distilled Ref2VA models (FastH3 Omni, Pika H3 Flex and HyperFlow H3 Flash Ref2VA) need at least one reference image, referred to in the prompt; without one they don't make a video.

## Reference video (MiniMax H3 Ref2VA)

MiniMax H3 Ref2VA models (FastH3 Omni and HyperFlow H3 Flash Ref2VA too) can follow a clip, its motion, camera or performance, as well as pictures. Open a video from History so it plays on the canvas, and switch to **Edit**: the canvas's badge says **Video 1**, and the clip is the reference video. Refer to it in the prompt as `<Video 1>`. The moodboard images are then Picture 1, Picture 2 and so on, since the canvas holds no picture.

- The clip is read from its start at the model's frame rate (24 fps for H3), one frame for each frame of the new video. A clip shorter than the new video holds its last frame; a longer one is cut off. Each frame is scaled to fill the frame on the canvas and cropped about its center, so a clip of another shape loses its edges.
- The new video is made from noise, with the clip only as its reference: **Strength** must be 100%, and **Length** at least 22 frames.
- It can't go with an audio file. With one in the **Audio** box, or with the Strength or Length above, Generate is disabled and the status bar (and the badge, in orange) says why.
- The new video follows the clip in History, but isn't recorded as made from it: **Use Settings** brings back its prompt and settings, not the clip.
- The queue keeps which clip, not its frames: they're read when the job starts, so a clip deleted while the job waits stops it with a message.

## Audio

Models that take an audio file show an **Audio** box at the top of the moodboard column. Drop an audio file on it or click **Choose Audio…**; it shows the file's name, length and waveform. For MiniMax H3 Ref2VA, refer to it in the prompt as `<Audio 1>`. Each queued video keeps the audio it was given, and **Use Settings** on a video brings its audio back.

LTX and MiniMax H3 make a soundtrack with the video. It's saved with the video, plays with it and is in the files you export. For MiniMax H3 models, **Audio Shift** (next to Shift in the inspector) shifts the soundtrack's noise schedule the way Shift does the video's.

For MiniMax H3 models (including FastH3 and HyperFlow H3), **Sol Attention** (its own section, under TeaCache) switches the model to sparse attention from **Start Step** on. It's much faster on long or large videos, with a small quality cost; **Tau** sets how picky it is about what still gets full attention (higher is faster with more quality cost; lower is closer to full attention). It's off by default, as in Draw Things, and is saved with each video and in presets, so settings imported from Draw Things keep it.

## While it runs

The canvas plays the run's preview as it forms, frame by frame, and the status bar shows the step. Saving a long video takes a few seconds after the last step.

## Watching and reusing a video

A finished video waits on the canvas until you press Play, then loops. Right-click it for:

- **Save Video…**, **Save to Photos** and **Share** (the MP4, to AirDrop, Mail, Messages and other apps).
- **Use This Frame as Input**: pauses on the frame on screen and puts it on the canvas in Edit mode. The next run follows that frame. From the last frame, that continues the video; from any other frame, it starts a branch there. **Load Settings from Image** then loads the video's settings, whichever frame it is.
- **Use Last Frame as Input**: the same, from the last frame, to make the next part of a longer video.
- **Copy Frame** and **Add Frame to Moodboard**.
- **Delete Video**: removes the video and all of its frames from the project, and from any timeline it's on, after asking, as in History. The canvas then shows the image that's now current.

While a video is on the canvas, Edit mode doesn't send it: pick a frame with one of the items above.

## In History

A video is one tile in History, with a film badge showing its length (and a speaker when it has sound). On the Mac, moving the pointer across the tile scrubs through its frames. The detail panel plays it and lists its length, frame count and frame rate. **Export Video…** saves it as an MP4, as it is or upscaled (see [Exporting videos](#exporting-videos)), and dragging it out of Atelier, or **Share**, sends the MP4. Use **Images / Videos** in the toolbar to show only one kind. **Add to Timeline** puts it on a timeline, to make a longer video from several (see [Putting videos together](video-editor.md)). Deleting a video deletes all of its frames.

Videos are stored in the project the way Draw Things stores them: one step per frame, plus the soundtrack, so Draw Things can open them too. That makes them large: a few seconds of video at 720p adds as much to the project file as a hundred images.

## Upscaling videos

To make a larger, sharper copy of a video, right-click it in History and choose **Upscale…**, or click **Upscale…** in its detail panel. Pick a method and a scale; the sheet shows the size it will make.

- **Quality** uses FlashVSR+, which restores the whole video as one stream, each part with the parts before it in view, so detail stays steady from frame to frame instead of shimmering. Pick **Turbo** (faster) or **Base** (slower, a little more detail). The first time, click **Download FlashVSR+** in the sheet: it downloads about 7 GB per version from Hugging Face into a **FlashVSR+** folder in the models folder. It makes videos up to 1920×1152 and takes a few seconds a frame.
- **ReCaVSR** restores the video with a large model (built on Wan2.2) a few frames at a time, reusing what it made for the frames before, so it stays steady too. Pick **Full** or **8-bit** weights: 8-bit uses about 3–4 GB less memory and looks nearly the same. The first time, click **Download ReCaVSR** (about 10.8 GB from Hugging Face, into a **ReCaVSR** folder in the models folder); for 8-bit, then click **Make 8-bit Copy**, which writes a 5.7 GB copy beside it in about a minute (stopping it keeps what's written, and the next copy carries on). If you already have an 8-bit copy, **Import 8-bit Copy…** brings it in without the big download (see [Getting ReCaVSR](#getting-recavsr)). It makes videos up to 1920×1088, about 0.6 s a frame at 1280×720 and 1.3 s at 1920×1080 on an M5 Max, and uses a lot of memory: about 23 GB at 720p and 30 GB at 1080p with 8-bit (27 and 33 GB full). It runs on a Mac: on an iPad, choose a paired Mac that has it in **Run on** (see [On another device](#on-another-device)); with the iPad itself as the target, ReCaVSR is shown but can't be picked. It upscales videos, not images.
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

### Getting ReCaVSR

Atelier looks for ReCaVSR in a **ReCaVSR** folder inside your models folder. **Full** is available once its three files are there at full size; **8-bit** needs only the 8-bit copy and the two small files (`prompt.safetensors` and `flashdecoder.safetensors`, 233 MB together), not the 10.6 GB transformer. **Download ReCaVSR** in the Upscale or Export Video sheet fetches whatever is missing, skipping files already there, the two small files first. To download them yourself, get these from [kopper/ReCaVSR](https://huggingface.co/kopper/ReCaVSR) (the VAE it also lists isn't needed):

```
Models/
  ReCaVSR/
    transformer.safetensors   (10.6 GB)
    prompt.safetensors        (4 MB)
    flashdecoder.safetensors  (229 MB)
    transformer_i8x.ckpt      (5.7 GB, written by Make 8-bit Copy or imported)
```

If you already have an 8-bit copy that Atelier made (on another Mac, say), click **Import 8-bit Copy…** in the same sheets and pick it, whatever it's named. Atelier checks that it's one of its own 8-bit copies and complete, then copies it into the ReCaVSR folder; your file stays where it is. It also brings the two small files: the ones beside the file you picked if they're there, otherwise it downloads them (233 MB). After that, choose **8-bit** under **Weights**: it works without downloading the full transformer, and Full still needs **Download ReCaVSR**. The button is off once the folder has an 8-bit copy. Other 8-bit formats of ReCaVSR aren't converted.

If you put `transformer_i8x.ckpt` in the folder yourself and the two small files aren't there, click **Download ReCaVSR**: it gets them first, 8-bit works as soon as they've arrived, and you can cancel the rest of the download if you only want 8-bit.

ReCaVSR is by Xijun Wang and others at the University of Science and Technology of China, Apache-2.0 (see **Settings ▸ About**).

### When it runs

The upscale runs in the Queue like any other job. The result is a new video after the original, with the same prompt and settings at the new size, and the soundtrack kept.

**Upscale…** makes a new video in History. To save a larger copy as a file instead, use **Export Video…** with an upscale (below).

## Exporting videos

**Export Video…**, on a video in History (its menu or the detail panel) and in the Video Editor, opens one sheet:

- **Upscale**: **None** (as it is), **Quality**, **ReCaVSR** or **Fast**, as above, with Quality's **Turbo** or **Base** and ReCaVSR's **Full** or **8-bit**.
- **Scale**: the scales that work for the video (disabled with None). The sheet shows the size it makes and, when upscaling, about how long it takes.

Then you choose where to save it. As it is, it exports right away. Upscaled, it's a job in the [Queue](queue.md#exports): it waits its turn after what's already queued, shows its progress in the status bar and the Queue, and writes the file when it's done. The video in History (or the timeline) is left as it is.

To upscale a video from outside Atelier, drop its file on the Create canvas. The same sheet opens, without None, and the result is only the file you save: nothing is added to the project or the canvas. Atelier works from a copy of the file, so you can move the original, and HDR video comes out as SDR.

## On another device

Videos, upscales and exports can run on a [paired server](remote.md), chosen with **Run on** in the inspector. A video sends its reference images, reference video (its frames, as prepared here) and audio file and brings back every frame, the soundtrack and the frame rate, and is saved like one made here. **Upscale…** uses the server's FlashVSR+, ReCaVSR or Apple Super Resolution rather than this device's: a clip made on that server doesn't need its frames sent back while the server still has them, for up to 7 days. **Export Video…** with an upscale sends the frames there and encodes the file on this device. Upscales and exports aren't picked up again after a quit.

## Files

Videos are saved as MP4, with AAC sound when there is any. **Settings ▸ Images ▸ Video Format** picks **H.264** (plays everywhere, the default) or **HEVC** (smaller files). With **Save Generated Images to Output Folder** on, each new video is also written there. With **Include Generation Settings in Saved Images** on, the MP4 carries its prompt, model, seed and settings, as images do.

## On iPad

Everything above works on iPad; touch and hold a video for its menu. Scrubbing a History tile needs a pointer, so on iPad play the video in the detail panel instead. Fast upscaling takes videos up to 1440×1080 on iPad. iPadOS stops generation in the background, so a video that was being made when you switched away may fail; **Retry** in the Queue runs it again.
