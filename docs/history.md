# History and projects

Every image you generate is saved to the **current project**. Click **History** in the sidebar to browse it.

## Browsing

- The grid shows the current project's images, every branch, newest first.
- The slider in the toolbar sets the thumbnail size, and the small and large picture icons beside it step it down or up; on iPad it's the **Thumbnail Size** menu. Pinching on the grid does the same.
- Drag the edge of the detail panel on the right to make it wider or narrower.
- Press Space or ⌘Y (**Image ▸ Show Image Full Size**) to open the selected image full size, in the same popup as [Show Image Full Size](creating-images.md) in Create: zoom, pan and resize it there, and use the arrow keys to move to the next image. Space, Esc or **Done** closes it. A video opens in Quick Look instead.
- **Grid / Graph** in the toolbar switches to a graph: one row per image with its prompt, model and time, and a column of lines showing which image each one follows, so you can see where the history branches. The current image has a ring around its dot.
- **Filter by prompt**: type in the search field in the toolbar.
- **Model**: show only images made with one model.
- **Rating**: show only images with at least that many stars, or only unrated ones.
- Videos show as one tile each, with a film badge. **Images / Videos** in the toolbar shows only one kind. See [Making videos](video.md#in-history).
- **Show Inputs** in the toolbar (on iPad, in the **Filter** menu) shows or hides [input entries](#input-entries). It's on by default, and the strip under the canvas in Create follows the same setting.
- Click an image to make it the **current image** (see Branches below) and see its prompt, negative prompt and settings (model, size, seed, steps, guidance, shift, sampler, hires fix and more) in the panel on the right. Prompts and seeds can be selected and copied.
- Select several images with ⌘-click or ⇧-click to copy, export or delete them together. On iPad, tap **Select** in the toolbar, then tap images to add or remove them; tap **Done** when you're finished.
- On iPad, a tap shows an image's details and a double tap uses its settings. In a narrow window the details open over the grid and close when you're done.

## Rating images

Give an image 1 to 5 stars from the **Rating** row in the detail panel, the **Rating** submenu when you right-click it, or by pressing 1 to 5 in the grid or graph (0 clears it). Click the star an image already has to clear it. With several images selected, the submenu and keys rate them all at once. Rated images show their stars in the grid and the graph, and the image on the canvas in Create shows its rating above the generate buttons, where you can change it too.

Ratings are saved in the project, so they stay with the image when you branch from it.

## Reusing an image

- **Double-click** an image to load its model, prompt, seed and every setting into Create. The seed is kept, so generating again reproduces the image. If the image was made with Edit, its input image is put back on the canvas in Edit mode as well, with the mask the run went in with. The moodboard comes back as it was when you generated: from the run's [input entry](#input-entries) when it has one, weight-0 images included, otherwise the images the run used. For an image made by refining part of its input and merging the result back ([Refining part of an image](creating-images.md#refining-part-of-an-image)), the input comes back zoomed on the same region, with its mask. Otherwise an image comes back with the last mask it had on the canvas, as it does when you click it.
- **Use Settings** loads the same model, prompt, seed, settings and moodboard, but leaves the canvas as it is: it doesn't put the input back.
- **Rerun with New Seed** does the same with a fresh seed, for a variation.
- If the model that made an image isn't downloaded anymore, History says so and Use Settings is unavailable.

- **Mask ▸ Replace Canvas Mask** and **Mask ▸ Add to Canvas Mask** put the mask an image remembers on the image on the canvas, stretched to fill it ([Refining part of an image](creating-images.md#refining-part-of-an-image)). They're available when the image has a mask and the canvas can be painted.

You can also drag images from History onto the canvas or the moodboard in Create. A dragged image comes in as a new image, without its mask.

## Input entries

History also records what went into your runs, as Draw Things does:

- **Imported**: an image you put on the canvas (pasted, dropped, opened, picked from Photos, **Show on Canvas** from the moodboard, or placed by an agent), as you brought it in, with the moodboard at that moment.
- **Moodboard**: a change to the moodboard (adding, removing, clearing, or a new weight), with the canvas as it was. A burst of changes, or dragging a weight slider, is one entry, written about a second and a half after the last change (or straight away when you generate, put another image on the canvas, clear it, switch projects or quit).
- **Cleared**: the canvas was cleared, with the moodboard at that moment.
- **Mask**: when you generate (in Generate or Edit mode) with an image on the canvas and a mask that isn't the one the latest entry holds, the canvas, mask and moodboard go in first, and the run follows them.

Each entry holds the canvas image (none for an empty canvas), its mask and the whole moodboard, weight-0 images included. Entries show in the grid, the graph and the strip under the canvas with a badge saying which kind they are. They have no stars, settings or generation time; **Use Settings**, **Rerun with New Seed**, the rating and **Copy Prompt** / **Copy Seed** are unavailable for them, and so are **Copy Image**, **Export PNG…** and **Save to Photos** when the canvas was empty.

Click an entry (in History or the strip) to put it back: the canvas image, fitted, with its mask, and the moodboard with its weights. The prompt, settings and seed stay as they are. The entry becomes the current image, so the next image you make follows it. An entry isn't written when it would hold just what the one before it holds, so clicking an entry and changing nothing records nothing.

An entry and the images around it share their pictures in the project file: the canvas image and the moodboard images are stored once, however many entries show them. Deleting entries never removes an image another step still uses. Undo (⌘Z) isn't affected: entries are a record, not undo steps.

## Copying, exporting and deleting

Right-click an image (on iPad, touch and hold), or use the buttons in the detail panel:

- **Copy Image**, **Copy Prompt**, **Copy Seed**.
- **Export Video…** (on a video) saves it as an MP4, as it is or upscaled; see [Exporting videos](video.md#exporting-videos).
- **Export PNG…** saves a PNG with its prompt, model, seed and settings embedded, in the format Draw Things uses, so Atelier and Draw Things can read them back. Images saved from the canvas or dragged out of Atelier carry them too. You can turn this off in [Settings](settings.md#saved-images).
- **Save to Photos** adds the image to your photo library, with its settings embedded like an export. The first time, the system asks whether Atelier may add photos.
- An image with a region refined zoomed in is copied, exported, dragged and saved at the detail that region was made at, so it's larger than the image History shows, unless **Export Refined Images At** in [Settings](settings.md#saved-images) is **Image Size**.
- **Delete** removes the image and its settings from the project. This can't be undone.

With several images selected, the same menu offers **Copy Images**, **Export PNGs…** (choose a folder), **Save to Photos**, and **Delete**.

## Branches

Like Draw Things, a project keeps a branching history. The **current image** is the one you last clicked (in History or the recent strip under the canvas) or generated. The next image you make, in Generate or Edit mode, follows it:

- If the current image is the newest one, the new image simply comes after it.
- Otherwise the new image starts a new branch from it. Nothing is lost: the images that already followed it stay where they are, on their own branch.

Clicking an image changes nothing in the project except which image is current, and the project remembers that for the next time it's opened. Double-clicking an image made with Edit makes its input the current image, so generating again makes a sibling of the original. Changing the canvas or the moodboard adds an [input entry](#input-entries) after the current image, which becomes current in its place.

Deleting an image keeps its branch together: the images that followed it now follow the image before it. If you delete the current image, the one before it becomes current.

## Projects

A project is one file holding the images, their branches and their settings. Use the project menu at the left of History's toolbar to:

- Switch to another project.
- **New Project…**
- **Rename** the current project.
- **Output Folder…**: choose whether the project's new images are also saved to an output folder, and which one. **Save generated images** is **As in Settings** until you pick **On** or **Off**, and **Use a different folder for this project** sends them somewhere other than the folder in Settings. These choices are kept in the project file, so they stay with it when you rename it. See [Output folder](settings.md#output-folder).
- **Show in Finder** (on iPad, **Show in Files**).

Projects are stored in `~/Pictures/Atelier/Projects/` (on iPad, **On My iPad ▸ Atelier ▸ Atelier ▸ Projects**), one `.sqlite3` file each, in the same format Draw Things uses for its projects. The first project is called "Atelier".

When you bring an image in from outside, Atelier saves it in the project as an Imported [input entry](#input-entries), so the edited result can always find its input again. When the canvas isn't the frame's size, the frame a run was drawn from is saved too; History doesn't list it.
