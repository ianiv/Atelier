# Running jobs on another device

Any copy of Atelier can run jobs for your other devices. Send a video from an iPad to the Mac on your desk, and the Mac does the work while the iPad stays free. Results come back into the project on the device you sent them from, in the same place a local run would put them. Nothing is synced: your project stays on the device you're working on, and the other device is a borrowed engine.

## Setting it up

On the device that will do the work (the server), open Settings ▸ Compute and turn on **Let paired devices run jobs here**. Then pair the other device, which only has to happen once. Choose **Pair a Device…** to show a QR code and a code, good for two minutes and for one device, then on the other device do one of these:

- **Scan the QR code** with the Camera app (iPad). It opens Atelier and asks you to confirm.
- **Paste the link**: on the server choose Copy Link, and on the other device paste it into Settings ▸ Compute ▸ Add Server….
- **Type the code**: in Add Server…, enter the server's address and the code. A server on the same network shows under Nearby: choose its **Pair…** to fill in the address, then type the code it shows.

## Running a job there

In Create, **Run on** at the top of the inspector picks where new jobs go: this device or a paired server. A server that doesn't answer stays in the list, disabled. With a server chosen, the model and LoRA pickers list what the server has, including its own custom models, and this device needs none of those files. A preset for a model the server doesn't have shows as not available there.

## Using a server's styles

A paired server's [styles](styles.md) can be used on this device. On the Styles screen, the library menu in the toolbar also lists paired servers: pick one to show its styles, all its libraries together. In Create, the style picker lists each server's after your own, under its name. A server's style works just like your own, with the same tag boxes, and it works wherever the job runs, even on this device.

They're read-only here, and nothing the server does changes your own styles. To keep one and change it, choose **Copy to This iPad** or **Copy to This Mac**. If a server goes offline, its styles stay usable as last seen, marked as offline there. **Open Thumbnail in Create** brings back how a style's thumbnail was made, so it's unavailable when that thumbnail's model isn't where jobs are set to run. It needs the server online.

Then generate as usual. In the [Queue](queue.md), each job shows where it runs, with Uploading and Downloading as phases of their own, and Stop cancels it on the server.

Jobs on a server don't hold up this device: one can run here while another runs there, and each server runs jobs one at a time. On the server, a paired device's job joins its own queue with the device's name beside it, and appears only there. It's never saved to the server's projects.

If the connection drops or you quit, the job carries on at the server. Atelier picks it up when the server is back or on your next launch, and saves the result where it belongs. A result nobody collects is deleted after 7 days. Jobs still waiting their turn on this device aren't kept across a quit, nor are upscales and exports, whichever device they run on.

## What can run there

| Job | What's sent | What comes back |
| --- | --- | --- |
| Image | Settings, canvas, moodboard | The image |
| [Video](video.md) | Settings, reference images, audio file | Every frame, the soundtrack, the frame rate |
| Upscale (Quality or Fast) | The clip's frames, unless the server still has them from making that clip | The upscaled frames |
| Export Video with upscaling | The timeline's frames | The upscaled frames; this device encodes the video |

Upscale and Export use what's on the server: FlashVSR+ has to be downloaded there, and this device doesn't need it. The server holds all of an upscale's frames in memory at once, so very long timelines need a server with memory to spare.

Video results are large, up to hundreds of megabytes, and over a slow connection a download can take minutes. It resumes where it stopped if the connection drops.

## Tailscale, without the Tailscale app

Atelier can join your [tailnet](https://tailscale.com) by itself: no Tailscale app, no VPN. This is the easy way to reach your Mac from anywhere, and it works alongside the Tailscale app if you have that too. On each device, open Settings ▸ Compute and under **Tailscale**:

1. Choose **Sign In…**. Your browser opens Tailscale's sign-in page. Sign in there, and Settings then shows **Signed in as** you. Atelier shows up as a device of its own in your Tailscale admin console.
2. Leave **Serve over Tailscale** on, on the device doing the work. Paired devices can then reach it over your tailnet. Serving also needs **Let paired devices run jobs here** on.
3. Pair as usual. A pairing link and QR code made while signed in start with this device's tailnet name, so the other device reaches it from anywhere once it's signed in as well.

**Limit access to your Tailscale account** (on by default) only lets in devices signed in to the same Tailscale account as this one, on top of being paired. It matters if you've shared this device with someone else's tailnet.

**Control Server** is for [Headscale](https://headscale.net): enter its address before signing in, or leave it empty for Tailscale's own. **Preferred Hostname** is the name this device asks for on your tailnet. Tailscale may add a number if it's taken.

**Sign Out…** takes this device off your tailnet and forgets its sign-in. Atelier keeps that sign-in in its own folder, separate from the Tailscale app's.

Builds from source need one extra step to include this: see [Getting started](getting-started.md#tailscale-in-your-own-build). Without it, Settings says so and a Tailscale app still works.

## Networks

Atelier encrypts and authenticates every connection itself, so this works over any route: Atelier's own Tailscale sign-in, the Tailscale app, Headscale, your local network, or any network you can reach the server on. Pairing gives each device its own key, kept in the Keychain, and neither side can talk to the other without it. Tailscale only carries encrypted bytes it can't read. Outside of Tailscale's sign-in, there are no accounts or passwords, and no outside service is involved.

The server's **Accept connections from** setting is a second layer on top of those keys:

- **Tailscale only** (the default) accepts what comes over Atelier's own Tailscale sign-in, and from Tailscale addresses (100.64.0.0/10 and fd7a:115c:a1e0::/48) through the Tailscale app.
- **Tailscale and local network** also accepts private addresses on your own network.
- **Any network** accepts all addresses. Paired keys are still required.

A pairing link holds all the server's addresses, and the client tries the local network first, then Tailscale. Tailscale doesn't carry Bonjour between machines, so a server is found through the addresses remembered from pairing. On the same network, servers also find each other: a paired one shows as online and is reached directly.

Settings ▸ Compute shows this device's name on your tailnet when Atelier is signed in, and its address when it has the Tailscale app. The default port is 7863.

## What a paired device can do

A paired device can run and cancel its own jobs, list the server's models, LoRAs and the file names in its models folders, read its styles and their thumbnails (with the settings each thumbnail was made with), and download its own results. It can't read the server's projects, history, other files or settings, can't use its agent tools, and can't see another device's jobs. The images and audio it sends stay on the server for up to 7 days, as does a clip it made there, so it can be upscaled without sending it back. Those are stored separately for each device.

**Remove** in Settings ▸ Compute takes a device off at once: its connection closes, its key stops working, and its jobs and files on the server are deleted. To use it again, pair it again. Removing a server on the client only forgets it there; the server still lists the device until you remove it there too.

Be careful where a pairing link or QR code ends up: anyone who gets it within its two minutes can pair. A link opened on your device always asks before pairing, since the server it names would receive the jobs you send.

## On a Mac as the server

The server has to be running Atelier, and awake. Atelier keeps the Mac from going to sleep by itself while it's running a paired device's job, but a Mac already asleep can't be woken over Tailscale. If the Mac's firewall is on, macOS may ask whether Atelier can accept incoming connections the first time you turn this on.

## On iPad

An iPad can be a client or a server. As a server it only accepts jobs while Atelier is in the foreground, because iPadOS stops apps from listening in the background, and Atelier's Tailscale sign-in reconnects when you come back to it. It doesn't use the iPad's VPN slot, so it works beside another VPN. iPadOS asks for Local Network access the first time Atelier looks for servers or advertises itself.
