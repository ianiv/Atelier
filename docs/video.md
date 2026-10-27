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

Download them from **Models** like any other model. They're large, and a video takes minutes, not seconds.

## Length

The inspector's **Video** layout (from the menu at the top of the inspector) shows what most videos need: length, the second pass, the refiner, TeaCache and tiled decoding, with the rest one search away.


The inspector's **Video** section starts with **Length**: the number of frames, with how many seconds that plays for beside it. Each model only takes some frame counts (LTX one more than a multiple of 8, Wan one more than a multiple of 4, MiniMax H3 5 plus a multiple of 17), so the length snaps to the nearest one, and the stepper moves between them. Videos play at the rate the model was trained at (25 frames a second for LTX, 24 for MiniMax H3, 16 for Wan 2.1).

Longer and larger videos take much longer and need much more memory. Try a short, small one first.

## Starting from an image

- **First frame.** With a model that takes one, put an image on the canvas and switch to **Edit**, as you would to edit an image. The video starts from what's inside the frame.
- **Last frame (MiniMax H3 FL2VA).** The moodboard column is titled **Last Frame**: the first image on it is where the video ends.
- **References (MiniMax H3 Ref2VA).** The column is titled **References**, and each image says which picture it is. In Edit mode the canvas is Picture 1 and the moodboard images follow. Refer to them in the prompt as `<Picture 1>`, `<Picture 2>` and so on.

## Audio

Models that take an audio file show an **Audio** box at the top of the moodboard column. Drop an audio file on it or click **Choose Audio…**; it shows the file's name, length and waveform. For MiniMax H3 Ref2VA, refer to it in the prompt as `<Audio 1>`. Each queued video keeps the audio it was given, and **Use Settings** on a video brings its audio back.

LTX and MiniMax H3 make a soundtrack with the video. It's saved with the video, plays with it and is in the files you export.

## While it runs

The canvas plays the run's preview as it forms, frame by frame, and the status bar shows the step. Saving a long video takes a few seconds after the last step.

## Watching and reusing a video

A finished video plays on the canvas, looping. Right-click it for:

- **Save Video…** (and **Save to Photos** on iPad).
- **Use This Frame as Input**: pauses on the frame on screen and puts it on the canvas in Edit mode. The next run follows that frame. From the last frame, that continues the video; from any other frame, it starts a branch there.
- **Use Last Frame as Input**: the same, from the last frame, to make the next part of a longer video.
- **Copy Frame** and **Add Frame to Moodboard**.

While a video is on the canvas, Edit mode doesn't send it: pick a frame with one of the items above.

## In History

A video is one tile in History, with a film badge showing its length (and a speaker when it has sound). On the Mac, moving the pointer across the tile scrubs through its frames. The detail panel plays it and lists its length, frame count and frame rate. **Export Video…** saves it as an MP4, and dragging it out of Atelier drags the MP4. Use **Images / Videos** in the toolbar to show only one kind. **Add to Timeline** puts it on a timeline, to make a longer video from several (see [Putting videos together](timeline.md)). Deleting a video deletes all of its frames.

Videos are stored in the project the way Draw Things stores them: one step per frame, plus the soundtrack, so Draw Things can open them too. That makes them large: a few seconds of video at 720p adds as much to the project file as a hundred images.

## Upscaling videos

To make a larger, sharper copy of a video, right-click it in History and choose **Upscale…**, or click **Upscale…** in its detail panel. Pick a method and a scale; the sheet shows the size it will make.

- **Quality** uses FlashVSR+, which restores the whole video as one stream, each part with the parts before it in view, so detail stays steady from frame to frame instead of shimmering. Pick **Turbo** (faster) or **Base** (slower, a little more detail). The first time, click **Download FlashVSR+** in the sheet: it downloads about 7 GB per version from Hugging Face into a **FlashVSR+** folder in the models folder. It makes videos up to 1920×1152, takes a few seconds a frame, and needs a lot of memory (about 25 GB at 1664×1024).
- **Fast** uses Apple Super Resolution on the Neural Engine and takes seconds. macOS downloads its model the first time you use it. It offers only the scales your device supports (on some Macs, only 4×), for videos up to 1920×1080.

The upscale runs in the Queue like any other job. The result is a new video after the original, with the same prompt and settings at the new size, and the soundtrack kept.

To upscale a whole timeline instead, use **Export ▸ Export Upscaled Video…** in Timeline (see [Exporting](timeline.md#exporting)).

## Files

Videos are saved as MP4, with AAC sound when there is any. **Settings ▸ Images ▸ Video Format** picks **H.264** (plays everywhere, the default) or **HEVC** (smaller files). With **Save Generated Images to Output Folder** on, each new video is also written there. With **Include Generation Settings in Saved Images** on, the MP4 carries its prompt, model, seed and settings, as images do.

## On iPad

Everything above works on iPad; touch and hold a video for its menu. Scrubbing a History tile needs a pointer, so on iPad play the video in the detail panel instead. Quality upscaling needs 32 GB of memory, more than an iPad has; Fast upscaling takes videos up to 1440×1080 on iPad. iPadOS stops generation in the background, so a video that was being made when you switched away may fail; **Retry** in the Queue runs it again.
