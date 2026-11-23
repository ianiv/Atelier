# Editing images

The **Edit** screen (below History in the sidebar) finishes an image without a model: a crop, film grain, color matching to a reference, a grade, a 3D LUT, halation, lens blur and a vignette. Its grain imitates a real camera's noise, and looks can be kept as `.grain.json` noise profiles. Editing is non-destructive: the screen always renders the image you opened with the current settings, and an edit saved to History remembers its settings, so you can open it again and change them.

Edit works on images, not videos.

## Opening an image

- **Open in Edit**, when you right-click an image in History or on the Create screen's canvas, brings that step here.
- **Open Image…** and **Open from Photos…** (toolbar) open a file or a photo, and you can drop an image on the screen: a file, or a picture dragged from Photos or a browser.
- **Use Canvas Image** (toolbar) takes the image on the Create screen's canvas: its step when it's one, or the image itself.

The image's name is in the bottom bar ("Project, step 12", or the file's name). The screen keeps the image and its look while you switch to other screens, and comes back to the same step at the next launch.

## Tools

The picker at the left of the bottom bar chooses what a drag on the image does:

- **Move** drags the image around (when you're zoomed in).
- **Crop** draws the crop over the whole image.

Crop and the other tools act in a single picture: choosing one while **Side by Side** or **Slider** is on switches the comparison to **Hold for Original**, and choosing Side by Side or Slider goes back to Move.

## Crop

With **Crop** chosen the screen shows the whole image fitted, with the crop rectangle over it and the part outside it dimmed. Drag a corner or an edge to resize it, drag inside to move it, or drag outside it to draw a new one; a grid of thirds shows while you drag. Pinch to zoom, and on the Mac hold Space and drag to move the image. Choosing another tool applies the crop: the screen then shows the cropped picture with the look.

The bar over the bottom of the image holds:

- **Aspect**: **Free**, **Original** (the image's own ratio), or 1:1, 4:5, 2:3, 3:4, 9:16 or 16:9. Choosing a ratio holds the crop to it, keeping its center; with no crop it takes the largest crop of that ratio. Corners then keep the ratio as you drag.
- **Orientation** turns the ratio on its side (4:5 to 5:4). It's unavailable for Free and 1:1.
- The crop's size in pixels.
- **Reset Crop** takes the crop off.

Crops are in whole pixels, at least 16 on a side, anywhere in the image (not snapped to 64). Each finished drag, ratio change and Reset Crop is one step of **Undo** (⌘Z), named Crop or Reset Crop. The bottom bar's **Reset** resets the look only and leaves the crop.

The crop goes on before the look, so the vignette centers on the cropped picture, the grain is sized to the cropped frame (as grain.py gives a cropped file), and the matches measure what's in the frame. Blur, smear and halation near the crop's edge read the edge's own pixels rather than what's beyond it. While Crop is chosen the look is drawn over the whole image, so its vignette is the whole image's until you leave Crop.

The crop belongs to the image, not the look: opening another image starts with none, and profiles never hold one. The screen keeps the crop of the step it has open across a quit, saved or not.

## The look

The inspector's sections are in the order the look is applied: lens smear and blur, the matches, the grade, the LUT, halation, the vignette, then the grain. Every control is always there; one that can't do anything yet (Match Reference without a reference, Real Noise without a profile that has real noise) is unavailable, with a line saying what it needs.

### Look

- **Profile** picks a grain profile from your library: its grain settings, blur and colour settings go on the screen, and its grain data (the reference's brightness curve, colors and real noise) goes with them. The seed stays the screen's. **None** clears the grain data and keeps the settings.
- **Open Profile…** opens a `.grain.json` file from anywhere; **Save Profile…** saves the current settings as one anywhere; **Add to Library** adds the current look to the library (numbered, "Night 2", when the name is taken). The library is the folder Application Support/Atelier/Grain Profiles. A profile is a look, so it doesn't keep a seed.
- **Reference** picks an image the matches move toward: **Choose File…**, **From Photos…**, **Step's Input**, a **Moodboard** picture, or **Choose History Step…**.
- **Match Reference** measures the reference's grain and takes it on: grain strength and size, colour noise and colour size, the brightness curve, the reference's colors at **Profile Colour** 0.6, and its real noise. The line below says how close it came: the reference's grain shape and colour blotches beside the matched grain's. It needs a reference with a flat, mid-bright area to measure; the result is the profile until you pick another, and **Add to Library** keeps it.

### Match

**Match to** picks **Reference** or **Step's Input** (the image the step was made from, such as the picture an image-to-image or inpainting edit started from). Each is disabled when there's nothing to match to: Reference until you choose one, Step's Input for a step that wasn't made from an image. **Tint**, **Saturation**, **Brightness** and **Contrast** move the image's colors toward the target's, as Match Colors… does, from 0% (leave it) to 100%. **Histogram** reshapes the image's tones to the target's, of **Luma** (the default, which keeps the image's own colors) or **RGB** (each channel on its own, which can move hues). **Profile Colour** is how far each color channel's average and spread move to the profile's reference.

### Grade

**Exposure** (in stops), **Temperature**, **Tint** (green to magenta), **Contrast**, **Saturation** and **Vibrance** (saturation that moves muted colors more than vivid ones), applied in that order.

### LUT

The **LUT** menu picks **None**, one of the built-in looks below, or the LUT you loaded from a file, listed under them; choosing one keeps the **Strength**. **Load .cube…** applies a 3D LUT in the Adobe/Resolve `.cube` format at full **Strength**; **Remove** takes it off and drops the file's LUT from the menu. Sizes 2 to 129 are read, with `DOMAIN_MIN`/`DOMAIN_MAX`; 1D LUTs aren't.

#### Built-in LUTs

Atelier's own looks, written from scratch (sRGB in and out):

- **Warm Film**: lifted blacks, a gentle S-curve, cool shadows and warm highlights, tamed greens.
- **Teal and Orange**: a firmer S-curve, teal shadows and orange highlights, a little warmth on skin.
- **Faded Matte**: strongly lifted blacks and dimmed whites, soft contrast, muted color.
- **Punchy Slide**: a strong S-curve with richer reds, yellows and blues, like slide film.
- **Bleach Bypass**: half the saturation and a hard S-curve, for a gritty, silvery look.
- **Sodium Night**: crushed blacks, cyan-green shadows and an orange street-light cast.
- **Cool Phone Night**: slightly lifted shadows, a cool white balance and a little more color.
- **Golden Hour**: a warm white balance, warm split toning and a light S-curve.
- **Tri-X Mono**: black and white through a red filter's weights, with strong contrast.
- **Cross Process**: contrasty reds, slightly brighter greens and lifted, flattened blues.

A step saved with a built-in keeps its table, so it renders the same even if a later version of Atelier changes the look.

**Export LUT…** bakes the matches, the grade and the LUT, as they are for this image, into a 33³ `.cube` for other apps. Blur, halation, the vignette and the grain aren't in it: they depend on where a pixel is, which a LUT can't hold. The baked LUT is within about 2 levels of the screen inside the colors it can hold, and up to 4 near clipping; a strong luma histogram match is too steep near black for 33 steps and comes out softer there.

### Halation

A warm glow around highlights, as film gives. Only the light brighter than **Threshold** glows, and the further a highlight is past it the stronger its glow, so something just over the threshold barely glows. The glow shows against darker surroundings, strongest just outside a bright edge, and hardly changes the highlight itself or other bright areas. **Amount** sets how strong it is, **Radius** how far it spreads, and **Warmth** goes from the highlight's own color to film's red-orange.

### Lens

**Motion** is a slow-shutter smear (in pixels at full size, from 2) along **Angle**; **Blur** softens the image before the grain (default 3). The smear repeats the edge pixels at the borders, where grain.py wraps around.

### Vignette

**Amount** darkens the corners, or lightens them below 0; **Size** sets where the falloff starts and **Softness** how gradual it is.

### Grain

**Grain** (strength), **Size**, **Colour Noise** and **Colour Size** are the random grain. **Real Noise** adds the profile's real noise, copied from its reference photo, at 1 for the reference's amount. **Seed** picks the grain pattern, and **New Grain** rolls a new one. The grain follows the profile's brightness curve and scales with its reference's width.

**Reset** (bottom bar) goes back to the default look (blur 3, grain 9, colour noise 3) with no profile, reference or LUT, keeping the seed.

## Comparing and zooming

The bottom bar's comparison picks how you see the original:

- **Hold for Original** shows the edit; press and hold the **Hold for Original** segment itself to see the original in its place until you let go. A click just picks the mode. With VoiceOver, once Hold for Original is picked, the segment's action turns the original on and off.
- **Side by Side** shows the original and the edit next to each other.
- **Slider** shows one picture with a divider you drag across it. It shows the whole image only.

With a crop, the original is cropped the same way, so the two line up.

Zoom with the − and + buttons, ⌘+ and ⌘−, a pinch, or the zoom menu (**Zoom to Fit**, **Zoom to Fill**, actual size); drag to move around, and double-click for actual size or to fit. At 100% and above the screen renders only what's visible, at full detail, so the grain you see is the grain you'll save. While you pinch or drag, the preview you had moves and scales with you, and parts you've already seen at that zoom show as they come into view; the rest renders sharp once you let go. When a render takes more than a moment, a small spinner shows in the preview's corner while the last preview stays up; changing a setting again stops a render that's under way.

## Saving

- **Save to History** renders the image at full size with the crop and the look and saves it as a new step after the image it was opened from, with that step's settings. The new step is the crop's size; its input stays the whole image. It's a job in the [Queue](queue.md) on this device, after what's already waiting, and saves into the image's own project even if you open another before it runs. While it's waiting or running, saving the same look again is unavailable: it would make the same image.
- **Add to History** is for an image opened from a file or Photos: it puts the image in the current project as an Imported [input entry](history.md#input-entries) and saves the edit after it.
- **Export…** saves the edit at full size as a PNG, without the queue (cropped, even while Crop is chosen). For a step it carries the step's settings and the edit's, as History's exports do (unless Settings turns that off).

A project records image sizes in steps of 64 pixels, as Draw Things does, so History lists an edit of a 1600×1200 image as 1600×1152.

### Opening an edit again

A step saved from Edit records its look and its crop: the settings, the profile's name, grain data and real noise, the reference's measurements, and the LUT's table. Opening it in Edit goes back to the whole image it was made from with that look and crop, so you can change the settings or the crop rather than add grain over grain or crop a crop. The data is kept in the project, so the step can be opened again exactly even if the profile, reference or LUT file is gone; steps that share a profile or LUT share one copy. If the image it was made from has been deleted, the edit itself opens. An older Atelier opening a cropped edit shows the whole image with the look. If some of the step's data is gone from the project (its real noise, its reference's histograms or its LUT), only the setting that needs it is turned off, and the screen says which.

## On iPad

The inspector is a panel beside the image, as in the Video Editor. The **Hold for Original** segment is pressed and held with a finger; pinch to zoom. With Crop, one finger moves the crop's handles; choose Move to drag the image. The profile library lives in Atelier's own storage; use **Open Profile…** and **Save Profile…** to move profiles to and from Files.

## Agents

On the Mac, agents can give an image a look with `edit_image_look`, crop it with `crop_image`, list your profiles with `list_grain_profiles`, and measure a reference with `measure_reference`. See [Atelier for agents](../MCP.md).
