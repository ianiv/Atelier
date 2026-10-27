# Putting videos together

**Timeline**, in the sidebar after History, puts a project's videos in order to make one longer video. Edits never change or copy the videos themselves: a timeline is a list of which part of which video plays when, saved in the project file. From any frame on a timeline you can start a new video, and it comes back onto the timeline right after that frame.

## The screen

- **The viewer**, at the top, plays the whole timeline with sound. Click it, or press Space, to play or pause. The bar under it steps a frame back or forward, shows the time and which clip and frame are under the playhead, and has Loop and Mute.
- **The track**, at the bottom, shows the timeline's clips end to end, each as a strip of its frames. The red line is the playhead: click or drag along the ruler or the track to move it. A speaker marks a clip with sound, a crossed-out speaker a muted one, and a half-filled circle a crossfade into the next clip.
- **Videos**, in the column on the right, lists the project's videos, newest first. Drag one into the track to put it there, or double-click it to add it at the end. Moving the pointer across a video scrubs through it, as in History.

The menu at the top left picks the timeline when the project has more than one, and has **New Timeline**, **Rename…** and **Delete…**. Deleting a timeline leaves its videos in History.

**Add to Timeline**, on a video's menu in History and in its detail panel, adds it to the end of the timeline last open in Timeline (making one if there's none).

## Editing

- **Move** a clip by dragging it along the track.
- **Trim** a clip by dragging its left or right edge. It moves a frame at a time and can't go past the video's own first or last frame.
- **Split at Playhead** (⌘B, or the scissors) cuts the clip under the playhead in two there.
- Right-click a clip for **Mute**, **Crossfade into Next** (from 4 to 48 frames), **Duplicate**, **Show in History** and **Remove from Timeline**. Delete also removes the selected clip.

Every edit can be undone with ⌘Z.

**Timeline Settings** (the sliders button) sets the size and frame rate it plays and exports at. Both start as the first clip's. Clips of another size are scaled to fit inside, on black; clips at another frame rate play at their own speed.

## Starting a new video from a frame

Right-click the viewer for the frame under the playhead, or a clip in the track (for the frame under the playhead when it's on that clip, otherwise the clip's last frame):

- **Continue from Here** puts the frame on the canvas in Create, in Edit mode, as **Use This Frame as Input** does, and switches to Create. Change the prompt or settings if you like and press Generate. When the video finishes, it goes on the timeline right after that frame: the clip you started from now ends there, and the new video's first frame, which repeats the one you picked, is left out so the join doesn't stutter. The rest of the old clip is still in Videos; drag it back if you want it.
- **Bridge to Next Clip**, with MiniMax H3 FL2VA selected in Create, also puts the next clip's first frame at the front of the moodboard as the frame the video ends on. The result goes between the two clips.
- **Use This Frame as Input**, **Copy Frame** and **Add Frame to Moodboard** work as they do on a video in Create, and put nothing on the timeline.

Only the first video made from that Generate goes on the timeline; with ×2 or more, the others are in Videos to swap in. Where the video goes is kept with the queued job, so it still lands in the right place after Pause, reordering or quitting with jobs waiting. If the clip it started from was removed meanwhile, the video goes at the end.

## Exporting

**Export** writes the timeline as one MP4, in the format chosen in **Settings ▸ Images ▸ Video Format** (H.264 or HEVC), with AAC sound. It shows its progress over the viewer and can be cancelled; then it asks where to save the file.

## Deleting videos

Deleting a video in History that's on a timeline takes it off the timeline too. The confirmation names the timelines it's on.

## On iPad

Everything above works on iPad. Touch and hold a clip or the viewer for its menu, and drag a clip's edge to trim it. **Export ▸ Save to Photos** saves the timeline to Photos.
