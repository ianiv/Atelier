# The queue

On each device, Atelier makes one image at a time. Everything you ask for while an image is being made waits its turn in the **Queue**. A job sent to [another device](remote.md) doesn't hold up this one's: it runs there alongside whatever's running here, one job at a time per server.

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

A finished run on this device also shows how long each phase took: loading and encoding the prompt, encoding inputs, each sampling step, decoding (frames and soundtrack) and saving. The engine marks the end of sampling, so decoding is timed on its own; when it doesn't, the last step and decoding are shown together. The same timings are saved with the image or video (its info panel, **Timings**) and kept in the project, and agents get them from `get_job`, `list_jobs` and `get_image`.

- **Pause Queue** (toolbar) lets the current image finish, or be stopped, and then holds the rest. Click it again (**Resume Queue**) to carry on. While paused, Generate still adds to the queue; the status bar says "Paused".
- **Drag** waiting images to reorder them, or right-click one and choose **Run Next**.
- **Cancel** (right-click, or Delete) takes a waiting image out. On the running one, **Stop** works like Stop under the prompt.
- **Cancel All** (toolbar) removes every waiting image and stops the running one.
- **Retry** (on failed or cancelled images) and **Run Again** (on finished ones) queue the image again with the same settings and seed.
- **Show in History** opens a finished image in History. **Clear Finished** empties the recent list; the images stay in History.

## Jobs on another device

With a server chosen under **Run on**, a job shows here too, with the server's name beside it. Once it starts it's listed under **Running on Servers**, with **Uploading** and **Downloading** as phases of their own while its files move. Stop or Cancel stops it on the server. The status bar and canvas follow the job running on this device if there is one, then a job on a server. See [Running jobs on another device](remote.md).

On a server, a paired device's job joins the queue with that device's name beside it, and its result goes back to the device rather than into a project here. It can't be retried from here.

## Exports

An upscaled **Export Video…** (from History or the Video Editor; see [Exporting videos](video.md#exporting-videos)) is a job in the queue too, after the images already waiting. Its row shows the timeline or video's name, the method, scale, size, frames, about how long it takes (how long it took, once done), and the file it writes; while it runs, the status bar shows its progress like an image's. You can reorder it, Cancel it or Stop it like any job; a stopped export leaves no file. When it's done, **Show in Finder** (**Show in Files** on iPad) shows the file, and **Export Again** runs it again. Exports aren't kept when you quit: the file you chose is only open to Atelier until then.

## Stop

**Stop** under the prompt (or Esc) stops only the image being made; the queue goes on with the next one. To stop and hold everything, press Pause Queue first, then Stop.

## Quitting

If an image is being made, jobs are waiting or a video is exporting, Atelier asks before quitting on the Mac. A paused queue doesn't count: its jobs are kept anyway.

Waiting images, and the one being made, are kept when you quit and come back paused at the next launch. Press Resume Queue to run them. Images for a model you've since deleted are dropped.

A job that has started on a server carries on there when you quit, and Atelier collects its result the next time it can reach the server. A job still waiting here for a server, or an upscale or export running on one, isn't kept across a quit.

## On iPad

The queue keeps running when you switch away from Atelier, on iPads that can use the GPU in the background, with its progress in the system's display while you're away. You can stop it from that display, and iPadOS can stop it too: the queue pauses, the generation that was running goes back to the front to start again, and the queue resumes when you come back (if you stopped it while in Atelier, it stays paused until you resume it).

On an iPad that can't do this, or when iPadOS turns it down, the queue pauses when you switch away and resumes when you come back (unless you paused it yourself). An image that was being made when you switched away may fail; Retry runs it again. The screen stays awake while an image is being made.

## Agents

Images an agent asks for over MCP join the same queue and show a network icon. Cancelling one in the Queue cancels the agent's request. Agents' images aren't kept across a quit.
