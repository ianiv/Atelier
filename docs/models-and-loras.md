# Models and LoRAs

Atelier keeps models and LoRAs in your models folder (see [Settings](settings.md)), in the same layout as Draw Things, so the two apps can share one folder.

## Models

Click **Models** in the sidebar.

- **Show**: Downloaded, Available or All. The catalog is the Draw Things community list plus models you imported.
- **Refresh** reloads the catalog and rescans the models folder.
- Select a model to see its file, family, size on disk and description, and a link to its Hugging Face page when it has one.

### Downloading

Select a model and click **Download**. Atelier also downloads the text encoders and other files the model needs. Progress shows in the list; **Cancel Download** stops it, and downloading again later resumes where it stopped.

### Deleting

**Move to Trash** moves the model's file to the Trash. Text encoders and other files that other models share are kept. For an imported model, its entry is removed from the library too. If an imported model's file has gone missing from the folder, it says "File missing" and **Remove from Library** cleans up the entry.

### Importing a checkpoint

To use a model that isn't in the catalog, such as a fine-tune you downloaded:

1. Click **Import…** in the Models toolbar and choose one or more `.safetensors` or `.ckpt` files, or drop them on the Models list.
2. Atelier inspects each file and shows the model family it detected. Give it a name if you like, or remove a file you don't want to import.
3. Start the import. Converting a checkpoint takes a few minutes and a lot of memory; a 10 GB file can take 10 to 30 minutes.

The converted model is saved in the models folder as `<name>_f16.ckpt`, marked **Imported**, and any text encoders or VAE it needs are downloaded. It then appears in Create's model menu.

**MOSS Image fine-tunes** in OpenMOSS' layout (for example Kromoss) are converted by a dedicated importer and work like the official MOSS Image model.

Some families can't be imported yet: MiniMax H3, HiDream O1, Qwen Image 2.1, LTX-2, SeedVR2, Kandinsky, Würstchen and LongCat. Atelier tells you after inspecting the file.

### Make 8-bit Copy (MOSS models)

An imported MOSS model is full precision and large. Atelier can write a smaller copy at about half the size. Select the model and click:

- **Make 8-bit Copy**: like Draw Things' "8-bit" models. Slow to write.
- **Make 8-bit S Copy**: like Draw Things' "8-bit S" models. These can run on the Apple Neural Engine (see Performance in [Settings](settings.md)).

The copy is saved next to the original and listed as "<name> (8-bit)" or "<name> (8-bit S)" with the same settings. Pick it in Create like any other model. Once a copy exists, its button goes away. You can keep the full-precision model or move it to the Trash.

## LoRAs

Click **LoRAs** in the sidebar. **Family** filters the list by the model family each LoRA was made for.

### Importing a LoRA

1. Click **Import…** and choose `.safetensors` LoRA files, or drop them on the list.
2. For each file, check the name, add its **trigger words** (the words it was trained on, which you add to your prompt to bring it in), and leave **Model family** on **Detect automatically** unless detection picks the wrong one.
3. Import. The LoRA is converted, saved in the models folder and registered in `custom_lora.json`. It's usable right away; no relaunch needed.

### Managing LoRAs

Select a LoRA to rename it or change its trigger words, then click **Save** (or **Revert**). **Reveal in Finder** shows its file, and **Move to Trash** deletes the file and removes it from `custom_lora.json`.

To use a LoRA, add it in the inspector's LoRAs section in Create; see [Creating images](creating-images.md#loras).

Before Atelier first changes `custom.json` or `custom_lora.json` in a session, it saves a backup next to it (`custom.json.bak-atelier`, `custom_lora.json.bak-atelier`).
