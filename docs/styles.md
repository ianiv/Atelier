# Styles

A style is a prompt template. Pick one on the Create screen and Generate writes your prompt into it, so you can describe just the subject ("a red fox on a mossy log") and let the style supply the medium, linework, lighting and palette. Styles are written for the model they were tuned on (the example file below is for MOSS Image), but any model can use them.

## Using a style

The **Style** button under the prompt shows the style in use, or **No Style**. Click it to search the styles by name or category and pick one; **No Style** sends the prompt as typed.

With a style selected, the prompt box shows one labelled box for each tag in the style's template, in the order they appear:

- **Subject** (`{{SUBJECT}}`) is your prompt. A template without `{{SUBJECT}}` still gets a Subject box, and the subject goes in front of the template.
- Any other tag, such as **Setting** (`{{SETTING}}`) for styles whose look depends on the environment ("a misty pine forest at dawn"), gets its own box. An empty box drops its tag from the prompt. A tag's text is kept when you switch styles, so styles that share a tag share its text.
- A style's negative prompt is added after yours.

The boxes keep only what you typed. History saves the full prompt the model got. **Use Settings**, **Rerun** and the other ways of reusing an image recognise a prompt one of your styles wrote: the boxes get their text back, with that style selected. A prompt no style wrote clears the style, so it isn't styled twice.

## The Styles screen

**Styles** in the sidebar lists your styles by category, with the start of each template. Filter them with the search field, or pick a category from the toolbar. The style Create is using has a check mark.

- **New Style** (+) adds a style and opens it in the inspector. Edit its name, category, subcategory, template, negative prompt and notes, then click **Save**.
- **Use on Create** (in the inspector, or the right-click menu) selects the style on Create and goes there.
- **Duplicate** copies a style to start a variation; **Delete** removes the selected styles (⌫ works too). Deleting can't be undone, so export first to keep a copy.
- **Import Styles…** (the toolbar's import/export menu) reads one or more style files, or drop them on the screen. A style with the same category and name as one you have replaces it.
- **Export Styles…** writes the selected styles, or all the styles the filter shows, to a style file to share or keep.

## Thumbnails

Each style can have a square thumbnail, shown in the list and the editor.

- In the editor's **Thumbnail** section: **Generate** makes one now, **Use Canvas Image** takes the image on Create's canvas, **Choose Image…** takes an image file, and **Remove** takes it away.
- The bar under the list has a box for every tag your styles use: **Thumbnail subject** ("A woman with a red umbrella walking down a rainy city street"), and others such as **Thumbnail setting**. Each style's tags take these values; an empty one is left out. **Generate** in the editor uses them too.
- To make thumbnails for many styles at once, select the styles (⇧- or ⌘-click, or ⌘A) and click **Make Thumbnails**. The bar shows which one is running; **Stop** ends the batch and keeps the thumbnails already made.

Generated thumbnails use what's on the Create screen when you start: the model, every inspector setting (size, steps, sampler, LoRAs and so on) and the seed, the same seed for every style so they compare like for like. Create's negative prompt, canvas and moodboard aren't used; only each style's own negative prompt is. Pick an image model there first, and lower the size or steps for a quicker batch. The jobs run in the queue like any other, and their images also save to the current project.

Styles are saved in `Styles.json` and thumbnails in `StyleThumbnails` in Atelier's Application Support folder. Style files don't carry thumbnails.

## Style file format

A style file is a Markdown (`.md`) or plain text file. Headings set the category and subcategory, and each style is a `###` heading followed by labelled sections:

```markdown
# Anime & Manga

## Core anime & manga looks

### Anime Style
TEMPLATE:
A clean digital anime illustration in a bright, approachable style. {{SUBJECT}} Shading is flat-to-cel, and the background is a simple pastel gradient.
NOTES:
Background invented as a simple pastel gradient.

### Ghibli Style
TEMPLATE:
A hand-painted animation-style illustration with soft gouache washes. {{SUBJECT}} {{SETTING}} The environment is rendered with patient, meticulous detail.
NEGATIVE:
photorealistic, 3D render
```

- `# Heading`: the category for the styles under it, until the next `#`.
- `## Heading`: the subcategory (optional), until the next `##` or `#`.
- `### Heading`: a style's name. Its sections follow, each a label on its own line (or with text after it on the same line) and text that runs until the next label, heading or `---` rule:
  - `TEMPLATE:` (required): the prompt template, with `{{SUBJECT}}` where the prompt goes. Any other `{{TAG}}` (letters, digits and `_`, such as `{{SETTING}}` or `{{CAMERA_ANGLE}}`) becomes a box of its own on the Create screen, labelled from its name ("Camera angle").
  - `NEGATIVE:` (optional): added to the negative prompt.
  - `NOTES:` (optional): shown in the editor only; not sent to the model.

Anything else is ignored: a title, a contents list, headings with no styles under them, and `---` rules. Labels are uppercase and must start the line. A style without a template is skipped. Export writes the same format, so exported files import back unchanged.

The file *MOSS-Image style templates by category* (`moss_templates_by_category.md`) uses exactly this format: 414 styles in 9 categories, written for MOSS Image.
