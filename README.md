# TV Mirror

Mirror your Mac's screen to a Sony TV (and most other smart TVs) over Wi-Fi.
No Apple TV, no app on the TV, free and open source.

It works with TVs that support **DLNA** (most smart TVs since about 2012),
including older Sony Bravia models that don't support AirPlay, such as the
KDL-32WD754 (2016).

## Easiest: the TV Mirror app (no Terminal)

For Macs with Apple Silicon (M1 or newer) and macOS 13 or later.

1. **Download** [TV-Mirror-Mac.zip](https://github.com/nizarhalim05/tv-mirror/releases/download/mac-app/TV-Mirror-Mac.zip).
2. **Open** the downloaded zip (double-click it). A **TV Mirror** app appears.
   Drag it into your **Applications** folder.
3. **Open TV Mirror** (double-click it). The first time, macOS says it can't check
   the app. Click **Done**, then open **System Settings > Privacy & Security**,
   scroll down, click **Open Anyway** next to "TV Mirror", and enter your password.
   This only happens once.
4. A **TV icon** appears in the menu bar at the top right of your screen. Click it.
5. Choose your TV, then click **Show my screen on the TV** or
   **Use the TV as an extra screen**.
6. **First time only:**
   - If macOS asks to allow **Screen Recording**, turn on **TV Mirror** in
     System Settings, then click the TV icon > **Quit TV Mirror** and open it again.
   - If it asks to find devices on your **local network**, or to accept incoming
     connections, click **Allow** (the TV needs this).
7. **Extra screen:** when Apple's window asks how to use the new screen, choose
   **Extend**. Click the TV icon > **Show mini screen** for the small live window.
   Move a window to the TV with its green button > **Move to TV Mirror Display**.
8. To stop, click the TV icon > **Stop**. If the TV falls behind, click
   **Catch up**.

The app is new. If it doesn't work for you, the Terminal version below still
does, and the app's log is in `~/Library/Logs/TVMirror.log`.

## Or: the Terminal version

## Install (one time)

1. Turn on your TV and connect it to the **same Wi-Fi** as your Mac.
2. On your Mac, open **Terminal**: press **Cmd + Space**, type `Terminal`, press **Enter**.
3. Paste this line and press **Enter**:

   ```
   curl -fsSL https://raw.githubusercontent.com/nizarhalim05/tv-mirror/main/install.sh | bash
   ```

4. If it asks for your **Mac password**, type it and press **Enter**. Nothing
   shows while you type; that's normal.
5. If a window pops up asking to install **developer tools**, click **Install**,
   wait for it to finish, then paste the line from step 3 again.
6. When it says **Done**, there's a **TV Mirror** icon on your Desktop.

## Show your screen on the TV

1. Double-click **TV Mirror** on your Desktop.
2. Type **1** and press **Enter**.
3. After a few seconds, your Mac's screen appears on the TV.
4. To stop, click the TV Mirror window and press **Q**.

**First time only:**
- macOS asks for **Screen Recording** permission: open **System Settings >
  Privacy & Security > Screen Recording**, turn on **Terminal**, quit Terminal
  (**Cmd + Q**) and double-click **TV Mirror** again.
- If a pop-up asks whether **Python** may accept incoming connections, click
  **Allow** (the TV needs this).

## Use the TV as an extra screen

The TV becomes a second monitor: put a website or video on it, and keep working
on your Mac at the same time.

1. Double-click **TV Mirror** on your Desktop.
2. Type **2** and press **Enter**.
3. An **Apple window** pops up asking how to use the new screen. Choose
   **Extend** (use it as a separate display), **not** Mirror.
   You have 2 minutes to answer.
4. A small window called **TV screen (live)** appears in the bottom-right corner
   of your Mac. It shows what's on the TV, without the TV's delay.
5. To put a window on the TV, hover over its **green button** (top-left of the
   window) and choose **Move to TV Mirror Display**.
6. Press **Ctrl + Cmd + F** to make it fill the whole TV. (Press again to undo.)
   For a YouTube video, press **F**.
7. Keep working on your Mac; the TV keeps showing that window.
8. To stop, click the TV Mirror window and press **Q**. The extra screen goes
   away and its windows come back to your Mac.

**Tip:** for a single browser tab, right-click the tab and choose **Move Tab to
New Window** first, then do step 5 with that window.

### The mini screen (P key)

The **TV screen (live)** window is a mini copy of the TV screen on your Mac.

- **Show or hide it:** click the TV Mirror window and press **P**.
- **Control the TV screen:** move your mouse off the **right edge** of your Mac's
  screen onto the TV screen, and watch the mini screen (not the TV, which is a
  few seconds behind) to see where your pointer is.
- **Jump there:** click a spot in the mini screen and your mouse pointer jumps
  to that spot on the TV screen.

## Update to the newest version

```
python3 ~/tv-mirror/tvmirror.py --update
```

TV Mirror shows its version number when it starts.

## Controls while it's running

Click the TV Mirror (Terminal) window, then press:

| Key | What it does |
|---|---|
| **1**, **2**, **3**... | Switch to that screen |
| **P** | Show/hide the mini screen (extra-screen mode) |
| **R** | Reset the delay: the TV starts again from "now" |
| **+** / **-** | Bigger / smaller stream (bigger = less delay, needs better Wi-Fi) |
| **F** | Try the next video format (if the TV shows an error like "Playback not available") |
| **M** | Switch between "sony" and "live" mode, to see which has less delay on your TV |
| **Q** | Quit |

**First time only:** macOS asks for **Screen Recording** permission. Go to
System Settings > Privacy & Security > Screen Recording, turn on **Terminal**,
then quit Terminal and start TV Mirror again. If a firewall pop-up asks
whether Python may accept connections, click **Allow** (the TV needs this).

## Options

Run these in Terminal, inside the `~/tv-mirror` folder (`cd ~/tv-mirror`):

| Command | What it does |
|---|---|
| `python3 tvmirror.py --update` | Download the newest version from GitHub |
| `python3 tvmirror.py --screen 2` | Mirror screen 2 without asking |
| `python3 tvmirror.py --rate 12` | Stream size in Mbit/s (default 8). Bigger = less delay, needs better Wi-Fi |
| `python3 tvmirror.py --virtual-display` | Go straight to "extra screen" mode (option 2) |
| `python3 tvmirror.py --virtual-display --no-preview` | The same, without the mini screen |
| `python3 tvmirror.py --show-clock` | Show a clock on the TV so you can measure the delay |
| `python3 tvmirror.py --auto-reset 5` | Reset the delay automatically every 5 minutes |
| `python3 tvmirror.py --tv "Bravia"` | Pick a TV by name or IP address if you have several |
| `python3 tvmirror.py --height 720` | Lower quality, smoother on weak Wi-Fi |
| `python3 tvmirror.py --mode live` | Tell the TV it's a live broadcast instead of a long video file |
| `python3 tvmirror.py --encoder hardware` | Use the Mac's video chip: less CPU, but more delay on still screens (`intra` = every frame complete) |
| `python3 tvmirror.py --audio-codec aac` | Sound format: `mp2` (default), `ac3` or `aac` |
| `python3 tvmirror.py --mode stream` | For newer TVs that don't like the default Sony mode |
| `python3 tvmirror.py --debug` | Show what the TV is asking for (for troubleshooting) |
| `python3 tvmirror.py --test-pattern` | Send a moving test picture instead of your screen |

## About the delay

**Why there's a delay:** many TVs, including older Sonys, collect a fixed
*amount of data* before they start playing. A normal video encoder makes very
little data for a still screen (about 60 kbit/s instead of 8,000), and silent
sound is even smaller, so the TV can end up waiting 20-40 seconds to collect
enough. An empty extra screen is the worst case.

**What TV Mirror does about it:** it keeps the video and the sound at a
constant size, topping every frame up with filler data the TV throws away
(H.264 filler units, and MP2 sound, the format European TV broadcasts use). The TV's buffer then fills in a fraction
of a second, however still your screen is.

**Fine-tuning for your TV:**

1. Start with `python3 tvmirror.py --show-clock` and keep the Terminal window
   visible on the mirrored screen. Compare the clock in Terminal with the same
   clock on the TV: the difference is your delay.
2. Press **R** to start from "now", then press **+** a couple of times (wait for
   the picture to come back each time). A bigger stream fills the TV's buffer
   faster.
3. If TV Mirror says the TV *can't keep up*, your Wi-Fi is the limit: press
   **-** once.
4. Press **M** to try "live" mode, which tells the TV it's a live broadcast.
   Some TVs keep a smaller buffer for live broadcasts. Keep whichever is faster.

**If the delay keeps growing** the longer it runs, press **R**, or use
`--auto-reset 5` to reset it automatically every 5 minutes. Moving the Mac
closer to the router (or connecting the TV with a network cable) helps.

Expect a few seconds at best: DLNA was designed for playing films, not live
screens. It's great for videos, slides and dashboards, but not for gaming. For
zero delay, use an HDMI cable.

## Sound

macOS doesn't let apps record the sound your Mac is playing, so by default
the TV gets the picture with silence. To send sound too:

1. Install the free BlackHole driver: `brew install blackhole-2ch`
2. Open **Audio MIDI Setup**, click **+** > **Create Multi-Output Device**,
   tick your speakers and **BlackHole 2ch**, and choose it as your sound output.
3. Start with: `python3 tvmirror.py --audio-device "BlackHole 2ch"`

## Troubleshooting

- **"Couldn't create the invisible screen: macOS didn't switch it on"**: macOS
  only switches the extra screen on after you answer its window asking how to
  use it. Start again, choose **2**, and choose **Extend** in Apple's window
  within 2 minutes (it may be hiding behind other windows). Details are saved
  in `~/.tv-mirror-build/virtual-screen-report.txt`.

- **Something's not right?** TV Mirror writes down everything the TV asks for in
  `~/.tv-mirror-build/last-session.log`. Attach that file when asking for help.

- **The TV says "Playback not available"**: when it starts, TV Mirror watches
  whether the TV really downloads the video and, if not, automatically tries
  other formats, ending with one older Sony TVs are known to play. It remembers
  what worked for your TV. You can also press **F** to switch format by hand.

- **"No TV found"**: the TV and Mac must be on the same network. Guest Wi-Fi
  and some mesh routers block devices from seeing each other. On the TV, check
  Settings > Network > Home Network setup > Renderer is turned on.
  Restarting the TV often helps.
- **The TV keeps connecting and disconnecting**: try `--encoder software`,
  then `--mode stream`.
- **Mirrors the wrong screen**: press 1/2/3 while it's running. To show one
  thing while you keep working, choose **2** (extra screen) at the start.

## How it works

1. **ffmpeg** captures the screen (AVFoundation) and encodes constant-bitrate
   H.264 (x264 with filler data) plus MP2 audio into an MPEG-TS stream.
2. A small web server built into the script serves the stream on port 8090.
   For older Sony TVs it pretends the stream is a very long video file, since
   they refuse endless streams. These TVs download the "file" in pieces, so the
   server keeps the recent stream with its byte positions and gives every piece
   exactly the bytes that follow the previous one (a "growing file").
3. The TV is found with an **SSDP** search, then told to play the stream with
   **UPnP AVTransport** commands (`SetAVTransportURI` and `Play`).

The invisible screen comes from `vdisplay.m`, a small Objective-C program
that uses macOS's built-in (undocumented) `CGVirtualDisplay` feature, and
shows the live preview with `CGDisplayStream`. TV
Mirror compiles it on your Mac the first time it runs. The same helper draws a
tiny dot that changes 30 times a second, because macOS only sends new frames to
screen recording when something on screen changes.

Everything else uses Python's standard library plus ffmpeg.

## Requirements

- A Mac running macOS 12 or later, with Apple's developer tools (the installer
  sets these up)
- On macOS 13 or older (or if Homebrew can't install ffmpeg), the installer downloads
  a ready-made ffmpeg from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de/)
  into `~/tv-mirror/bin` instead
- A smart TV with DLNA on the same network

## License

MIT, see [LICENSE](LICENSE). Not affiliated with Apple or Sony. AirPlay is a
trademark of Apple Inc.
