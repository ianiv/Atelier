# Creating images

The **Create** screen has three parts: the canvas in the middle, the prompt box under it, and the settings inspector on the right. The toolbar holds the model menu, the Presets menu and the inspector button.

## Prompt

Type what you want in **Describe the image…** and press Return, or click **Generate** (⌘↩). Press ⌥↩ to start a new line instead. ⌘L jumps to the prompt from anywhere.

- **Negative Prompt**: click the disclosure under the prompt to describe what to avoid. Not every model uses it.
- **Recent prompts**: ⌘↑ and ⌘↓ step through prompts you used before. **Image ▸ Clear Prompt History…** forgets them; images in History keep their prompts.
- Drag the handle above the prompt box to make it taller. Double-click the handle to go back to the default height.

While an image generates, the canvas shows a preview at each step. Click **Stop** or press Esc to cancel. You can keep editing settings during a run; changes apply to the next one.

## Model

Pick a model from the **Model** menu in the toolbar. Only downloaded models are listed (see [Models and LoRAs](models-and-loras.md)). Switching models loads that model's recommended settings, then its default preset if it has one.

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

- **Search**: type in the search field at the top to find any setting, including hidden ones.
- **Changed**: when any setting differs from the model's defaults, a Changed group at the top lists them all, so nothing you changed is out of sight.
- **More: N**: less common settings in a section are tucked under this disclosure.
- **Settings that don't apply** to the selected model are hidden automatically (search still shows them, dimmed).
- **Right-click any setting** for Reset to Default, Copy Value, and Hide from / Show in Inspector.
- **Reset All to Model Defaults** at the bottom puts everything back to the model's recommended values (and its default preset).
- Hover over any setting to see what it does.
- Setting changes can be undone with ⌘Z.

### Layouts

A layout decides which settings are shown, their order, and which sections start expanded. It never changes values. Pick one from the menu at the top of the inspector:

- **Simple**: size, steps, guidance and sampler.
- **Standard**: adds LoRAs, shift, hires fix, refiner, upscaler, strength and other common settings.
- **Everything**: every setting.

From the same menu:

- **Show All Settings** shows everything temporarily. Holding ⌥ does the same.
- **Customize Inspector…** opens a checklist of every setting by section. Uncheck settings to tuck them under More, drag to reorder, and choose which sections start expanded. Editing a built-in layout saves it as a copy named "… Custom".
- **Export Layout…**, **Import Layout…**, **Delete** and **Show Layouts Folder** manage your layouts as files.

### LoRAs

In the LoRAs section, click **Add LoRA…** to pick one. The list only offers LoRAs made for the selected model's family; turn on **Show LoRAs for other models** to see the rest. A LoRA that doesn't match the current model is marked and skipped. Many LoRAs need their trigger words in the prompt; you'll find them in the LoRAs section of the sidebar.

## Presets

A preset is a set of saved setting values. Applying one puts its values on top of the model's defaults; settings it doesn't include keep the model's own values. Presets never change the inspector layout.

Open the **Presets** menu in the toolbar:

- **Save Current Settings as Preset…**: name it, then choose:
  - **Only for [model]**: the preset is listed for this model only. Uncheck it to offer the preset for every model.
  - **Use as this model's defaults**: applied whenever you switch to this model, and used by Reset.
  - **All Current Settings** or **Changed Settings Only**. Changed Settings Only keeps the preset small and lets the model's defaults fill in the rest.
- Pick a preset from the list to apply it. Presets for other models are under **Other Models**.
- **Default for [model]**: choose which preset (or **Model Defaults Only**) a model starts with.
- **Copy Settings as JSON** copies every setting, the model and the seed in Draw Things' configuration format. **Paste Settings** applies settings copied from Draw Things or Atelier.
- **Import Preset…**, **Export**, **Delete** and **Show Presets Folder** manage presets as files.

## The canvas

- Pinch, or use ⌘+ and ⌘−, to zoom. Drag to move. Double-click to switch between fit and actual size. The zoom controls are also under **View**.
- Right-click the canvas for **Copy Image**, **Save Image…**, **Open Image…**, **Paste Image**, **Add to Moodboard**, **Match Size to Image** and **Clear Canvas**.

### Recent images

The strip under the canvas shows your latest images from the current project. Click one to bring back its settings and show it on the canvas. Right-click for **Use Settings**, **Use as Input**, **Add to Moodboard** and **Copy Image**. You can also drag an image from the strip into another app.

## Image to image

The **Generate / Edit** switch under the prompt decides whether the canvas is sent to the model.

- **Generate** makes an image from the prompt alone. The canvas is ignored.
- **Edit** sends what's inside the frame on the canvas as the input image. Empty areas of the frame (where the image doesn't reach) are filled in, so moving or zooming the image out inside the frame extends it (outpainting). An **Input** badge on the frame tells you Edit is on.

Bringing in an image switches to Edit for you. Ways to bring one in:

- Drop an image file on the canvas.
- **Image ▸ Open Image…** (⌘O) or **Paste Image** (⇧⌘V).
- Right-click a recent image and choose **Use as Input**.

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
