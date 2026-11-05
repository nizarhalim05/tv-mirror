# TV Mirror

Mirror your Mac to a Sony TV (or most smart TVs) over Wi-Fi. No Apple TV, no app on the TV, free.

## Why I made this

My dad has a 2016 Sony Bravia (KDL-32WD754). Good TV, but no AirPlay, so you can't just mirror a MacBook to it. I didn't want to buy an Apple TV for one thing, so I started digging into what the TV *can* do.

Turns out almost every smart TV since ~2012 supports DLNA, the thing you use to play videos from a phone or laptop. So the idea was: record the Mac screen, turn it into a live video, and make the TV think it's just playing a really long video file.

It ended up being way harder than I thought. The TV kept saying "Playback not available", there was a 40 second delay at one point, and macOS has its own surprises. I worked through it on and off, partly at the Afriqom office in London, and now it works. You can mirror your screen, or use the TV as a second monitor.

## Install the app

For Macs with Apple Silicon (M1 or newer) on macOS 13 or later.

1. Download [TV-Mirror-Mac.zip](https://github.com/nizarhalim05/tv-mirror/releases/download/mac-app/TV-Mirror-Mac.zip)
2. Open the zip and drag **TV Mirror** into Applications
3. Open it. The first time macOS will block it because it's not from the App Store. Go to System Settings > Privacy & Security, scroll down, click **Open Anyway**
4. Pick your TV and click **Show my screen on the TV** or **Use the TV as an extra screen**

First time only:
- If it asks for Screen Recording, turn on TV Mirror in System Settings, then quit TV Mirror and open it again
- If it asks about your local network, click Allow (it needs that to find the TV)
- For extra screen, Apple asks how you want to use the new display. Pick **Extend**, not Mirror

To move a window onto the TV, hover over its green button and choose **Move to TV Mirror Display**. There's a little live preview window (Show mini screen) so you can see what's on the TV without looking at it.

The app is still new. If it gives you trouble, the [Terminal version](TERMINAL.md) is the one I've used the most and it works.

## How it works (short version)

- **Finding the TV:** SSDP search on the Wi-Fi, then UPnP AVTransport commands (`SetAVTransportURI` + `Play`) to tell it what to play
- **The video:** screen capture, H.264 encoded at a constant 8 Mbit/s, packed into MPEG-TS with silent MP2 audio
- **The trick for old Sonys:** they won't play a live stream, only files. So a tiny web server on the Mac pretends there's a 100 GB video file and serves the live stream as if it was that file, piece by piece
- **Delay:** the TV waits for a certain amount of data before playing. A still screen makes almost no data, so the TV would sit there for 40 seconds. Padding every frame to a constant bitrate fills its buffer fast and gets it down to a few seconds
- **Extra screen:** uses macOS's built-in (undocumented) virtual display feature, then streams that display instead of yours

More detail in [TERMINAL.md](TERMINAL.md#how-it-works).

It's DLNA, so there will always be a few seconds of delay. Fine for videos, slides, dashboards. Not for gaming, use an HDMI cable for that.

## License

MIT. Not affiliated with Apple or Sony.
