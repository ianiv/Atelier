# History and projects

Every image you generate is saved to the **current project**. Click **History** in the sidebar to browse it.

## Browsing

- The grid shows the current project's images, every branch, newest first.
- **Grid / Graph** in the toolbar switches to a graph: one row per image with its prompt, model and time, and a column of lines showing which image each one follows, so you can see where the history branches. The current image has a ring around its dot.
- **Filter by prompt**: type in the search field in the toolbar.
- **Model**: show only images made with one model.
- **Rating**: show only images with at least that many stars, or only unrated ones.
- Videos show as one tile each, with a film badge. **Images / Videos** in the toolbar shows only one kind. See [Making videos](video.md#in-history).
- Click an image to make it the **current image** (see Branches below) and see its prompt, negative prompt and settings (model, size, seed, steps, guidance, shift, sampler, hires fix and more) in the panel on the right. Prompts and seeds can be selected and copied.
- Select several images with ⌘-click or ⇧-click to copy, export or delete them together. On iPad, tap **Select** in the toolbar, then tap images to add or remove them; tap **Done** when you're finished.
- On iPad, a tap shows an image's details and a double tap uses its settings. In a narrow window the details open over the grid and close when you're done.

## Rating images

Give an image 1 to 5 stars from the **Rating** row in the detail panel, the **Rating** submenu when you right-click it, or by pressing 1 to 5 in the grid or graph (0 clears it). Click the star an image already has to clear it. With several images selected, the submenu and keys rate them all at once. Rated images show their stars in the grid and the graph, and the image on the canvas in Create shows its rating above the generate buttons, where you can change it too.

Ratings are saved in the project, so they stay with the image when you branch from it.

## Reusing an image

- **Use Settings** (or double-click the image) loads the image's model, prompt, seed and every setting into Create. The seed is kept, so generating again reproduces the image. If the image was made with Edit, its input image is put back on the canvas in Edit mode as well, and its moodboard is restored.
- **Rerun with New Seed** does the same with a fresh seed, for a variation.
- If the model that made an image isn't downloaded anymore, History says so and Use Settings is unavailable.

You can also drag images from History onto the canvas or the moodboard in Create.

## Copying, exporting and deleting

Right-click an image (on iPad, touch and hold), or use the buttons in the detail panel:

- **Copy Image**, **Copy Prompt**, **Copy Seed**.
- **Export Video…** (on a video) saves it as an MP4, as it is or upscaled; see [Exporting videos](video.md#exporting-videos).
- **Export PNG…** saves a PNG with its prompt, model, seed and settings embedded, in the format Draw Things uses, so Atelier and Draw Things can read them back. Images saved from the canvas or dragged out of Atelier carry them too. You can turn this off in [Settings](settings.md#saved-images).
- **Save to Photos** (iPad only) adds the image to your photo library, with its settings embedded like an export. The first time, iPadOS asks whether Atelier may add photos.
- **Delete** removes the image and its settings from the project. This can't be undone.

With several images selected, the same menu offers **Copy Images**, **Export PNGs…** (choose a folder), **Save to Photos** on iPad, and **Delete**.

## Branches

Like Draw Things, a project keeps a branching history. The **current image** is the one you last clicked (in History or the recent strip under the canvas) or generated. The next image you make, in Generate or Edit mode, follows it:

- If the current image is the newest one, the new image simply comes after it.
- Otherwise the new image starts a new branch from it. Nothing is lost: the images that already followed it stay where they are, on their own branch.

Clicking an image changes nothing in the project except which image is current, and the project remembers that for the next time it's opened. Use Settings on an image made with Edit makes its input the current image, so generating again makes a sibling of the original.

Deleting an image keeps its branch together: the images that followed it now follow the image before it. If you delete the current image, the one before it becomes current.

## Projects

A project is one file holding the images, their branches and their settings. Use the project menu at the left of History's toolbar to:

- Switch to another project.
- **New Project…**
- **Rename** the current project.
- **Output Folder…**: choose whether the project's new images are also saved to an output folder, and which one. **Save generated images** is **As in Settings** until you pick **On** or **Off**, and **Use a different folder for this project** sends them somewhere other than the folder in Settings. These choices are kept in the project file, so they stay with it when you rename it. See [Output folder](settings.md#output-folder).
- **Show in Finder** (on iPad, **Show in Files**).

Projects are stored in `~/Pictures/Atelier/Projects/` (on iPad, **On My iPad ▸ Atelier ▸ Atelier ▸ Projects**), one `.sqlite3` file each, in the same format Draw Things uses for its projects. The first project is called "Atelier".

When you bring an image in from outside to edit it, Atelier also saves that image in the project (History doesn't list it) so the edited result can always find its input again.
