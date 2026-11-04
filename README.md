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

## Use it

1. Turn on your TV and make sure it's on the **same Wi-Fi** as your Mac.
2. Double-click **TV Mirror** on your Desktop.
3. If you have more than one screen, type the number of the one to mirror.
4. Your screen appears on the TV after a few seconds.
5. To stop, press **Ctrl+C** or close the window.

**First time only:** macOS asks for **Screen Recording** permission. Go to
System Settings > Privacy & Security > Screen Recording, turn on **Terminal**,
then quit Terminal and start TV Mirror again. If a firewall pop-up asks
whether Python may accept connections, click **Allow** (the TV needs this).

## Options

Run these in Terminal, inside the `~/tv-mirror` folder (`cd ~/tv-mirror`):

| Command | What it does |
|---|---|
| `python3 tvmirror.py --screen 2` | Mirror screen 2 without asking |
| `python3 tvmirror.py --boost 32M` | Less lag (needs good Wi-Fi). Default is `25M`; `0` turns it off |
| `python3 tvmirror.py --tv "Bravia"` | Pick a TV by name or IP address if you have several |
| `python3 tvmirror.py --height 720` | Lower quality, smoother on weak Wi-Fi |
| `python3 tvmirror.py --encoder software` | Try this if the TV says it can't play the video |
| `python3 tvmirror.py --mode stream` | For newer TVs that don't like the default Sony mode |
| `python3 tvmirror.py --debug` | Show what the TV is asking for (for troubleshooting) |
| `python3 tvmirror.py --test-pattern` | Send a moving test picture instead of your screen |

## About the delay

The TV saves up a chunk of video before it starts playing, which causes the
delay. TV Mirror pads the video with filler data the TV throws away, so that
chunk fills up much faster, which cuts the delay to a fraction of what it
would be otherwise.

- Still too much delay? Try `--boost 32M` or `--boost 40M`.
- Picture freezing or stuttering? Your Wi-Fi can't keep up; try `--boost 15M`.

It's fine for videos, slideshows and presentations, but not for gaming.

## Sound

macOS doesn't let apps record the sound your Mac is playing, so by default
the TV gets the picture with silence. To send sound too:

1. Install the free BlackHole driver: `brew install blackhole-2ch`
2. Open **Audio MIDI Setup**, click **+** > **Create Multi-Output Device**,
   tick your speakers and **BlackHole 2ch**, and choose it as your sound output.
3. Start with: `python3 tvmirror.py --audio-device "BlackHole 2ch"`

## Troubleshooting

- **"No TV found"**: the TV and Mac must be on the same network. Guest Wi-Fi
  and some mesh routers block devices from seeing each other. On the TV, check
  Settings > Network > Home Network setup > Renderer is turned on.
  Restarting the TV often helps.
- **The TV keeps connecting and disconnecting**: try `--encoder software`,
  then `--mode stream`.
- **Mirrors the wrong screen**: use `--screen 1` or `--screen 2`. macOS
  "Spaces" (extra desktops you swipe between) aren't separate screens; TV
  Mirror shows whichever Space is on the screen you picked.

## How it works

1. **ffmpeg** captures the screen (AVFoundation) and encodes H.264 with the
   Mac's hardware encoder (VideoToolbox) into an MPEG-TS stream.
2. A small web server built into the script serves the stream on port 8090.
   For older Sony TVs it pretends the stream is a very long video file, since
   they refuse endless streams.
3. The TV is found with an **SSDP** search, then told to play the stream with
   **UPnP AVTransport** commands (`SetAVTransportURI` and `Play`).

Everything uses Python's standard library plus ffmpeg; nothing else to install.

## Requirements

- A Mac running macOS 12 or later
- A smart TV with DLNA on the same network

## License

MIT, see [LICENSE](LICENSE). Not affiliated with Apple or Sony. AirPlay is a
trademark of Apple Inc.
