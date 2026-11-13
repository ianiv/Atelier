# Creating images

The **Create** screen has three parts: the canvas in the middle, the prompt box under it, and the settings inspector on the right. The toolbar holds the model menu, the Presets menu and the inspector button.

## Prompt

Type what you want in **Describe the image…** and press Return, or click **Generate** (⌘↩). Press ⌥↩ to start a new line instead. ⌘L jumps to the prompt from anywhere.

- **Negative Prompt**: click the disclosure under the prompt to describe what to avoid. Not every model uses it.
- **Style**: the button beside the prompt, above Generate, picks a [style](styles.md), a template Generate writes your prompt into. With a style, the prompt box becomes one box per tag in its template (Subject, Setting and so on).
- **Recent prompts**: ⌘↑ and ⌘↓ step through prompts you used before. **Image ▸ Clear Prompt History…** forgets them; images in History keep their prompts.
- Drag the handle above the prompt box to make it taller. Double-click the handle to go back to the default height.

While an image generates, the canvas shows a preview at each step. Click **Stop** or press Esc to cancel it. You can look at other images, open or paste one, or clear the canvas while it runs: the canvas then stays on what you picked, and a small live thumbnail in the status bar shows the running image. Click the thumbnail to put the canvas back on it. Finished images still save to the project and the recent strip either way. You can keep editing settings during a run; changes apply to the next one. Pressing Generate during a run queues the next image, and **×N** under Generate makes several at once (see [The queue](queue.md)).

### Layout prompts

FLUX.3, Ideogram 4 and MOSS Image can place things where you put them. With one of them picked, click **Layout** beside the prompt, above Generate:

- **Drag on the canvas** to draw a box, or click **+** in the Layout panel to add one in the middle. Drag a box to move it; the picked box has corner handles to resize it. Right-click a box, or click its trash button, to delete it.
- In the **Layout panel**, write the **Caption** (the whole image: medium, setting, light) and, for each box, what goes in it. Make a box **Text** to give the exact words to show; MOSS also has **Character**. Ideogram adds a **Background** field. FLUX.3 cites boxes in the caption by id, such as `<object_1>`: the button beside a box adds its id to the caption.
- Atelier writes the prompt in the model's own layout format as you go, so the prompt box always shows what Generate will send. Boxes follow the image size you set.
- Pasting or reusing a layout prompt while the panel is open turns it back into boxes, and opening Layout on a layout prompt shows its boxes. Switching to another of these models rewrites the layout in that model's format, keeping the boxes and descriptions.
- **Done** closes the panel. The prompt keeps the layout, so the image saves it like any prompt.

## Model

Pick a model from the **Model** menu in the toolbar. Only downloaded models are listed (see [Models and LoRAs](models-and-loras.md)). Switching models keeps your current settings. To start from the new model's recommended settings (and its default preset, if it has one), use **Reset All to Model Defaults** at the bottom of the inspector. Picking a video model makes videos on the same screen; see [Making videos](video.md).

## Run on

**Run on**, above the model at the top of the inspector, picks where new jobs go: this device, or a [paired server](remote.md). A server that doesn't answer stays listed, disabled. With a server chosen, the Model menu and LoRA picker list what that server has, so this device doesn't need the files, and a preset for a model it doesn't have shows as not available there. Generate is disabled while the server is offline or doesn't have the selected model. Results still land in this device's project, in the same place a local run would put them.

## Seed

The **Seed** row is at the top of the inspector.

- With **Random** checked, every run uses a new seed.
- To reproduce an image, uncheck **Random** and enter the seed. Same model, settings and seed give the same image (tiny pixel differences between runs are normal).
- With Random unchecked, the dice button or ⌘R rolls a new seed.

Only you change the Random checkbox. Presets, "Use Settings" and Reset never turn it on or off.

## Size

Click the size row in the inspector to open the size popover:

- **Aspect Ratio**: 1:1, 4:3, 3:4, 3:2, 2:3, 16:9, 9:16 and 21:9.
- **Megapixels**: 0.5 to 4. Larger images take longer and use more memory.
- **Width** and **Height**: type exact values. Sizes snap to multiples of 64 pixels. The swap button flips width and height.

## The settings inspector

The inspector lists the model's settings in sections: Essentials, Sampling, LoRAs, Hires Fix, Refiner, Upscaler, Image to Image and more. Show or hide it with the toolbar button or ⌥⌘I.

**On iPad**, in a window too narrow for the canvas beside the inspector, the inspector starts hidden; the toolbar button opens it over the canvas (or as a sheet in a very narrow window). In a narrow window the buttons under the prompt move below it, and the sidebar hides (its toolbar button shows it).

- **Search**: type in the search field at the top to find any setting, including hidden ones.
- **Changed**: when any setting differs from the model's defaults, a Changed group at the top lists them all, so nothing you changed is out of sight.
- **More: N**: less common settings in a section are tucked under this disclosure.
- **Settings that don't apply** to the selected model are hidden automatically (search still shows them, dimmed). Some depend on other settings too: Strategic Stochastic Sampling (SSS), the noise the TCD samplers add each step, shows only when the sampler is TCD or TCD Trailing.
- **Right-click any setting** (on iPad, touch and hold) for Reset to Default, Copy Value, and Hide from / Show in Inspector.
- **Reset All to Model Defaults** at the bottom puts everything back to the model's recommended values (and its default preset).
- Hover over any setting to see what it does.
- Setting changes can be undone with ⌘Z.

### Layouts

A layout decides which settings are shown, their order, and which sections start expanded. It never changes values. Pick one from the menu at the top of the inspector:

- **Simple**: size, steps, guidance and sampler.
- **Standard**: adds LoRAs, shift, hires fix, refiner, upscaler, strength and other common settings.
- **Video**: for video models: size, steps, guidance, sampler and length first, then LoRAs, shift, the second pass (LTX), the refiner (Wan 2.2's two experts), strength, TeaCache, Sol Attention (MiniMax H3) and tiled decoding. Settings a model doesn't use stay hidden.
- **Everything**: every setting.

From the same menu:

- **Show All Settings** shows everything temporarily. On a Mac, holding ⌥ does the same.
- **Customize Inspector…** opens a checklist of every setting by section. Uncheck settings to tuck them under More, drag to reorder, and choose which sections start expanded. Editing a built-in layout saves it as a copy named "… Custom".
- **Export Layout…**, **Import Layout…**, **Delete** and **Show Layouts Folder** manage your layouts as files.

### LoRAs

In the LoRAs section, click **Add LoRA…** to pick one. The list only offers LoRAs made for the selected model's family; turn on **Show LoRAs for other models** to see the rest. A LoRA that doesn't match the current model is marked and skipped. Many LoRAs need their trigger words in the prompt; you'll find them in the LoRAs section of the sidebar.

## Presets

A preset is a set of saved setting values. Applying one puts its values on top of the model's defaults; settings it doesn't include keep the model's own values. Presets never change the inspector layout.

Open the **Presets** menu in the toolbar:

- **Save Current Settings as Preset…**: name it, then choose:
  - **Only for [model]**: the preset is listed for this model only. Uncheck it to offer the preset for every model.
  - **Use as this model's defaults**: used by Reset, and as the baseline for the Changed group.
  - **All Current Settings** or **Changed Settings Only**. Changed Settings Only keeps the preset small and lets the model's defaults fill in the rest.
- Pick a preset from the list to apply it. Presets for other models are under **Other Models**; picking one switches to its model. If its model isn't downloaded and is in the model catalog, Atelier offers to download it, then switches and applies the preset when the download finishes; the status bar shows the progress and a way to cancel. A preset whose model can't be downloaded is listed but disabled. To use those settings on another model, switch back to it afterwards: your settings carry over.
- **Default for [model]**: choose which preset (or **Model Defaults Only**) Reset uses for a model.
- **Copy Settings as JSON** copies every setting, the model and the seed in Draw Things' configuration format. **Paste Settings** applies settings copied from Draw Things or Atelier.
- **Import Preset…**, **Export**, **Delete** and **Show Presets Folder** manage presets as files. Import Preset also takes a `custom_configs.json` exported from Draw Things, and adds each configuration in it as a preset. The name is what matches an import to a preset: one that's already here with the same settings is skipped, and when a preset with that name has other settings or another model, Atelier asks whether to **Replace** it, **Keep Both** (the import becomes “Name 2”) or **Skip** it. With more than one such preset, **Do this for all remaining conflicts** answers for the rest. If a file lists a name twice, the last one counts.

## The canvas

- Pinch, or use ⌘+ and ⌘−, to zoom. Drag to move. Double-click to switch between fit and actual size. The zoom controls are also under **View**.
- Right-click the canvas for **Show Image Full Size**, **Copy Image**, **Save Image…**, **Save to Photos**, **Open Image…**, **Open from Photos…**, **Paste Image**, **Load Settings from Image**, **Add to Moodboard**, **Match Size to Image** and **Clear Canvas**.
- **Show Image Full Size** (⌘Y, also in the **Image** menu) opens the image at full resolution in a popup. It opens at most of the main window's size, and on the Mac you can drag its edges to resize it. Pinch, use its buttons or press ⌘+ / ⌘- to zoom, drag to pan, and double-click to switch between fit and actual size. Space, Esc or **Done** closes it.

### Recent images

The strip under the canvas shows your latest images from the current project. Click one to bring back its settings and show it on the canvas; it becomes the current image, and the next image you make follows it, starting a new branch if it isn't the newest (see [History](history.md#branches)).

The two buttons at the strip's left switch what it shows: **Chronological** (clock) shows the newest images on every branch; **Current Lineage** (branch) shows the current image's line: the images it came from, and the newest images made after it. An image that more than one image follows has a small branch badge with their count. Right-click for **Use Settings**, **Use as Input**, **Add to Moodboard** and **Copy Image**. You can also drag an image from the strip into another app.

To make the canvas image larger, Control-click it and choose **Upscale…**. Pick an upscaler: an ESRGAN model from your models folder (such as 4x UltraSharp), **FlashVSR+** (up to 1920×1920, using about 34 GB of memory at that size), **Apple Super Resolution** (images up to 1920×1920 on the Mac and 1920×1080 on iPad), or a SeedVR2 model from your models folder (up to 4096×4096, using about 14 GB of memory at that size). Then pick **2×** or **4×**, or **Max** for the largest size FlashVSR+ or SeedVR2 can make at the image's shape; the sheet says when a size doesn't work. It runs in the [Queue](queue.md) on this device, and the result is a new image in History after the original, with the same settings. Only SeedVR2 loads a large diffusion model. The inspector's **Upscaler** setting is different: it upscales each new image as part of generating it.

Edit models (Fibo Edit, FLUX Kontext, Qwen Image Edit, the MOSS Edit LoRA), image to image and refines often shift an image's colors a little warmer or cooler than the image they started from. To put them back, Control-click the edited image on the canvas and choose **Match Colors to Original**. It compares the colors of the two images (in the Lab color space, as Reinhard color transfer does) and moves the edited image's color balance to the original's, leaving its brightness alone. The original is the image the edit was made from: the canvas image it was edited from, or, for an edit made only from moodboard images, the first one. The result is a new image in History after the edited one, with the same settings, and the status bar says what was taken out (positive Δb means the edit had come out warmer, positive Δa more magenta). Matching that result again goes back to the same original. It's a job in the [Queue](queue.md) on this device (whatever **Run on** says), after what's already waiting, with its progress in the status bar. It saves into the image's own project even if you open another before it runs. While it's waiting or running, the menu item is unavailable for that image: matching it again would make the same result. It's also unavailable for videos and for images that weren't made from another image.

To choose how far it goes, pick **Match Colors…** just below it instead. The sheet shows the original and a preview of the match. Above the pictures, **Side by Side** shows the two next to each other, and **Slider** shows one picture with a divider you drag across it: the original is to its left, the match to its right. The sheet can be resized on the Mac to see them larger, and it opens at that size next time (made smaller if it no longer fits the screen). Under **Match the original's** are four sliders: **Tint**, **Saturation**, **Brightness** and **Contrast**. Each goes from **Edit** to **Original**: at the Edit end that part of the picture stays as the edit made it, at the Original end it's brought all the way to the original's, and 50% is halfway. They don't go past either picture, so if the original is darker, Brightness can only darken. The line under each slider says what its Original end holds, such as "The original is darker." or "The original is slightly warmer." When the two pictures are already alike in something, its line says "Same as the original." and the slider is unavailable, since there's nothing for it to match; that's also so for Saturation when the edit is black and white, and for Contrast when it's one flat tone, since there's nothing there to stretch. Tint and Saturation start at 100% and Brightness and Contrast at 0%, which leaves the edit's light alone, as **Match Colors to Original** does. If the edit added or removed something colorful and the match comes out too vivid or too dull, lower **Saturation** and leave **Tint** where it is. **Ignore edited areas** compares the two pictures only where the edit left the picture alone, so a red coat the edit added isn't taken for the whole picture having turned red; the line under it says how much of the picture that is, and the sliders' lines follow it. It uses the parts that barely changed from the original, so an edit that recolors a backdrop is compared from the subject it kept. When less than a quarter of the picture qualifies (most of it was edited, or the whole picture shifted), or when the original has a different shape, the whole picture is compared instead, and the line says so. The preview follows the settings, and the sheet remembers what you last used. **Match** queues it like the one-click item, which always uses 100% tint and saturation, 0% brightness and contrast, and the whole image. However the sliders are set, saturation is never stretched or squeezed by more than 2× and contrast by more than 1.5×, so a very flat or very different original can't blow the colors out. A match with different settings can be queued while another for the same image is waiting; one with the same settings can't, and the sheet says so.

## Image to image

The **Generate / Edit** switch beside the prompt, above the Generate button, decides whether the canvas is sent to the model.

- **Generate** makes an image from the prompt alone. The canvas is ignored.
- **Edit** sends what's inside the frame on the canvas as the input image. Empty areas of the frame (where the image doesn't reach) are filled in, so moving or zooming the image out inside the frame extends it (outpainting). An **Input** badge on the frame tells you Edit is on.

Bringing in an image switches to Edit for you. Ways to bring one in:

- Drop an image file on the canvas.
- **Image ▸ Open Image…** (⌘O), **Open from Photos…** or **Paste Image** (⇧⌘V). A photo saved by Atelier or Draw Things keeps its settings.
- Right-click a recent image and choose **Use as Input**.

### Refining part of an image

Like Draw Things, you can redo just part of an image and have the result go back into it.

- **Pick the region** by zooming and moving the image under the frame. The frame shows what the model works on, at the output size, so zooming in on a face gives the model more pixels for it.
- **Paint a mask** to change only some of it. The tools sit in the status bar beside the zoom controls: **Move**, **Brush** and **Eraser**, the brush size (in frame pixels), **Invert Mask** and **Clear Mask**. On the Mac, drag with Brush or Eraser to paint, and hold Space while dragging to move the image. On iPad, Apple Pencil always paints (or erases, with Eraser selected) and your fingers move and zoom. Each stroke can be undone (⌘Z). Mask steps belong to the image they were made on: once another image goes on the canvas they leave the undo history (the image keeps its mask, see below), so undo never changes another image's mask. Painted areas show in red. With a mask, Edit works even at 100% Strength: the painted area is made fresh and the rest is kept.
- **Merge into Image** (the overlapping-squares button with the canvas tools in the status bar) is on by default. It's enabled when the frame is moved or zoomed to show part of the image or reach past its edges, or there's a mask. The result is then put back into the whole image: through the mask, softened by **Mask Blur** and grown by **Mask Blur Outset** (in the inspector's Image to Image section, in frame pixels as for inpainting), or without a mask, the whole frame. Where the frame's edges cross the image, the result is blended in over Mask Blur pixels so no seam shows. Parts of the image the mask doesn't reach stay exactly as they were. If the frame reaches past the image, the image grows to hold both. An image fitted in the frame with no mask isn't merged: the result is the output size, as before. Turn it off to save just what's in the frame.
- **Zoomed-in detail is kept.** When the frame is zoomed in past the image's own pixels (say 4× on a face), the region keeps the resolution it was made at, as Draw Things keeps it: it's stored as a layer with more pixels than the area it covers (a zoom within 2% of a whole number counts as that number, so 4× lands pixel for pixel; up to 8×). The image keeps its own size on the canvas and in History, and the canvas shows the extra detail when you zoom in on it. A merging run at a zoom within 2% of a whole number runs at that zoom. A masked refine keeps only the masked area (with its blur) at that detail; the rest of the image stays exactly as it was. A later refine of that image starts from the detail and keeps it, unless the new frame covers it completely. **Show Image Full Size** (⌘Y) shows the image at its finest detail, and exports use it too (see [Saved images](settings.md#saved-images)). A refine zoomed out, at 1×, or reaching past the image's edges is merged at the image's own pixels.

The mask stays on the canvas after a run, so you can refine again, and the result keeps it too. Each image remembers the last mask it had on the canvas, whether you generated with it or only painted it: put another image on the canvas and the mask goes with the old one, and it comes back whenever that image does (clicking it in History or the recent strip, Use Settings, Use as Input, from the Video Editor, and after you quit and reopen Atelier). Clearing the mask clears what the image remembers. Images dragged from History onto the canvas come in as new images, without their mask. Masks painted in Draw Things on a project's images come back the same way. Masks and merging aren't used with video models.

To use one image's mask on another, right-click it in History or the recent strip (on iPad, touch and hold) and choose **Mask ▸ Replace Canvas Mask** or **Mask ▸ Add to Canvas Mask**. **Copy Mask** and **Paste Mask** (in the Image menu, and when you right-click or touch and hold the canvas) do the same from the canvas: copy the mask from one image, put another on the canvas, and paste. A mask from an image of another size is stretched to fill this one. Each is one step to undo (⌘Z). A mask needs this device or a server running this version of Atelier or later; for an older server the mask tools are disabled, and a job with a mask is refused.

When the image grows, the corners neither the image nor the frame covered stay empty (transparent), and the next Edit fills them in. Atelier saves such a result as Draw Things saves a canvas, as layers (the image, and the frame over it), so Draw Things shows it the same way, and Atelier shows Draw Things canvases made of several layers whole.

#### Select (auto mask)

The **Select** tool (the wand, next to Brush and Eraser) makes the mask for you. Its controls appear over the bottom of the canvas while it's the tool.

- **Select Subject** picks the image's main subjects with Apple's subject detection, the one Photos uses to lift subjects. It needs no download. It finds people, animals and objects that stand out; a landscape with no clear subject selects nothing.
- **Clicks and boxes** use SAM 2.1 (Segment Anything), which downloads once: press **Download** (93.9 MB for Small) and it goes into a "SAM 2.1" folder, with progress and Cancel beside it. Atelier finds SAM in your models folder or any [additional folder](settings.md#additional-model-folders) that's connected. A download goes to the folder that already has a "SAM 2.1" folder, else your models folder, else the first additional folder Atelier can write to (not one inside another app's own storage, such as Draw Things' models folder); the Download button's help says where. If none is available, for example because the models folder's drive is disconnected, Download is disabled. Until then those controls are disabled and clicking the image does nothing. The **SAM** menu picks the size: **Small** is the default, **Tiny** is a little faster and **Large** (457 MB) a little more exact.
- On the Mac, click what you want (a green point), Option-click what to leave out (a red point), or drag a box around it. On iPad, tap with a finger or Apple Pencil, choose **+** or **−** to say whether a tap includes or leaves out, and drag a box with Apple Pencil; fingers still move and zoom. Each point refines the selection; the first click on an image takes a few seconds while SAM reads it, later ones are quick.
- The selection shows in blue, apart from the red mask. **Add** puts it into the mask, **Subtract** takes it out, **Replace** makes it the whole mask; the points are then cleared. **Clear Points** (or Esc, on the Mac) starts over. Every click, box, Clear Points and commit is a step of its own in Edit ▸ Undo (⌘Z) and Redo (⌘⇧Z), in order with brush strokes and setting changes: undoing a click selects again from the points before it, and undoing Add, Subtract or Replace takes the selection out of the mask and brings back the points it was made from, so you can keep refining it.
- If you generate while a selection is showing that you haven't added, it's added to the mask first, as **Add** does (one step to undo, the points cleared), and the run uses that mask. A selection still being worked out is waited for: the status bar says "Adding the selection…" and Generate is unavailable until it's in (up to 30 seconds; after that the run goes without it). If you put another image on the canvas or leave Edit meanwhile, that run is dropped, and the status bar says so. A selection that failed or selects nothing is left out, and the status bar says so. Queued runs take the mask as it is when you queue them, so the selection goes in then.

Select works where painting does: an image on the canvas in Edit mode, for an image model, on this device or a server that takes masks.

### Settings from an image

Images made by Draw Things carry their prompt, model, seed and settings, and so do images Atelier saves. When an image you bring in has them, the status bar says so. Images made in Atelier have them too, whether they're on the canvas after a run or picked in History or the recent strip, so you can get an image's settings back after changing the inspector. A video frame put on the canvas with **Use This Frame as Input** has the video's settings. Choose **Load Settings from Image** (canvas right-click menu, or the **Image** menu) to load the prompt, negative prompt, model, seed and every setting, on top of the model's defaults like **Paste Settings**. If the image's model isn't downloaded, the settings apply to the current model. The **Random** seed checkbox stays as it is, so with Random on the next image still gets a new seed.

After an Edit run, the result replaces the canvas and the mode stays on Edit, so you can keep refining with one click.

**Which models can edit:**

- **Edit models** such as FLUX.2 (including Klein), Kontext, Qwen Image Edit, [Fibo 2.0 Edit Turbo](models-and-loras.md#fibo-20-edit-turbo) and [MiniMax H3 Image](models-and-loras.md#minimax-h3-image) take the canvas as a reference and follow the prompt's instructions ("make it night", "add a red hat"). So does MOSS Image with a [MOSS Image Edit LoRA](models-and-loras.md#moss-image-edit-loras) on.
- **Other models** edit through **Strength** (in the Image to Image section of the inspector). Below 100%, the model starts from the canvas: lower values stay closer to it, higher values change more. At 100% the canvas is ignored, so the Edit switch is disabled until you lower Strength.

  Strength is a noise level, not a share of the steps: the run starts at the first step whose noise is at or below it, on the schedule as **Shift** bends it. With a high Shift most steps sit at high noise, so a low Strength runs very few of them (at Shift 5 with 8 steps, Strength 0.3 runs one model pass). The line under Strength says how much of the schedule a run at that Strength goes through, for example "≈1.4 of 8 steps at Shift 5"; its help gives the step it starts at and how many model passes that is. With no input image, or at 100%, it says, dimmed, that the run goes through all its steps. HyperFlow H3 Flash and MiniMax H3 Image run their own fixed schedule whatever the sampler, and the line says so, dimmed (for a moment after you pick an H3 model it says "Counting steps…" while Atelier reads which kind it is). Samplers with their own fixed timesteps, and a server's models this device doesn't have, show no line.

**Match Size to Image** (canvas right-click menu) sets the output size to the image's aspect ratio, which avoids cropping.

Areas of an image that are transparent are treated as the region to fill in. There is no mask brush yet.

## Moodboard

The **Moodboard** column on the right edge of the canvas holds reference images. Only models that take references (the edit models above, and MOSS Image with a MOSS Image Edit LoRA on) use it; with other models, such as MOSS Image on its own, it says "Not used by this model". Collapse or expand it with its own button or from the **View** menu.

- Add images by dropping them on the moodboard, with its **+** button (**Add Images…** for files, **Add from Photos…** for your photo library), or with **Add to Moodboard** from the canvas or the recent strip.
- Click an image to set its **Weight**. 0% leaves it out of the next run. For edit models such as FLUX.2, Kontext and MOSS Image Edit, any weight above 0% counts the same.
- Right-click an image for **Show on Canvas**, **Remove** and **Clear Moodboard**.

Moodboard images are sent in both Generate and Edit modes, and are kept between launches. Each image you generate saves the moodboard it used, so "Use Settings" in History brings it back.
