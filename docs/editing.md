# Editing images

The **Edit** screen (below History in the sidebar) finishes an image without a model: film grain, color matching to a reference, a grade, a 3D LUT, halation, lens blur and a vignette. Its grain is a port of grain.py and Grain Studio, and it reads and writes their `.grain.json` noise profiles. Editing is non-destructive: the screen always renders the image you opened with the current settings, and an edit saved to History remembers its settings, so you can open it again and change them.

Edit works on images, not videos.

## Opening an image

- **Open in Edit**, when you right-click an image in History or on the Create screen's canvas, brings that step here.
- **Open Image…** and **Open from Photos…** (toolbar) open a file or a photo, and you can drop an image file on the screen.
- **Use Canvas Image** (toolbar) takes the image on the Create screen's canvas: its step when it's one, or the image itself.

The image's name is in the bottom bar ("Project, step 12", or the file's name). The screen keeps the image and its look while you switch to other screens, and comes back to the same step at the next launch.

## The look

The inspector's sections are in the order the look is applied: lens smear and blur, the matches, the grade, the LUT, halation, the vignette, then the grain. Every control is always there; one that can't do anything yet (Match Reference without a reference, Real Noise without a profile that has real noise) is unavailable, with a line saying what it needs.

### Look

- **Profile** picks a grain profile from your library: its grain settings, blur and colour settings go on the screen, and its grain data (the reference's brightness curve, colors and real noise) goes with them. The seed stays the screen's. **None** clears the grain data and keeps the settings.
- **Open Profile…** opens a `.grain.json` file from anywhere; **Save Profile…** saves the current settings as one anywhere; **Add to Library** adds the current look to the library (numbered, "Night 2", when the name is taken). The library is the folder Application Support/Atelier/Grain Profiles. Profiles Atelier writes load in grain.py and Grain Studio, and theirs load here. A profile is a look, so it doesn't keep a seed.
- **Reference** picks an image the matches move toward: **Choose File…**, **From Photos…**, **Original of This Step**, a **Moodboard** picture, or **Choose History Step…**.
- **Match Reference** measures the reference's grain the way `grain.py --match` does and takes it on: grain strength and size, colour noise and colour size, the brightness curve, the reference's colors at **Profile Colour** 0.6, and its real noise. The line below says how close it came: the reference's grain shape and colour blotches beside the matched grain's. It needs a reference with a flat, mid-bright area to measure; the result is the profile until you pick another, and **Add to Library** keeps it.

### Match

**Match to** picks **Reference** or **Original** (the image the step was made from, as [Match Colors…](creating-images.md) uses). **Tint**, **Saturation**, **Brightness** and **Contrast** move the image's colors toward the target's, as Match Colors… does, from 0% (leave it) to 100%. **Histogram** reshapes the image's tones to the target's, of **Luma** (the default, which keeps the image's own colors) or **RGB** (each channel on its own, which can move hues). **Profile Colour** is grain.py's `colour`: how far each color channel's average and spread move to the profile's reference.

### Grade

**Exposure** (in stops), **Temperature**, **Tint** (grain.py's green to magenta), **Contrast**, **Saturation** and **Vibrance** (saturation that moves muted colors more than vivid ones), applied in that order.

### LUT

**Load .cube…** applies a 3D LUT in the Adobe/Resolve `.cube` format at full **Strength**; **Remove** takes it off. Sizes 2 to 129 are read, with `DOMAIN_MIN`/`DOMAIN_MAX`; 1D LUTs aren't.

**Export LUT…** bakes the matches, the grade and the LUT, as they are for this image, into a 33³ `.cube` for other apps. Blur, halation, the vignette and the grain aren't in it: they depend on where a pixel is, which a LUT can't hold. The baked LUT is within about 2 levels of the screen inside the colors it can hold, and up to 4 near clipping; a strong luma histogram match is too steep near black for 33 steps and comes out softer there.

### Halation

A warm glow around highlights, as film gives. **Amount** sets how strong it is, **Threshold** how bright light must be to glow, **Radius** how far it spreads, and **Warmth** goes from the highlight's own color to film's red-orange.

### Lens

**Motion** is a slow-shutter smear (in pixels at full size, from 2) along **Angle**; **Blur** softens the image before the grain (grain.py's default 3). The smear repeats the edge pixels at the borders, where grain.py wraps around.

### Vignette

**Amount** darkens the corners, or lightens them below 0; **Size** sets where the falloff starts and **Softness** how gradual it is.

### Grain

**Grain** (strength), **Size**, **Colour Noise** and **Colour Size** are grain.py's random grain. **Real Noise** adds the profile's real noise, copied from its reference photo, at 1 for the reference's amount. **Seed** picks the grain pattern, and **New Grain** rolls a new one. The grain follows the profile's brightness curve and scales with its reference's width.

**Reset** (bottom bar) goes back to grain.py's default look (blur 3, grain 9, colour noise 3) with no profile, reference or LUT, keeping the seed.

## Comparing and zooming

The bottom bar's comparison picks how you see the original:

- **Hold for Original** shows the edit; press and hold **Hold to See Original** to see the original in its place.
- **Side by Side** shows the original and the edit next to each other.
- **Slider** shows one picture with a divider you drag across it. It shows the whole image only.

Zoom with the − and + buttons, ⌘+ and ⌘−, a pinch, or the zoom menu (**Zoom to Fit**, **Zoom to Fill**, actual size); drag to move around, and double-click for actual size or to fit. At 100% and above the screen renders only what's visible, at full detail, so the grain you see is the grain you'll save.

## Saving

- **Save to History** renders the image at full size with the look and saves it as a new step after the image it was opened from, with that step's settings. It's a job in the [Queue](queue.md) on this device, after what's already waiting, and saves into the image's own project even if you open another before it runs. While it's waiting or running, saving the same look again is unavailable: it would make the same image.
- **Add to History** is for an image opened from a file or Photos: it puts the image in the current project as an Imported [input entry](history.md#input-entries) and saves the edit after it.
- **Export…** saves the edit at full size as a PNG, without the queue. For a step it carries the step's settings and the edit's, as History's exports do (unless Settings turns that off).

A project records image sizes in steps of 64 pixels, as Draw Things does, so History lists an edit of a 1600×1200 image as 1600×1152.

### Opening an edit again

A step saved from Edit records its look: the settings, the profile's name, grain data and real noise, the reference's measurements, and the LUT's table. Opening it in Edit goes back to the image it was made from with that look, so you can change the settings rather than add grain over grain. The data is kept in the project, so the step can be opened again exactly even if the profile, reference or LUT file is gone; steps that share a profile or LUT share one copy. If the image it was made from has been deleted, the edit itself opens.

## On iPad

The inspector is a panel beside the image, as in the Video Editor. **Hold to See Original** is pressed and held with a finger; pinch to zoom. The profile library lives in Atelier's own storage; use **Open Profile…** and **Save Profile…** to move profiles to and from Files.

## Agents

On the Mac, agents can give an image a look with `edit_image_look`, list your profiles with `list_grain_profiles`, and measure a reference with `measure_reference`. See [Atelier for agents](../MCP.md).
