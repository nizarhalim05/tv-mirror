# TellyBeam: Terminal version

This is the original version. Works on macOS 12 and up, Intel or Apple Silicon.

## Install

1. Turn the TV on, same Wi-Fi as your Mac
2. Open Terminal (Cmd + Space, type Terminal)
3. Paste this and press Enter:

   ```
   curl -fsSL https://raw.githubusercontent.com/nizarhalim05/tv-mirror/main/install.sh | bash
   ```

4. If it asks for your password, type it (nothing shows while you type, that's normal)
5. If a popup asks to install developer tools, click Install, wait, then run step 3 again
6. When it says Done, there's a TellyBeam icon on your Desktop

On macOS 13 or older it downloads a ready-made ffmpeg from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de/) instead of using Homebrew, because Homebrew kept failing on old macOS.

## Using it

Double-click **TellyBeam** on your Desktop, then:

- Type **1** to show your screen on the TV
- Type **2** to use the TV as an extra screen. Apple will ask how to use the new display, pick **Extend**. You've got 2 minutes to answer

First time, macOS asks for Screen Recording. Turn on **Terminal** in System Settings > Privacy & Security > Screen Recording, quit Terminal (Cmd + Q) and start again. If it asks whether Python can accept incoming connections, click Allow.

### Extra screen tips

- Move a window to the TV: hover the green button > Move to TellyBeam Display
- Ctrl + Cmd + F makes it fullscreen on the TV. For YouTube just press F
- For one browser tab: right-click the tab > Move Tab to New Window, then move that window
- Your mouse goes off the right edge of your screen onto the TV

### The mini screen (P)

A small window in the corner that shows what's on the TV, live, without the TV's delay. Press **P** to show/hide it. Click anywhere in it and your mouse jumps to that spot on the TV.

## Keys

Click the Terminal window first.

| Key | What it does |
|---|---|
| 1, 2, 3... | Switch screen |
| P | Mini screen on/off |
| R | Reset the delay (TV starts again from "now") |
| + / - | Bigger / smaller stream. Bigger = less delay but needs good Wi-Fi |
| F | Try the next video format (if the TV says "Playback not available") |
| M | Switch between "sony" and "live" mode, see which is faster on your TV |
| Q | Quit |

## Update

```
python3 ~/tv-mirror/tvmirror.py --update
```

## Options

Run from the `~/tv-mirror` folder.

| Command | What it does |
|---|---|
| `--screen 2` | Mirror screen 2 without asking |
| `--rate 12` | Stream size in Mbit/s (default 8) |
| `--virtual-display` | Go straight to extra screen mode |
| `--no-preview` | Extra screen without the mini screen |
| `--show-clock` | Clock on the TV so you can measure the delay |
| `--auto-reset 5` | Reset the delay every 5 minutes |
| `--tv "Bravia"` | Pick a TV by name or IP if you have more than one |
| `--height 720` | Lower quality, smoother on weak Wi-Fi |
| `--mode live` / `--mode stream` | Other ways of serving the video, for TVs that don't like the default |
| `--encoder hardware` | Use the Mac's video chip (less CPU, more delay on still screens) |
| `--audio-codec aac` | Sound format: mp2 (default), ac3 or aac |
| `--debug` | Print what the TV is asking for |
| `--test-pattern` | Send a test picture instead of your screen |

## Delay

The TV collects a fixed amount of data before it starts playing. A normal encoder makes about 60 kbit/s for a still screen instead of 8,000, so the TV ends up waiting 20 to 40 seconds. That's what I had at first.

The fix is padding every frame with filler data (H.264 filler NAL units) so it's always 8 Mbit/s, and using MP2 audio which is a fixed size per frame. The buffer fills in under a second no matter what's on screen.

macOS also only sends new frames when something on screen changes, so a still screen gave about 2 fps. There's a tiny dot that changes 30 times a second to keep it going.

To tune it for your TV:
1. Run with `--show-clock` and compare the clock on the Mac and the TV
2. Press R, then + a couple of times
3. If it says the TV can't keep up, press - once (that's your Wi-Fi)
4. Try M for live mode, keep whichever is faster

If the delay grows over time, press R or use `--auto-reset 5`. Getting closer to the router or plugging the TV into ethernet helps a lot.

## Sound

macOS doesn't let apps record system sound, so by default the TV gets silence. If you want sound:

1. `brew install blackhole-2ch`
2. Audio MIDI Setup > + > Create Multi-Output Device, tick your speakers and BlackHole 2ch, set it as output
3. Run with `--audio-device "BlackHole 2ch"`

## Problems I ran into (and you might too)

- **"Playback not available"**: TellyBeam checks if the TV actually starts downloading and tries other formats if not. It remembers what worked. You can also press F
- **"No TV found"**: same Wi-Fi? Guest networks and some mesh routers block devices from seeing each other. On the Sony check Settings > Network > Home Network > Renderer is on. Restarting the TV fixes it more often than you'd think
- **TV keeps connecting and disconnecting**: try `--encoder software`, then `--mode stream`
- **"Couldn't create the invisible screen"**: you need to answer Apple's popup with Extend. It sometimes hides behind other windows. Details go in `~/.tv-mirror-build/virtual-screen-report.txt`
- **Anything else**: the log is at `~/.tv-mirror-build/last-session.log`, send me that

## How it works

1. **ffmpeg** captures the screen (AVFoundation) and encodes constant bitrate H.264 (x264 with filler data) plus MP2 audio into MPEG-TS
2. A small web server inside the script serves it on port 8090. Older Sonys refuse endless streams, so it pretends to be a 100 GB file. They download it in pieces with HTTP Range requests, so the server keeps the last ~2 minutes with byte positions and gives every piece exactly the bytes that come after the last one
3. The TV gets found with an SSDP search and told to play with UPnP AVTransport (`SetAVTransportURI` and `Play`)

The extra screen comes from `vdisplay.m`, a small Objective-C helper using macOS's undocumented `CGVirtualDisplay`, with the mini screen drawn using `CGDisplayStream`. It compiles on your Mac the first time.

Everything else is Python standard library + ffmpeg.
