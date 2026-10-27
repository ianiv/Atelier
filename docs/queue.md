# The queue

Atelier makes one image at a time. Everything you ask for while an image is being made waits its turn in the **Queue**.

## Queuing images

- **Generate while an image is running** adds the next one to the queue instead of waiting. The button shows a "queue" icon while something runs. Each queued image keeps the prompt, settings, seed, canvas (in Edit mode) and moodboard you had when you pressed Generate, so you can go on changing things for the next one.
- **×N under Generate** makes several images at once. With **Random** checked, each gets its own random seed. With Random unchecked, the seeds count up from the one in the Seed field (seed, seed + 1, …), as Draw Things' batch count does. The Seed field and the Random checkbox stay as they are.
- In Edit mode, an image queued while another runs starts from the canvas as it was before the running image's previews covered it.

The status bar under the canvas shows how many images are waiting ("3 waiting"). Click it to open the Queue. The **Queue** item in the sidebar shows the count too.

## Where results go in History

Images queued one after another form a line: each follows the image before it, as if you had pressed Generate after each one finished. That holds even if you reorder the queue or cancel some of it. If you click another image (making it the current step) before queuing more, the new ones branch from that image instead. Edit images always follow the image they edit.

Results are saved to the project that's open when they finish.

## The Queue screen

The list has three parts: the image being made, the waiting images and recent ones (finished, failed or cancelled). Each row shows the prompt, model, size, seed and steps, with the result's thumbnail once it's done; recent ones show how long they took. Videos show their length and a film icon.

- **Pause Queue** (toolbar) lets the current image finish, or be stopped, and then holds the rest. Click it again (**Resume Queue**) to carry on. While paused, Generate still adds to the queue; the status bar says "Paused".
- **Drag** waiting images to reorder them, or right-click one and choose **Run Next**.
- **Cancel** (right-click, or Delete) takes a waiting image out. On the running one, **Stop** works like Stop under the prompt.
- **Cancel All** (toolbar) removes every waiting image and stops the running one.
- **Retry** (on failed or cancelled images) and **Run Again** (on finished ones) queue the image again with the same settings and seed.
- **Show in History** opens a finished image in History. **Clear Finished** empties the recent list; the images stay in History.

## Exports

An upscaled **Export Video…** (from History or the Video Editor; see [Exporting videos](video.md#exporting-videos)) is a job in the queue too, after the images already waiting. Its row shows the timeline or video's name, the method, scale, size, frames, about how long it takes (how long it took, once done), and the file it writes; while it runs, the status bar shows its progress like an image's. You can reorder it, Cancel it or Stop it like any job; a stopped export leaves no file. When it's done, **Show in Finder** (**Show in Files** on iPad) shows the file, and **Export Again** runs it again. Exports aren't kept when you quit: the file you chose is only open to Atelier until then.

## Stop

**Stop** under the prompt (or Esc) stops only the image being made; the queue goes on with the next one. To stop and hold everything, press Pause Queue first, then Stop.

## Quitting

Waiting images, and the one being made, are kept when you quit and come back paused at the next launch. Press Resume Queue to run them. Images for a model you've since deleted are dropped.

## On iPad

The queue pauses when you switch away from Atelier, because iPadOS doesn't let apps use the GPU in the background, and resumes when you come back (unless you paused it yourself). An image that was being made when you switched away may fail; Retry runs it again. The screen stays awake while an image is being made.

## Agents

Images an agent asks for over MCP join the same queue and show a network icon. Cancelling one in the Queue cancels the agent's request. Agents' images aren't kept across a quit.
