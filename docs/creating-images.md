# Creating images

The **Create** screen has three parts: the canvas in the middle, the prompt box under it, and the settings inspector on the right. The toolbar holds the model menu, the Presets menu and the inspector button.

## Prompt

Type what you want in **Describe the image…** and press Return, or click **Generate** (⌘↩). Press ⌥↩ to start a new line instead. ⌘L jumps to the prompt from anywhere.

- **Negative Prompt**: click the disclosure under the prompt to describe what to avoid. Not every model uses it.
- **Recent prompts**: ⌘↑ and ⌘↓ step through prompts you used before. **Image ▸ Clear Prompt History…** forgets them; images in History keep their prompts.
- Drag the handle above the prompt box to make it taller. Double-click the handle to go back to the default height.

While an image generates, the canvas shows a preview at each step. Click **Stop** or press Esc to cancel it. You can look at other images, open or paste one, or clear the canvas while it runs: the canvas then stays on what you picked, and a small live thumbnail in the status bar shows the running image. Click the thumbnail to put the canvas back on it. Finished images still save to the project and the recent strip either way. You can keep editing settings during a run; changes apply to the next one. Pressing Generate during a run queues the next image, and **×N** under Generate makes several at once (see [The queue](queue.md)).

## Model

Pick a model from the **Model** menu in the toolbar. Only downloaded models are listed (see [Models and LoRAs](models-and-loras.md)). Switching models keeps your current settings. To start from the new model's recommended settings (and its default preset, if it has one), use **Reset All to Model Defaults** at the bottom of the inspector.

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
- Pick a preset from the list to apply it. Presets for other models are under **Other Models**; picking one switches to its model. To use those settings on another model, switch back to it afterwards: your settings carry over.
- **Default for [model]**: choose which preset (or **Model Defaults Only**) Reset uses for a model.
- **Copy Settings as JSON** copies every setting, the model and the seed in Draw Things' configuration format. **Paste Settings** applies settings copied from Draw Things or Atelier.
- **Import Preset…**, **Export**, **Delete** and **Show Presets Folder** manage presets as files.

## The canvas

- Pinch, or use ⌘+ and ⌘−, to zoom. Drag to move. Double-click to switch between fit and actual size. The zoom controls are also under **View**.
- Right-click the canvas for **Copy Image**, **Save Image…**, **Open Image…**, **Paste Image**, **Load Settings from Image**, **Add to Moodboard**, **Match Size to Image** and **Clear Canvas**.

### Recent images

The strip under the canvas shows your latest images from the current project. Click one to bring back its settings and show it on the canvas; it becomes the current image, and the next image you make follows it, starting a new branch if it isn't the newest (see [History](history.md#branches)).

The two buttons at the strip's left switch what it shows: **Chronological** (clock) shows the newest images on every branch; **Current Lineage** (branch) shows the current image's line: the images it came from, and the newest images made after it. An image that more than one image follows has a small branch badge with their count. Right-click for **Use Settings**, **Use as Input**, **Add to Moodboard** and **Copy Image**. You can also drag an image from the strip into another app.

## Image to image

The **Generate / Edit** switch under the prompt decides whether the canvas is sent to the model.

- **Generate** makes an image from the prompt alone. The canvas is ignored.
- **Edit** sends what's inside the frame on the canvas as the input image. Empty areas of the frame (where the image doesn't reach) are filled in, so moving or zooming the image out inside the frame extends it (outpainting). An **Input** badge on the frame tells you Edit is on.

Bringing in an image switches to Edit for you. Ways to bring one in:

- Drop an image file on the canvas.
- **Image ▸ Open Image…** (⌘O) or **Paste Image** (⇧⌘V).
- Right-click a recent image and choose **Use as Input**.

### Settings from an image

Images made by Draw Things carry their prompt, model, seed and settings, and so do images Atelier saves. When an image you bring in has them, the status bar says so. Choose **Load Settings from Image** (canvas right-click menu, or the **Image** menu) to load the prompt, negative prompt, model, seed and every setting, on top of the model's defaults like **Paste Settings**. If the image's model isn't downloaded, the settings apply to the current model. The **Random** seed checkbox stays as it is, so with Random on the next image still gets a new seed.

After an Edit run, the result replaces the canvas and the mode stays on Edit, so you can keep refining with one click.

**Which models can edit:**

- **Edit models** such as FLUX.2 (including Klein), Kontext and Qwen Image Edit take the canvas as a reference and follow the prompt's instructions ("make it night", "add a red hat").
- **Other models** edit through **Strength** (in the Image to Image section of the inspector). Below 100%, the model starts from the canvas: lower values stay closer to it, higher values change more. At 100% the canvas is ignored, so the Edit switch is disabled until you lower Strength.

**Match Size to Image** (canvas right-click menu) sets the output size to the image's aspect ratio, which avoids cropping.

Areas of an image that are transparent are treated as the region to fill in. There is no mask brush yet.

## Moodboard

The **Moodboard** column on the right edge of the canvas holds reference images. Only models that take references (the edit models above) use it; with other models, such as MOSS, it says "Not used by this model". Collapse or expand it with its own button or from the **View** menu.

- Add images by dropping them on the moodboard, with its **+** button, or with **Add to Moodboard** from the canvas or the recent strip.
- Click an image to set its **Weight**. 0% leaves it out of the next run. For edit models such as FLUX.2 and Kontext, any weight above 0% counts the same.
- Right-click an image for **Show on Canvas**, **Remove** and **Clear Moodboard**.

Moodboard images are sent in both Generate and Edit modes, and are kept between launches. Each image you generate saves the moodboard it used, so "Use Settings" in History brings it back.
