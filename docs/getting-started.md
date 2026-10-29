# Getting started

## What you need

- A Mac with Apple silicon running macOS 27 or later. Image models are large, so more memory lets you run bigger models and keep them loaded between runs.
- Xcode, only if you build the app yourself.
- Disk space for models. A single model is typically 5 to 20 GB, so many people keep them on an external drive.
- Optional: Draw Things installed in `/Applications`. The build copies its small preview decoders from it to show sharp step-by-step previews. Without it Atelier still works and shows lower-resolution previews.

## Download and install

1. Download the latest `Atelier-<version>.zip` from [Releases](https://github.com/ianiv/Atelier/releases/latest).
2. Open the zip and drag Atelier to your Applications folder. If an older Atelier is there, replace it.

From version 0.3 on, Atelier keeps itself up to date: it checks for a new version once a day and asks before installing it. To check now, choose Atelier ▸ Check for Updates….

Release builds don't include Draw Things' preview decoders, so step-by-step previews are lower resolution than in a build made on a Mac with Draw Things installed.

## Build and install

1. Clone the repository and open a Terminal in it.
2. Run `Scripts/build.sh Release`. The first build fetches the engine packages and takes a while. The app ends up at `build/Atelier.app`.
3. If an older Atelier is in `/Applications`, move it to the Trash first. Copying over an existing app bundle breaks its code signature.
4. Copy the new app into place: `ditto build/Atelier.app /Applications/Atelier.app`.

You can also open `Atelier.xcodeproj` in Xcode and run the Atelier scheme.

Builds stay in `build/`, and the scripts keep them out of Spotlight and Open With so only the installed app shows there. If old copies still show up, run `Scripts/clean-builds.sh`. It also deletes Xcode's own build folder for Atelier. Add `--all` to delete the build caches in `build/` too, which makes the next build a full one.

### Code formatting

The Swift code is formatted with [SwiftFormat](https://github.com/nicklockwood/SwiftFormat), set up in `.swiftformat`. If you change the code, install it with `brew install swiftformat` and run `Scripts/install-hooks.sh` once: a pre-commit hook then formats the Swift files you commit. To format everything, run `swiftformat .` from the repository root.

### Code signing

You don't need an Apple developer account to build Atelier. By default the app is signed to run locally on your Mac (the settings are in `Config/Atelier.xcconfig`).

Because a locally signed app looks like a new app to macOS after each build, macOS may ask again for permissions, such as access to an external drive. To sign with your own developer team instead, create `Config/Local.xcconfig` with these two lines:

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOURTEAMID
```

Replace `YOURTEAMID` with your team ID, which is shown in Xcode under **Settings ▸ Accounts** and on the Membership page of your Apple Developer account. `Config/Local.xcconfig` is ignored by git, so your team ID stays out of the repository. Use this file rather than the Signing & Capabilities tab in Xcode, which writes the team into the project file.

## Atelier on iPad

An iPad version is in development, built from the same code as the Mac app; there's no download yet, so you build and install it from Xcode. It needs an iPad with an M1 chip or newer running iPadOS 27; how fast it generates depends on the chip and its memory.

There's no download yet; build and install it from Xcode:

1. Set your team in `Config/Local.xcconfig` (see [Code signing](#code-signing)) and sign in to your Apple account in Xcode under **Settings ▸ Accounts**. An iPad build has to be signed to install, and the first build from Xcode registers the app with the extra-memory capabilities it uses (Increased Memory Limit and Extended Virtual Addressing).
2. Connect the iPad, open `Atelier.xcodeproj`, choose your iPad as the run destination and run the Atelier scheme. From Terminal, `Scripts/build.sh Debug ipad` builds it and `Scripts/build.sh Debug ipad-sim` builds it for the iPad simulator.
3. Copy models in with the Files app: Atelier's folder under **On My iPad** has a **Models** folder. Copy the model files there from your Mac's models folder, or download models in **Models**.

On iPad:

- Images are saved in **On My iPad ▸ Atelier ▸ Atelier**, and models are in **On My iPad ▸ Atelier ▸ Models**.
- Settings is the gear button at the top of the sidebar. In **Models** and **Images**, **Choose…** picks a models or output folder anywhere Files can reach (another app's folder, iCloud Drive, an external drive), and **Use Default** goes back to Atelier's own folder. Settings shows where the folder is, and warns when a chosen folder can't be reached, for example on a disconnected drive.
- **Save to Photos** sits next to **Save Image…** on the canvas and **Export** in History.
- The queue pauses when you switch away from Atelier, because iPadOS doesn't let apps use the GPU in the background, and picks up again when you come back. The screen stays awake while an image is being made.
- Agents (the MCP server) and scripted runs are Mac only.

## Choose your models folder

Atelier uses the same model files as Draw Things. By default it looks in `~/Documents/Models` (or the folder in the `DRAWTHINGS_MODELS_DIR` environment variable, if set).

To use another folder, for example one on an external drive or the folder Draw Things already uses:

1. Open **Atelier ▸ Settings** (⌘,) and click the **Models** tab.
2. Next to **Models directory**, click **Choose…** and pick the folder, or type its path.
3. Click **Apply**.

Models you already downloaded in Draw Things show up right away, along with your imported models (`custom.json`) and LoRAs (`custom_lora.json`).

If the folder is empty, go to **Models** in the sidebar and download one. See [Models and LoRAs](models-and-loras.md).

## Make your first image

1. Click **Create** in the sidebar.
2. Pick a model from the **Model** menu in the toolbar. Atelier loads its recommended settings (steps, guidance, sampler and so on) for you.
3. Type a prompt in the box under the canvas, for example "a lighthouse at dusk, watercolor".
4. Press Return or click **Generate** (⌘↩).

The canvas shows a preview at each step and a progress bar. Press Esc or click **Stop** to cancel. When the image is done, the status bar says which project it was saved to; click **Show in History** to see it there.

For a quick test, lower **Steps** in the inspector on the right. Fewer steps is faster but rougher.

Next: [Creating images](creating-images.md).
