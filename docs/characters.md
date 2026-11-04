# Characters

A character is a saved, named description you build by turning knobs. Atelier writes the knobs out as plain sentences, and those sentences become the subject of any style in your library, so you can see one character in many looks.

## The screen

**Characters** in the sidebar has three parts:

- **The library**, on the left: your characters as a list or a grid of portraits, with a search field. **+** adds a character; the buttons beside it duplicate and delete the selected one. Deleting can't be undone, so export first to keep a copy.
- **The image**, in the centre: the saved image or preview you picked, with its **Saved** and **Previews** strip under it.
- **The knob panel**, on the right: the knobs, and below them, always in view, the description, the style and **Render**.

Changes save as you make them.

## The knobs

Every knob starts unset and writes nothing until you set it, so knobs that don't fit (a hair style on a robot) can simply stay unset. The character's name is never sent to the model, because models tend to draw names as text. Neither are its notes.

- **Kind** is free text ("woman", "old man", "dragon"): the noun the description is built around.
- **Sliders** step through words. The far left is unset, and the phrase beside the slider is what the model will be told.
- **Pickers** have an **Unset** choice.
- **Custom**: type your own phrase in the box beside any slider or picker ("ageless") and it replaces the knob's phrase. The knob stays in place, disabled, until you clear the box.
- **Age** also takes a number: type 35 in its Custom box and the description says "A 35-year-old woman".
- **Pronoun** sets how later sentences refer to the character (she, he, they, it). Unset repeats the kind: "The dog has…".
- **Hair or fur** and **Skin, coat or surface** have a small picker on the section header that switches their noun (fur, feathers, mane; coat, scales, shell, plating).
- Each section ends with a **free-text box** for anything the knobs don't cover; its text goes at the end of that section's sentence.

Click a section's title to fold it.

Framing, pose and setting aren't part of a character. They come from the style, from the style's tag boxes, or from Create once you send an image there.

### Randomize and locks

The dice on a section header reroll that section; **Randomize All** rerolls every section. Randomize changes only knobs that aren't locked or Custom, and can leave a knob unset. It never changes Kind, Pronoun, Accessories, the noun pickers or free text. Undo takes a roll back.

## The description

The description is one sentence for each part of the character, skipping anything unset, and updates as you turn the knobs:

> A middle-aged woman with an oval face, green eyes and a warm smile. She is tall, slender and athletic, with an upright posture. She has shoulder-length wavy auburn hair and fair, freckled skin. She wears a Victorian evening gown in deep green, with a leather satchel and a pocket watch. She has a scar through the left eyebrow.

> A young dog with a warm smile. The dog is small and sturdy. The dog has short wiry brown fur and a patched coat. The dog wears a red collar.

**Edit as Text** turns the description into text you can edit. It stops following the knobs, which stay in place, disabled. It only goes one way; Undo right after brings the knobs back.

## Rendering

The **Style** button is the same picker as on Create. The description fills the style's `{{SUBJECT}}`. Any other tag the style has, such as `{{SETTING}}`, gets a box under the button, kept with the character; an empty box takes the style's default or is left out.

**No Style** renders a neutral reference look: full body, facing the viewer, plain backdrop, even light and deep focus, with bokeh in the negative prompt.

- **Render** (⌘↩, also while typing in a knob's text box) makes one preview in the selected style.
- **Render in Styles…** lets you tick several styles (No Style among them) and renders the character in each with the same seed.
- **Render Sheet** (⇧⌘↩) makes one image showing the character several ways; see below.

Renders use what's on the Create screen when you start: the model, every inspector setting and the seed. The line above **Render** shows the model, size, steps and seed they'll use, and **Go to Create** takes you there to change them. Keep the seed and moving one knob shows only that knob's effect. Create's prompt, negative prompt, canvas and moodboard aren't used; only the style's own negative prompt is. Pick an image model on Create first, and lower the size or steps for quicker renders. The jobs run in the queue like any other, and **Stop** ends a batch and keeps what's made.

## Character sheets

A sheet is one image, from one prompt, showing the same character several ways. Pick one from the menu beside **Render Sheet**:

- **Turnaround**: front, three-quarter, side and back views, side by side on a 2:1 canvas.
- **Expressions**: six expressions in a grid, on a 3:2 canvas.
- **Poses**: standing, walking, sitting and running, on a 7:4 canvas.
- **Custom**: says what you type, on a 3:2 canvas. Pick **Custom** and the box under the menu opens (it stays greyed out for the other sheets, and Render Sheet waits until it has text). Your text continues the sentence "A character sheet: the same character shown several ways on one canvas, …", so write something like "in three outfits, side by side" or "from four camera angles, in a row". The prompt then says only that it's the same character in every view, so your text decides what else stays the same or changes. The text is kept with the character.

A sheet sets its own size from its shape and the **1 MP** or **2 MP** picker; the line above **Render** shows that size. Everything else comes from Create, whose own size isn't changed. The sheet's words wrap the description and fill the selected style's subject; with No Style it keeps the plain backdrop and deep focus, without the reference look's single full-body framing.

The result is a preview like any other. How well the views stay consistent depends on the model.

## Previews and saved images

Renders are previews only. They appear under **Previews**, aren't in any project or in History, and are cleared when you quit.

- **Save to Character** adds the preview shown to the character's saved images, under **Saved**. Saved images keep the settings they were made with.
- The **main image**, marked with a star, is the character's portrait in the library and what the screen shows when you come back. It's the first one saved until you pick another with **Make Main Image** (the star button) on a saved image.
- **Remove** (the trash button) removes a saved image. If it was the main image, the first one left takes over.
- **Send to Create** adds the preview or saved image shown to the current project, so it shows in History, and loads it on Create's canvas with the model, settings and seed it was made with, a sheet's size included. With a style, that style is selected with the description as its Subject (with a sheet's words around it) and its tag boxes filled. With No Style, the whole prompt it was made with goes in the prompt box.

## Files

**Export Selected…** and **Export All…** (the import/export menu under the library, or **Export…** in a character's right-click menu) write a `.json` characters file with the saved images. **Import Characters…** reads one; a character with the same name as one you have replaces it.

Characters are saved in `Characters.json` and each saved image (a square for the library, the full image and its settings) in `CharacterImages` in Atelier's Application Support folder.

## Adding knobs

The knobs are data. To change them, copy `CharacterKnobs.json` from inside the app (`Atelier.app/Contents/Resources`) to `CharacterKnobs.json` in Atelier's Application Support folder and edit it; Atelier reads that copy at launch, and uses its own if the copy can't be read. Sections appear in the file's order, and sentences are written in the same order:

```json
{
  "id": "faceShape",
  "title": "Face shape",
  "control": "picker",
  "role": "list",
  "format": "{a} {value} face",
  "options": ["round", "oval", { "label": "broad", "phrase": "a broad, flat face" }]
}
```

- `control`: `slider`, `picker` or `text`.
- `role`, where the knob's phrase goes in its section's sentence: `before` (an adjective before the noun), `list` (an item after "with" or "has"), `adjective` (an item after "is"), `with` (after ", with"), `head` (the noun after "wears"), `after` (after that noun), `kind` and `pronoun`.
- `format`: how a label is written. `{value}` is the label and `{a}` is a or an.
- `options`: a plain string is just a label. As an object, an option can add `phrase` (written instead of the format; `{noun}` is the section's noun), `word` (the noun when it isn't the label), `article` (takes a or an), `alone` (stands for the section's whole phrase), `after` (goes after the noun) and `plural` (takes plural verbs).
- `randomizes: false` keeps the dice off a knob.
- `numericFormat` writes a plain number in the Custom box in words (`"{value}-year-old"` for Age), and `customPrompt` is that box's placeholder.

Sheets are in the file's top-level `sheets`: each has `id`, `title`, `aspect` (width over height), and `template`, where `{{SUBJECT}}` is the description and `{{CUSTOM}}` the custom box's text with `takesText: true`.

A section has `id`, `title`, `textPrompt` and `knobs`, plus `sentence` (`opening`, `is`, `has` or `wears`) or `joinsPrevious: true` to share the sentence before it. `noun` adds the noun picker, and `separator` goes between its adjectives. The top-level `reference` holds the No Style `template` and `negative`, and `sheetTemplate`, the No Style look of a sheet.

Characters store each knob by its `id` and each choice by its label, so renaming either leaves that knob unset on existing characters.

## On iPad

The screen works the same way. In a narrow window the knob panel opens over the screen when you select a character, as the Styles editor does.
