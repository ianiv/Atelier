# History and projects

Every image you generate is saved to the **current project**. Click **History** in the sidebar to browse it.

## Browsing

- The grid shows the current project's images, newest first.
- **Filter by prompt**: type in the search field in the toolbar.
- **Model**: show only images made with one model.
- Click an image to see its prompt, negative prompt and settings (model, size, seed, steps, guidance, shift, sampler, hires fix and more) in the panel on the right. Prompts and seeds can be selected and copied.
- Select several images with ⌘-click or ⇧-click to copy, export or delete them together.

## Reusing an image

- **Use Settings** (or double-click the image) loads the image's model, prompt, seed and every setting into Create. The seed is kept, so generating again reproduces the image. If the image was made with Edit, its input image is put back on the canvas in Edit mode as well, and its moodboard is restored.
- **Rerun with New Seed** does the same with a fresh seed, for a variation.
- If the model that made an image isn't downloaded anymore, History says so and Use Settings is unavailable.

You can also drag images from History onto the canvas or the moodboard in Create.

## Copying, exporting and deleting

Right-click an image (or use the buttons in the detail panel):

- **Copy Image**, **Copy Prompt**, **Copy Seed**.
- **Export PNG…** saves a PNG with its settings embedded, so Atelier can read them back later.
- **Delete** removes the image and its settings from the project. This can't be undone.

With several images selected, the same menu offers **Copy Images**, **Export PNGs…** and **Delete**.

## Projects

A project is one file holding a sequence of images and their settings. Use the project menu at the left of History's toolbar to:

- Switch to another project.
- **New Project…**
- **Rename** the current project.
- **Show in Finder**.

Projects are stored in `~/Pictures/Atelier/Projects/`, one `.sqlite3` file each, in the same format Draw Things uses for its projects. The first project is called "Atelier".

When you bring an image in from outside to edit it, Atelier also saves that image in the project (History doesn't list it) so the edited result can always find its input again.
