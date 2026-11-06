# Models and LoRAs

Atelier keeps models and LoRAs in your models folder (see [Settings](settings.md)), in the same layout as Draw Things, so the two apps can share one folder. It can also read models and LoRAs from [additional folders](settings.md#additional-model-folders), such as an external drive.

## Models

Click **Models** in the sidebar.

- **Show**: Downloaded, Available or All. The catalog is the Draw Things community list plus models you imported.
- **Refresh** reloads the catalog and rescans the models folder. If the community list can't be fetched, for example with no network, Atelier uses the copy it shipped with, which may not have the newest models. Refresh tries the download again.
- Select a model to see its file, family, size on disk and description, and a link to its Hugging Face page when it has one.

### Downloading

Select a model and click **Download**. Atelier also downloads the text encoders and other files the model needs. Progress shows in the list; **Cancel Download** stops it, and downloading again later resumes where it stopped.

**On iPad**, tap **Download** in the list, or touch and hold a model. Keep Atelier open until a large download finishes: in the background iPadOS may pause it. Models are saved in your models folder, by default **On My iPad ▸ Atelier ▸ Models**. You can also copy model files there from a Mac with the Files app. Large models can run on an iPad with less memory than their size: the engine loads weights as it needs them, so it may just be slower.

### Deleting

**Move to Trash** moves the model's file to the Trash. Text encoders and other files that other models share are kept. For an imported model, its entry is removed from the library too. If an imported model's file has gone missing from the folder, it says "File missing" and **Remove from Library** cleans up the entry.

### Importing a checkpoint

To use a model that isn't in the catalog, such as a fine-tune you downloaded:

1. Click **Import…** in the Models toolbar and choose one or more `.safetensors` or `.ckpt` files, or drop them on the Models list.
2. Atelier inspects each file and shows the model family it detected. Give it a name if you like, or remove a file you don't want to import.
3. Start the import. Converting a checkpoint takes a few minutes and a lot of memory; a 10 GB file can take 10 to 30 minutes.

On iPad, Import… opens the Files picker. Importing a checkpoint and Make 8-bit Copy work there too but haven't been tried on an iPad yet; converting needs a lot of memory, so a Mac is the safer place for large checkpoints.

The converted model is saved in the models folder as `<name>_f16.ckpt`, marked **Imported**, and any text encoders or VAE it needs are downloaded. It then appears in Create's model menu.

**MOSS Image fine-tunes** in OpenMOSS' layout (for example Kromoss) are converted by a dedicated importer and work like the official MOSS Image model.

Some families can't be imported yet: MiniMax H3, HiDream O1, Qwen Image 2.1, LTX-2, SeedVR2, Kandinsky, Würstchen and LongCat. Atelier tells you after inspecting the file.

### Model files Atelier can't match

Atelier only lists a model it can find in a catalog or a `custom.json`, because the file alone doesn't say which family it is. [Import from Draw Things](getting-started.md#import-from-draw-things) lists the other files in a folder, each with one of these reasons:

- **Not converted yet.** The file is an original checkpoint or LoRA, which the engine can't run as it is. **Import as Model…** or **Import as LoRA…** converts a copy, and with two or more such files, buttons above the list import them all at once.
- **Converted, but not registered.** Draw Things converted the file, but no `custom.json` in the chosen folders lists it. Draw Things usually keeps that list in its Documents folder, even for files on another drive, so add that folder first. If the file still isn't explained, choose its **Model Family**, or use **Set To** above the list to give many files the same family. When you click **Import**, Atelier adds it to the `custom.json` in the file's folder, taking its encoders and default settings from a catalog model of that family.

The file itself doesn't say what it is, so Atelier can't check your choice. If it's wrong, the model won't load or will produce noise. To change it, edit the file's entry in `custom.json`; don't use **Move to Trash**, which also trashes the model file.

If the community catalog couldn't be reached, the list says so, because it may then include models newer than the copy Atelier shipped with.

### Make 8-bit Copy (MOSS models)

An imported MOSS model is full precision and large. Atelier can write a smaller copy at about half the size. Select the model and click:

- **Make 8-bit Copy**: like Draw Things' "8-bit" models. Slow to write.
- **Make 8-bit S Copy**: like Draw Things' "8-bit S" models. These can run on the Apple Neural Engine (see Performance in [Settings](settings.md)).

The copy is saved next to the original and listed as "<name> (8-bit)" or "<name> (8-bit S)" with the same settings. Pick it in Create like any other model. Once a copy exists, its button goes away. You can keep the full-precision model or move it to the Trash.

## LoRAs

Click **LoRAs** in the sidebar. **Family** filters the list by the model family each LoRA was made for.

Converting a LoRA to 8-bit in Draw Things deletes the original file and leaves the copy without its trigger words. Atelier treats the two as one LoRA: it shows the copy, with the original's trigger words if the copy has none, and the original's name if the copy's is only its file name. A yellow warning means a LoRA's file can't be found in any models folder.

### Importing a LoRA

1. Click **Import…** and choose `.safetensors` LoRA files, or drop them on the list.
2. For each file, check the name, add its **trigger words** (the words it was trained on, which you add to your prompt to bring it in), and leave **Model family** on **Detect automatically** unless detection picks the wrong one.
3. Import. The LoRA is converted, saved in the models folder and registered in `custom_lora.json`. It's usable right away; no relaunch needed.

### Managing LoRAs

Select a LoRA to rename it or change its trigger words, then click **Save** (or **Revert**). **Reveal in Finder** (on iPad, **Show in Files**, which opens its folder) shows its file, and **Move to Trash** deletes the file and removes it from `custom_lora.json`.

To use a LoRA, add it in the inspector's LoRAs section in Create; see [Creating images](creating-images.md#loras).

Before Atelier first changes `custom.json` or `custom_lora.json` in a session, it saves a backup next to it (`custom.json.bak-atelier`, `custom_lora.json.bak-atelier`).
