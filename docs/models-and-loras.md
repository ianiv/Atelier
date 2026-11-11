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

### Choosing where new models go

With [additional model folders](settings.md#additional-model-folders), **Add To** at the bottom of the Models screen picks the folder that downloads, imported checkpoints and LoRAs, and 8-bit copies go to, so a model can land on the internal drive without moving it afterwards. The import sheets show the same choice. The free space beside it is for that folder's drive. With one models folder, **Add To** is there but can't be changed. If the chosen folder can't be reached, for example on a disconnected drive, new files go to the models folder from Settings.

- A download puts the model's text encoders, VAE and other files there too, except ones a models folder already has.
- An import is converted straight into that folder, and its `custom.json` or `custom_lora.json` entry goes in that folder's file.

### Moving between folders

With [additional model folders](settings.md#additional-model-folders), the **Folder** column shows which folder each model's file is in. To choose what lives on the internal drive and what on an external one, select a model and pick a folder from **Move To** (also in the list's context menu), then confirm.

- The model's text encoders, VAE and other files it needs move with it. A file that another model outside the destination also needs is copied instead, so that model keeps working when the other drive isn't connected. A file the destination already has stays where it is.
- An imported model's `custom.json` entry moves to the destination folder's `custom.json` (both are backed up first, as for other changes).
- Between two drives, every file is copied, read back and compared before the originals are deleted. Keep both drives connected until it finishes. Cancelling (the × beside the progress) before the copies are done leaves everything where it was. On one drive the files are just renamed, which is instant.
- A move waits for a generation in progress to finish, and generations started meanwhile wait for the move. **Move To** is unavailable while a download, import or 8-bit copy is running, while a queued job uses the model, or when there's only one models folder.

### Importing a checkpoint

To use a model that isn't in the catalog, such as a fine-tune you downloaded:

1. Click **Import…** in the Models toolbar and choose one or more `.safetensors` or `.ckpt` files, or drop them on the Models list.
2. Atelier inspects each file and shows the model family it detected. Give it a name if you like, or remove a file you don't want to import.
3. Start the import. Converting a checkpoint takes a few minutes and a lot of memory; a 10 GB file can take 10 to 30 minutes.

On iPad, Import… opens the Files picker. Importing a checkpoint and Make 8-bit Copy work there too but haven't been tried on an iPad yet; converting needs a lot of memory, so a Mac is the safer place for large checkpoints.

The converted model is saved in the folder chosen in **Add To** as `<name>_f16.ckpt`, marked **Imported**, and any text encoders or VAE it needs are downloaded. It then appears in Create's model menu.

**MOSS Image fine-tunes** in OpenMOSS' layout (for example Kromoss) are converted by a dedicated importer and work like the official MOSS Image model. To edit images with MOSS Image, add a [MOSS Image Edit LoRA](#moss-image-edit-loras).

Some families can't be imported yet: HiDream O1, Qwen Image 2.1, LTX-2, SeedVR2, Kandinsky, Würstchen and LongCat. Atelier tells you after inspecting the file.

### Fibo 2.0 Edit Turbo

[Fibo 2.0 Edit Turbo](https://huggingface.co/briaai/Fibo-2.0-edit-turbo) from Bria edits an image from an instruction ("make the sky purple", "give the fox a scarf") and also makes images from a prompt alone. It isn't in the catalog, so it has to be converted first:

- Its license is **CC BY-NC 4.0: non-commercial use only**. You accept it on Hugging Face before you can download the files.
- Hugging Face ships the model as two transformer files and a Qwen3-VL text encoder. Convert the text encoder with the engine's `ModelConverter --fibo2-text-encoder` into the models folder (it's written as `fibo_2_qwen_3_vl_4b_f16.ckpt`), merge the two transformer files into one `.safetensors`, and import that as `fibo_2_….safetensors` so the converted file is named `fibo_2_…_f16.ckpt`. It uses FLUX.2's VAE, which is downloaded if missing.
- Use **Edit** with the image on the canvas; moodboard images are sent as further images to edit. A prompt that is a JSON object with an `edit_instruction` key is passed as it is.
- It runs at 4 steps with Euler A Trailing and resolution-dependent shift, at 1024×1024 by default. It's distilled without CFG, so there's no Guidance setting and the negative prompt is ignored. LoRAs aren't supported.

### MiniMax H3 Image

[MiniMax H3 Image](https://huggingface.co/MiniMaxAI/MiniMax-H3-Image) makes images from a prompt and edits one or more pictures from an instruction, in one model. It isn't in the catalog, because it needs two manual downloads and a conversion. Atelier walks you through it:

- Its license is the **MiniMax-H3-Image Community License**, which doesn't cover use in the European Union, the United Kingdom, South Korea or the United States. Read it on Hugging Face before you download the files.
- In **Models**, show **Available** or **All**, find the **MiniMax H3 Image** row and click **Install…** (also in the row's detail and right-click menu). Once the model and its VAE are installed, the row is replaced by the installed model.
- Under **1. Download**, the two links open Hugging Face in your browser: `minimax_h3_image_pruned_bf16.safetensors` (40 GB) and `minimax_h3_image_vae_fp16.safetensors` (1.2 GB).
- Under **2. Import**, click **Choose Downloaded Files…** and pick both files. If you pick only the model, the VAE is taken from the same folder or from a `vae` folder beside it. Atelier imports the model, converts the VAE to `minimax_h3_image_vae_f16.ckpt`, and makes the copy you chose under **Install**: the [8-bit S copy](#make-8-bit-copy-moss-and-minimax-h3-models), 21 GB, which on a 48 GB Mac makes a 2048×2048 image in well under a minute where the full-precision file takes many minutes, or a 4-bit S copy, about 12 GB, for Macs with less memory, at some cost in detail. The 4-bit S copy takes a few hours to write. The text encoder is MiniMax H3's and downloads afterwards in the Models list.
- **Move the full-precision copy to the Trash afterwards** is on by default. It moves only the converted `.ckpt` Atelier wrote, never the `.safetensors` files you downloaded, which you can delete yourself once it's installed.
- The install needs about 90 GB of free space while it runs and about 50 GB afterwards (about 40 GB with 4-bit S). If it stops part way, run it again: finished steps are skipped.
- To do it by hand, import the model file with **Import…** (or drop it on the Models list), then import the VAE file the same way, then use **Make 8-bit Copy**.
- For an edit, use **Edit** with the picture on the canvas; moodboard images are sent as further pictures. The prompt calls them `<Picture 1>` (the canvas), `<Picture 2>` and so on.
- It runs at 6 steps, the only step count it was distilled for, at 2048×2048 by default; it works from about 4 to 20 megapixels and is at its best around 16 (4096×4096). For this model the size popover offers up to 16 megapixels and sides up to 6400 px. With the 8-bit S copy on a 48 GB Mac, 16 megapixels takes under two minutes and about 26 GB of memory. It's distilled without CFG, so there's no Guidance setting and the negative prompt is ignored. Sampler and Shift don't change the result.
- It expects a long, detailed English description of the whole image, so a short prompt gives a plainer picture than the examples online.
- When you edit a picture this model made, use a different seed from the one that made it. With the same seed the model reproduces the picture with harsher contrast and barely applies the edit.

### Model files Atelier can't match

Atelier only lists a model it can find in a catalog or a `custom.json`, because the file alone doesn't say which family it is. [Import from Draw Things](getting-started.md#import-from-draw-things) lists the other files in a folder, each with one of these reasons:

- **Not converted yet.** The file is an original checkpoint or LoRA, which the engine can't run as it is. **Import as Model…** or **Import as LoRA…** converts a copy, and with two or more such files, buttons above the list import them all at once.
- **Converted, but not registered.** Draw Things converted the file, but no `custom.json` in the chosen folders lists it. Draw Things usually keeps that list in its Documents folder, even for files on another drive, so add that folder first. If the file still isn't explained, choose its **Model Family**, or use **Set To** above the list to give many files the same family. When you click **Import**, Atelier adds it to the `custom.json` in the file's folder, taking its encoders and default settings from a catalog model of that family.

The file itself doesn't say what it is, so Atelier can't check your choice. If it's wrong, the model won't load or will produce noise. To change it, edit the file's entry in `custom.json`; don't use **Move to Trash**, which also trashes the model file.

If the community catalog couldn't be reached, the list says so, because it may then include models newer than the copy Atelier shipped with.

### Make 8-bit Copy (MOSS and MiniMax H3 models)

An imported MOSS or MiniMax H3 model (such as HyperFlow H3 Flash) is full precision and large. Atelier can write a smaller copy at about half the size. Select the model and click:

- **Make 8-bit Copy**: like Draw Things' "8-bit" models. Slow to write.
- **Make 8-bit S Copy**: like Draw Things' "8-bit S" models. These can run on the Apple Neural Engine (see Performance in [Settings](settings.md)).

MiniMax H3 models only offer **Make 8-bit S Copy**, the format Draw Things' own H3 files use. The copy is faster too: each step reads half as much from memory, and it leaves more room for the text encoder.

The copy is saved in the folder chosen in **Add To** and listed as "<name> (8-bit)" or "<name> (8-bit S)" with the same settings. Pick it in Create like any other model. Once a copy exists, its button goes away. You can keep the full-precision model or move it to the Trash.

## LoRAs

Click **LoRAs** in the sidebar. **Family** filters the list by the model family each LoRA was made for.

Converting a LoRA to 8-bit in Draw Things deletes the original file and leaves the copy without its trigger words. Atelier treats the two as one LoRA: it shows the copy, with the original's trigger words if the copy has none, and the original's name if the copy's is only its file name. A yellow warning means a LoRA's file can't be found in any models folder.

### Importing a LoRA

1. Click **Import…** and choose `.safetensors` LoRA files, or drop them on the list.
2. For each file, check the name, add its **trigger words** (the words it was trained on, which you add to your prompt to bring it in), and leave **Model family** on **Detect automatically** unless detection picks the wrong one.
3. Optionally change the file's **scale factor**, the number after its trigger words (see below).
4. Import. The LoRA is converted, saved in the folder chosen in **Add To** and registered in that folder's `custom_lora.json`. It's usable right away; no relaunch needed.

#### Scale factor

The scale factor multiplies the LoRA's effect and is baked into the converted file, as in Draw Things' import. 1 keeps the LoRA as trained, 0.5 halves its effect and 2 doubles it. It must be above 0.

- Trainers scale a LoRA by its alpha ÷ rank (`network_alpha` ÷ `network_dim` in kohya's scripts). When the file stores alpha, as most do, the import already applies alpha ÷ rank, so a LoRA trained at rank 32 with alpha 16 needs no change. The scale factor is applied on top of that.
- If a LoRA was trained with alpha different from rank but its file doesn't store alpha, set the scale factor to alpha ÷ rank.
- Also use it for a LoRA that's always too strong or too weak at weight 100%. The LoRA's weight in Create multiplies it the same way at generation time; the scale factor changes what 100% means, so you don't have to set the weight each time.
- To change the scale factor later, import the original file again.

### MOSS Image Edit LoRAs

LoRAs trained with the [MOSS Image Edit trainer](https://github.com/Chenkin-x/Moss-Image-Edit) turn MOSS Image into an edit model. Import the trainer's `.safetensors` file like any other LoRA: Atelier renames its tensors so the engine can read them and registers it as an edit LoRA. Pick a MOSS Image model and turn the LoRA on. It works in **Edit**, and moodboard images are references in **Generate** too:

- The canvas is the first reference image, and each moodboard image with a weight above 0% is another one after it. Weight is on or off: any weight above 0% counts the same.
- Write the change as a plain instruction ("change her shirt to bright red", "make the background a sunny beach, keep the person").
- Edits of a single image work well. Edits that combine images, such as "put the jacket from image 2 on the woman in image 1", usually give back the first image unchanged: Atelier sends every reference, but the released LoRA was trained on single-image edits. A LoRA trained on multi-image edits (the trainer supports up to 4 references) may do better.
- MOSS Image's usual steps and Guidance apply.

### Managing LoRAs

Select a LoRA to rename it or change its trigger words, then click **Save** (or **Revert**). **Reveal in Finder** (on iPad, **Show in Files**, which opens its folder) shows its file, and **Move to Trash** deletes the file and removes it from `custom_lora.json`. **Move To** moves its file to another models folder, with its `custom_lora.json` entry when that's in the same folder, the same way as [moving a model](#moving-between-folders).

To use a LoRA, add it in the inspector's LoRAs section in Create; see [Creating images](creating-images.md#loras).

Before Atelier first changes `custom.json` or `custom_lora.json` in a session, it saves a backup next to it (`custom.json.bak-atelier`, `custom_lora.json.bak-atelier`).
