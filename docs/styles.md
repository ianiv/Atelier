# Styles

A style is a prompt template. Pick one on the Create screen and Generate writes your prompt into it, so you can describe just the subject ("a red fox on a mossy log") and let the style supply the medium, linework, lighting and palette. Styles are written for the model they were tuned on (the example file below is for MOSS Image), but any model can use them.

## Using a style

The **Style** button beside the prompt (above Generate) shows the style in use, or **No Style**. Click it to search the styles by name or category and pick one; **No Style** sends the prompt as typed.

With a style selected, the prompt box shows one labelled box for each tag in the style's template, in the order they appear:

- **Subject** (`{{SUBJECT}}`) is your prompt. A template without `{{SUBJECT}}` still gets a Subject box, and the subject goes in front of the template.
- Any other tag, such as **Setting** (`{{SETTING}}`) for styles whose look depends on the environment ("a misty pine forest at dawn"), gets its own box. An empty box drops its tag from the prompt, unless the style gives the tag a default: then the box shows the default, and the prompt uses it while the box is empty. A tag's text is kept when you switch styles, so styles that share a tag share its text.
- A style's negative prompt is added after yours.
- To see or change the whole prompt, click **Edit Full Prompt** (the text-cursor button beside the style). It writes the full prompt and negative prompt into the plain prompt box and stops using the style, so you can edit any of it. It only goes one way: the edited text can't be turned back into boxes, though Undo right after brings the style back.

The boxes keep only what you typed. History saves the full prompt the model got. **Use Settings**, **Rerun** and the other ways of reusing an image recognise a prompt one of your styles wrote: the boxes get their text back, with that style selected. A prompt no style wrote clears the style, so it isn't styled twice.

## The Styles screen

**Styles** in the sidebar lists your styles by category, with the start of each template. The list/grid switch in the toolbar shows them instead as a grid of thumbnails with their names. Filter them with the search field, or pick a category from the toolbar. The style Create is using has a check mark. Select styles with a click, ⌘-click, ⇧-click, ⌘A or the arrow keys (in the grid, ← and → move along a row and ↑ and ↓ between rows). The screen keeps its filter, category, layout, selection and scroll position while you're on other screens and between launches.

- **New Style** (+) adds a style and opens it in the inspector. Edit its name, category, subcategory, template, negative prompt and notes, then click **Save**.
- **Use on Create** (in the inspector, or the right-click menu) selects the style on Create and goes there.
- **Duplicate** copies a style to start a variation; **Delete** removes the selected styles (⌫ works too). Deleting can't be undone, so export first to keep a copy.
- **Import Styles…** (the toolbar's import/export menu) reads one or more style libraries (`.html`) or Markdown style files, or drop them on the screen. A style with the same category and name as one you have replaces it; a library's thumbnails come in with its styles.
- **Export Styles…** asks which styles to export (the selected ones, or all the filter shows), a title, and a format: a style library, one `.html` file with thumbnails that also works on its own in any browser (see below), or a Markdown style file without thumbnails. The title is the library page's heading and the file's name.

## Styles from another device

With a server paired, **Styles From** on the Styles screen shows its styles, and Create's style picker lists them under its name. They work like your own but are read-only; **Copy to This Mac** or **Copy to This iPad** keeps one you can edit. See [Running jobs on another device](remote.md#using-a-servers-styles).

## Thumbnails

Each style can have a square thumbnail, shown in the list and the editor.

- **Double-click a style** in the list or grid, click its thumbnail in the list or the editor, or press **Space** with a style selected, to see its thumbnail full size: the image the thumbnail was cut from, fitted to the window. Pinch or use the zoom buttons (⌘+ and ⌘-, ⌘0 for actual size, ⌘9 to fit) to zoom, drag to pan, and double-click to switch between fit and actual size. The arrow keys move the selection as they do in the list or grid, and the viewer shows the newly selected style's thumbnail. Space, Escape or **Done** closes it. An imported library's thumbnails have only the square to show.
- In the editor's **Thumbnail** section: **Generate** makes one now, **Use Canvas Image** takes the image on Create's canvas, **Choose Image…** takes an image file, **Choose from Photos…** takes one from your photo library, and **Remove** takes it away.
- **Open in Create** (in the editor, or **Open Thumbnail in Create** in the right-click menu) puts the thumbnail's full-size image on Create's canvas and loads the model, settings, seed and prompt it was made with, the style and its tag boxes included. It works for thumbnails generated here, and for ones taken from the canvas or a file when that image's settings are known.
- The box under the list works like the Create screen's prompt box: it has a **Subject** ("A woman with a red umbrella walking down a rainy city street") and a box for each other tag the selected styles use, such as **Setting**. Each style's tags take these values; an empty one takes the style's default (`{{TAG:default}}`) or is left out. The subject can be left empty when every selected style has a default subject. **Generate** in the editor uses them too.
- To make thumbnails for many styles at once, select the styles (⇧- or ⌘-click, or ⌘A) and click **Make Thumbnails**. The bar shows which one is running; **Stop** ends the batch and keeps the thumbnails already made.

Generated thumbnails use what's on the Create screen when you start: the model, every inspector setting (size, steps, sampler, LoRAs and so on) and the seed, the same seed for every style so they compare like for like. Create's negative prompt, canvas and moodboard aren't used; only each style's own negative prompt is. Pick an image model there first, and lower the size or steps for a quicker batch. The jobs run in the queue like any other, but their images only become thumbnails: they aren't saved to a project and don't replace the image on the canvas.

Styles are saved in `Styles.json` and thumbnails (with their full-size images, and settings when they're known) in `StyleThumbnails` in Atelier's Application Support folder. Style files don't carry thumbnails.

## Style libraries

An exported style library is a single, self-contained web page: open it in any browser, on any device, with no Atelier and no internet connection. It lists the styles by category with their thumbnails, searches them, and shows only the categories you tick in the category menu at the top. Click a style to open it: fill in its tag boxes (Subject, Setting and so on) and an optional negative prompt, and copy the finished prompt and negative prompt. The page remembers your tag text, the categories you picked and which ones are collapsed.

Atelier reads the styles back from a `<script type="application/json" id="atelier-styles">` element in the page, so a library made or edited by hand imports too, even a minimal HTML file holding nothing else:

```html
<script type="application/json" id="atelier-styles">
{
  "format": "atelier-styles",
  "version": 1,
  "title": "My styles",
  "styles": [
    {
      "name": "Ghibli Style",
      "category": "Anime & Manga",
      "subcategory": "Series & studio looks",
      "template": "A hand-painted animation-style illustration. {{SUBJECT}} {{SETTING}} Soft gouache washes.",
      "negative": "photorealistic",
      "notes": "Shown in the editor only.",
      "thumbnail": "data:image/jpeg;base64,…"
    }
  ]
}
</script>
```

Only `name` and `template` are required. `thumbnail` is a JPEG or PNG `data:` URL. Inside the element, write `<\/` for any `</` in the text, as Atelier's export does, so it doesn't end the script early.

## Markdown style file format

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
- `## Heading`: the subcategory (optional), until the next `##` or `#`. A `##` with nothing after it ends the subcategory.
- `### Heading`: a style's name. Its sections follow, each a label on its own line (or with text after it on the same line) and text that runs until the next label, heading or `---` rule:
  - `TEMPLATE:` (required): the prompt template, with `{{SUBJECT}}` where the prompt goes. Any other `{{TAG}}` (letters, digits and `_`, such as `{{SETTING}}` or `{{CAMERA_ANGLE}}`) becomes a box of its own on the Create screen, labelled from its name ("Camera angle"). Write `{{TAG:default text}}` to give a tag a default, used when its box is left empty, for example `{{SETTING:a quiet street at dusk}}` or `{{SUBJECT:a woman reading by a window}}`. A default can't contain `}`. If a tag appears more than once, the first default counts.
  - `NEGATIVE:` (optional): added to the negative prompt.
  - `NOTES:` (optional): shown in the editor only; not sent to the model.

Anything else is ignored: a title, a contents list, headings with no styles under them, and `---` rules. Labels are uppercase and must start the line. A style without a template is skipped. Export writes the same format, so exported files import back unchanged.

The file *MOSS-Image style templates by category* (`moss_templates_by_category.md`) uses exactly this format: 414 styles in 9 categories, written for MOSS Image.
