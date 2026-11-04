# TV Mirror

Mirror your Mac's screen to a Sony TV (and most other smart TVs) over Wi-Fi.
No Apple TV, no app on the TV, free and open source.

It works with TVs that support **DLNA** (most smart TVs since about 2012),
including older Sony Bravia models that don't support AirPlay, such as the
KDL-32WD754 (2016).

## Install (one time)

1. Open **Terminal** (press Cmd+Space, type `Terminal`, press Enter).
2. Paste this line and press Enter:

   ```
   curl -fsSL https://raw.githubusercontent.com/nizarhalim05/tv-mirror/main/install.sh | bash
   ```

   It installs what's needed (Homebrew and ffmpeg) and puts a
   **TV Mirror** launcher on your Desktop. It may ask for your Mac password;
   the letters won't show while you type, that's normal.

**Prefer to do it by hand?** Install ffmpeg with `brew install ffmpeg`, download
[`tvmirror.py`](tvmirror.py), and run `python3 tvmirror.py` in the folder you saved it to.

## Update to the newest version

```
python3 ~/tv-mirror/tvmirror.py --update
```

TV Mirror prints its version number when it starts, so you can check.

## Use it

1. Turn on your TV and make sure it's on the **same Wi-Fi** as your Mac.
2. Double-click **TV Mirror** on your Desktop.
3. If you have more than one screen, type the number of the one to mirror.
4. Your screen appears on the TV after a few seconds.
5. To stop, press **Q** (or close the window).

## Keep working while the TV shows something else

macOS only draws the desktop you're looking at, so it can't mirror "Desktop 1"
while you're on Desktop 2. Instead, TV Mirror can add an **invisible extra
screen** that macOS always draws, and send that to the TV:

```
python3 ~/tv-mirror/tvmirror.py --virtual-display
```

1. The first time, it builds a small helper (a few seconds). If it asks for
   Apple's developer tools, run `xcode-select --install` and try again.
2. A new screen called **TV Mirror Display** appears and goes to the TV.
3. To put a window on the TV, hover over the window's green button and
   choose **Move to TV Mirror Display** (or drag it off the right edge of
   your screen).
4. Keep working on your normal desktops; the TV keeps showing that screen.
5. When you quit TV Mirror, the screen disappears and its windows come back.

Make sure **System Settings > Desktop & Dock > Displays have separate Spaces**
is on, so swiping between your desktops doesn't affect the TV.

## Controls while it's running

Click the TV Mirror (Terminal) window, then press:

| Key | What it does |
|---|---|
| **1**, **2**, **3**... | Switch to that screen |
| **R** | Reset the delay: the TV starts again from "now" |
| **+** / **-** | Bigger / smaller stream (bigger = less delay, needs better Wi-Fi) |
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
| `python3 tvmirror.py --virtual-display` | Add an invisible extra screen for the TV (see above) |
| `python3 tvmirror.py --show-clock` | Show a clock on the TV so you can measure the delay |
| `python3 tvmirror.py --auto-reset 5` | Reset the delay automatically every 5 minutes |
| `python3 tvmirror.py --tv "Bravia"` | Pick a TV by name or IP address if you have several |
| `python3 tvmirror.py --height 720` | Lower quality, smoother on weak Wi-Fi |
| `python3 tvmirror.py --mode live` | Tell the TV it's a live broadcast instead of a long video file |
| `python3 tvmirror.py --encoder hardware` | Use the Mac's video chip: less CPU, but more delay on still screens |
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

- **The TV says "Playback not available"**: TV Mirror asks the TV whether it's
  playing and, if not, automatically tries other formats, ending with one older
  Sony TVs are known to play. If it still fails, try `--mode live`, or
  `--audio-codec aac`, or `--encoder hardware`.

- **"No TV found"**: the TV and Mac must be on the same network. Guest Wi-Fi
  and some mesh routers block devices from seeing each other. On the TV, check
  Settings > Network > Home Network setup > Renderer is turned on.
  Restarting the TV often helps.
- **The TV keeps connecting and disconnecting**: try `--encoder software`,
  then `--mode stream`.
- **Mirrors the wrong screen**: use `--screen 1` or `--screen 2`, or press
  1/2/3 while it's running. To show one thing while working on other
  desktops, use `--virtual-display`.

## How it works

1. **ffmpeg** captures the screen (AVFoundation) and encodes constant-bitrate
   H.264 (x264 with filler data) plus MP2 audio into an MPEG-TS stream.
2. A small web server built into the script serves the stream on port 8090.
   For older Sony TVs it pretends the stream is a very long video file, since
   they refuse endless streams.
3. The TV is found with an **SSDP** search, then told to play the stream with
   **UPnP AVTransport** commands (`SetAVTransportURI` and `Play`).

The invisible screen comes from `vdisplay.m`, a small Objective-C program
that uses macOS's built-in (undocumented) `CGVirtualDisplay` feature. TV
Mirror compiles it on your Mac the first time you use `--virtual-display`.

Everything else uses Python's standard library plus ffmpeg.

## Requirements

- A Mac running macOS 12 or later
- A smart TV with DLNA on the same network

## License

MIT, see [LICENSE](LICENSE). Not affiliated with Apple or Sony. AirPlay is a
trademark of Apple Inc.
