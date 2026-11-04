#!/usr/bin/env python3
"""
TV Mirror - mirror your Mac's screen to a Sony TV (or most smart TVs) over Wi-Fi.

How it works (same idea as AirBeamTV):
  1. ffmpeg captures the Mac screen and encodes it to H.264 video (hardware accelerated).
  2. This script serves that live video as an MPEG-TS stream from a tiny web server.
  3. It finds your TV on the network (SSDP / DLNA discovery).
  4. It tells the TV "play this URL" using UPnP AVTransport commands.

Requirements: macOS, Python 3, ffmpeg (brew install ffmpeg). No extra Python packages.

Usage:
  python3 tvmirror.py                 # find TV, start mirroring
  python3 tvmirror.py --tv "Bravia"   # pick a TV by (part of) its name or IP
  python3 tvmirror.py --list-devices  # show screens / audio devices ffmpeg can see
  python3 tvmirror.py --serve-only    # just run the stream (test it in VLC)
Press Ctrl+C to stop.
"""

import argparse
import atexit
import hashlib
import json
import http.server
import os
import queue
import re
import select
import shutil
import socket
import socketserver
import subprocess
import sys
import termios
import tty
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

APP_NAME = "TV Mirror"
VERSION = "1.7"
REPO = "nizarhalim05/tv-mirror"
SSDP_ADDR = ("239.255.255.250", 1900)
AVTRANSPORT = "urn:schemas-upnp-org:service:AVTransport:1"
TS_PACKET = 188
CLOCK_FONTS = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]
# Sound formats. MP2 (what European TV broadcasts use) and AC-3 always use the
# same number of bytes, even for silence. AAC shrinks silence to ~5 kbit/s, which
# makes TVs that wait for a fixed amount of data wait much longer.
AUDIO_CODECS = {
    "mp2": ["-c:a", "mp2", "-b:a", "384k"],
    "ac3": ["-c:a", "ac3", "-b:a", "448k"],
    "aac": ["-c:a", "aac", "-b:a", "128k"],
}
# Combinations tried in order if the TV says it can't play the stream.
# The last one is the one older Sony TVs are known to play (but with more delay).
PROFILES = [
    ("software", "mp2", "steady video + MP2 sound"),
    ("software", "aac", "steady video + AAC sound"),
    ("intra", "aac", "Mac's video chip, every frame complete + AAC sound"),
    ("hardware", "aac", "Mac's video chip + AAC sound (plays on most TVs, but more delay)"),
]
RATE_STEPS = [2, 3, 4, 6, 8, 10, 12, 15, 20, 25, 30]   # Mbit/s choices for + and -
HAS_X264 = True        # set at startup: does this ffmpeg have the libx264 encoder?
HAS_DRAWTEXT = False   # set at startup: can this ffmpeg draw text on the video?
VIDEO_PID = 0x100   # ffmpeg's default IDs for the first track and the stream map
PMT_PID = 0x1000
STREAM_PATH = "/screen.ts"
DLNA_FEATURES = (
    "DLNA.ORG_OP=00;DLNA.ORG_CI=0;"
    "DLNA.ORG_FLAGS=01700000000000000000000000000000"
)
MIME = "video/mpeg"


# --------------------------------------------------------------------------- #
# Finding the TV (SSDP discovery + device description)
# --------------------------------------------------------------------------- #

def _local(tag):
    """Strip the XML namespace from a tag name."""
    return tag.rsplit("}", 1)[-1]


def load_device(location):
    """Read a UPnP device description and return the TV's AVTransport control URL."""
    with urllib.request.urlopen(location, timeout=5) as resp:
        root = ET.fromstring(resp.read())

    base = location
    name = None
    for el in root.iter():
        tag = _local(el.tag)
        if tag == "URLBase" and el.text and el.text.strip():
            base = el.text.strip()
        elif tag == "friendlyName" and name is None and el.text:
            name = el.text.strip()

    for svc in root.iter():
        if _local(svc.tag) != "service":
            continue
        fields = {_local(c.tag): (c.text or "").strip() for c in svc}
        if "AVTransport" in fields.get("serviceType", "") and fields.get("controlURL"):
            return {
                "name": name or "Unknown TV",
                "host": urllib.parse.urlparse(location).hostname,
                "location": location,
                "control_url": urllib.parse.urljoin(base, fields["controlURL"]),
            }
    return None


def discover(timeout=4.0):
    """Search the local network for TVs / media renderers that can play a URL."""
    msg = "\r\n".join([
        "M-SEARCH * HTTP/1.1",
        "HOST: 239.255.255.250:1900",
        'MAN: "ssdp:discover"',
        "MX: 2",
        f"ST: {AVTRANSPORT}",
        "", "",
    ]).encode()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.settimeout(0.5)
    locations = set()
    try:
        for _ in range(3):
            sock.sendto(msg, SSDP_ADDR)
            time.sleep(0.1)
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _addr = sock.recvfrom(65507)
            except socket.timeout:
                continue
            m = re.search(rb"(?im)^location:\s*(\S+)", data)
            if m:
                locations.add(m.group(1).decode(errors="ignore"))
    finally:
        sock.close()

    devices, seen = [], set()
    for loc in sorted(locations):
        try:
            dev = load_device(loc)
        except Exception:
            dev = None
        if dev and dev["control_url"] not in seen:
            seen.add(dev["control_url"])
            devices.append(dev)
    return devices


# --------------------------------------------------------------------------- #
# Controlling the TV (UPnP AVTransport SOAP commands)
# --------------------------------------------------------------------------- #

class TVError(Exception):
    pass


def soap(control_url, action, args):
    arg_xml = "".join(f"<{k}>{escape(str(v))}</{k}>" for k, v in args)
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        f'<s:Body><u:{action} xmlns:u="{AVTRANSPORT}">{arg_xml}</u:{action}>'
        "</s:Body></s:Envelope>"
    ).encode()
    req = urllib.request.Request(
        control_url, data=body, method="POST",
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPACTION": f'"{AVTRANSPORT}#{action}"',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="ignore")
        code = re.search(r"<errorCode>(\d+)</errorCode>", detail)
        desc = re.search(r"<errorDescription>(.*?)</errorDescription>", detail)
        raise TVError(
            f"TV refused {action} (HTTP {e.code}"
            + (f", UPnP error {code.group(1)}" if code else "")
            + (f": {desc.group(1)}" if desc else "") + ")"
        ) from None


def didl_metadata(url, title):
    protocol_info = f"http-get:*:{MIME}:{StreamHandler._features(StreamHandler)}"
    return (
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        f"<dc:title>{escape(title)}</dc:title>"
        "<upnp:class>object.item.videoItem</upnp:class>"
        f'<res protocolInfo="{protocol_info}">{escape(url)}</res>'
        "</item></DIDL-Lite>"
    )


def tv_play(tv, url):
    try:
        soap(tv["control_url"], "Stop", [("InstanceID", 0)])
    except Exception:
        pass  # fine if nothing was playing
    soap(tv["control_url"], "SetAVTransportURI", [
        ("InstanceID", 0),
        ("CurrentURI", url),
        ("CurrentURIMetaData", didl_metadata(url, f"{APP_NAME} - {socket.gethostname()}")),
    ])
    soap(tv["control_url"], "Play", [("InstanceID", 0), ("Speed", 1)])


def tv_state(tv):
    """Ask the TV what it's doing: (state, status), e.g. ('PLAYING', 'OK')."""
    try:
        xml = soap(tv["control_url"], "GetTransportInfo", [("InstanceID", 0)]).decode(errors="ignore")
    except Exception:
        return None, None
    state = re.search(r"<CurrentTransportState>(.*?)</CurrentTransportState>", xml)
    status = re.search(r"<CurrentTransportStatus>(.*?)</CurrentTransportStatus>", xml)
    return (state.group(1).strip().upper() if state else None,
            status.group(1).strip().upper() if status else None)


def tv_check(tv, wait=25, debug=False):
    """After pressing play, see whether the TV really plays the stream: 'playing' or 'failed'.

    The TV's own answer can't be trusted (some say PLAYING while showing an error),
    so we watch what it downloads instead. A TV that's playing keeps up with the
    live stream; a TV that rejects it only grabs small pieces and hangs up.
    """
    samples, start, last_ask = [], time.time(), 0.0
    while time.time() - start < wait:
        time.sleep(0.5)
        now = time.time()
        samples.append((now, BROADCASTER.produced, StreamHandler.delivered))
        old = [x for x in samples if now - x[0] >= 6]
        if old:
            t0, p0, d0 = old[-1]
            made, sent = BROADCASTER.produced - p0, StreamHandler.delivered - d0
            if debug and int(now - start) % 3 == 0 and now - start - int(now - start) < 0.5:
                print(f"  [debug] last 6 s: made {made // 1024} KB, TV took {sent // 1024} KB")
            if made > 100 * 1024 and sent >= 0.6 * made:
                return "playing"
        if now - last_ask > 2:
            last_ask = now
            state, status = tv_state(tv)
            if debug:
                print(f"  [debug] TV says: {state} / {status}")
            if status == "ERROR_OCCURRED":
                return "failed"
    return "failed"


def tv_stop(tv):
    try:
        soap(tv["control_url"], "Stop", [("InstanceID", 0)])
    except Exception:
        pass


# --------------------------------------------------------------------------- #
# Screen capture + encoding (ffmpeg)
# --------------------------------------------------------------------------- #

def list_devices():
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
        capture_output=True, text=True,
    )
    lines = proc.stderr.splitlines()
    screens, audio, section = [], [], None
    for line in lines:
        if "video devices" in line:
            section = "video"
        elif "audio devices" in line:
            section = "audio"
        m = re.search(r"\[(\d+)\] (.+)$", line)
        if m and section == "video" and "Capture screen" in m.group(2):
            screens.append(m.group(2).strip())
        elif m and section == "audio":
            audio.append(m.group(2).strip())
    return screens, audio


def ffmpeg_command(args):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]

    if args.test_pattern:
        cmd += ["-re", "-f", "lavfi", "-i", f"testsrc2=size=1280x720:rate={args.fps}"]
    else:
        audio = args.audio_device or "none"
        cmd += [
            "-f", "avfoundation", "-capture_cursor", "1",
            "-pixel_format", "nv12",
            "-framerate", str(args.fps),
            "-i", f"{args.screen}:{audio}",
        ]

    has_real_audio = bool(args.audio_device) and not args.test_pattern
    if not has_real_audio:
        # Many TVs refuse a video with no sound track, so add silence.
        cmd += ["-re", "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]

    cmd += ["-map", "0:v:0", "-map", "0:a:0" if has_real_audio else "1:a:0"]
    vf = f"scale=-2:{args.height}:flags=bicubic"
    if args.show_clock and HAS_DRAWTEXT:
        font = next((f for f in CLOCK_FONTS if os.path.exists(f)), None)
        font_opt = f"fontfile='{font}':" if font else ""
        vf += (",drawtext=" + font_opt + "text='%{localtime\\:%T}':fontsize=h/14:"
               "fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=12:x=w-tw-30:y=30")
    cmd += ["-vf", vf + ",format=yuv420p"]

    # THE BIG LAG FIX: many TVs (including older Sonys) wait until they've collected a
    # fixed AMOUNT OF DATA before they start playing. A normal encoder makes almost no
    # data for a still screen (~60 kbit/s instead of 8,000), so the TV waits a very long
    # time - that's where a 20-40 second delay comes from. So we make the video and the
    # sound constant-size: the encoder tops every frame up with "filler" the TV throws
    # away, and the TV's buffer fills in a fraction of a second.
    kbps = int(args.rate * 1000)
    gop = args.fps                        # a keyframe every second -> fast start
    if args.encoder in ("hardware", "intra"):
        # Apple's hardware encoder can't add filler. "intra" makes every frame a
        # complete picture instead, which also keeps the amount of data up.
        cmd += ["-c:v", "h264_videotoolbox", "-realtime", "1", "-allow_sw", "1",
                "-profile:v", "high",
                "-b:v", f"{kbps}k", "-maxrate", f"{kbps}k", "-bufsize", f"{kbps}k"]
        if args.encoder == "intra":
            gop = 1
    else:
        # "superfast", not "ultrafast": ultrafast silently drops to the Baseline
        # profile, which many TVs refuse for HD video.
        cmd += ["-c:v", "libx264", "-preset", "superfast", "-tune", "zerolatency",
                "-profile:v", "high",
                "-b:v", f"{kbps}k", "-minrate", f"{kbps}k", "-maxrate", f"{kbps}k",
                "-bufsize", f"{max(kbps // 2, 500)}k",
                "-x264-params", "nal-hrd=cbr:force-cfr=1"]   # constant bitrate + filler
    cmd += [
        "-g", str(gop),
        "-bsf:v", "dump_extra",           # repeat picture settings so a TV can join any time
    ] + AUDIO_CODECS[args.audio_codec] + [
        "-ar", "48000", "-ac", "2",
        "-f", "mpegts",
        # system_b = label AC-3 sound the European (DVB) way
        "-mpegts_flags", "+pat_pmt_at_frames" + ("+system_b" if args.audio_codec == "ac3" else ""),
    ]
    if args.boost:
        # Optional extra: also pad the whole stream with empty packets up to this rate.
        # Only helps TVs that count the raw network data; costs Wi-Fi bandwidth.
        cmd += ["-muxrate", f"{max(args.boost, args.rate + 1)}M"]
    cmd += [
        "-muxdelay", "0", "-flush_packets", "1",
        "pipe:1",
    ]
    return cmd


class Broadcaster:
    """Reads the live stream from ffmpeg once and hands it to every connected TV."""

    def __init__(self):
        self.lock = threading.Lock()
        self.clients = set()
        self.running = True
        self.max_backlog = 1024 * 1024   # bytes a TV may fall behind before we skip ahead
        self.drops = 0                   # how many times a TV fell too far behind
        self.produced = 0                # bytes of video made so far

    def subscribe(self):
        q = queue.Queue()
        q.waiting_for_keyframe = True
        q.backlog = 0
        with self.lock:
            self.clients.add(q)
        return q

    def unsubscribe(self, q):
        with self.lock:
            self.clients.discard(q)

    @staticmethod
    def keyframe_offset(chunk):
        """Byte offset of the first MPEG-TS packet that starts a clean frame, or -1."""
        def pid(i):
            return ((chunk[i + 1] & 0x1F) << 8) | chunk[i + 2]

        for i in range(0, len(chunk), TS_PACKET):
            pkt = chunk[i:i + TS_PACKET]
            # video track, with an adaptation field whose random_access_indicator is set
            if (pkt[0] == 0x47 and pid(i) == VIDEO_PID
                    and pkt[3] & 0x20 and pkt[4] > 0 and pkt[5] & 0x40):
                # also include the stream map (PAT/PMT) written just before it
                while i >= TS_PACKET and pid(i - TS_PACKET) in (0x0000, PMT_PID):
                    i -= TS_PACKET
                return i
        return -1

    def publish(self, chunk):
        self.produced += len(chunk)
        with self.lock:
            clients = list(self.clients)
        start = None
        for q in clients:
            data = chunk
            if q.waiting_for_keyframe:
                if start is None:
                    start = self.keyframe_offset(chunk)
                if start < 0:
                    continue  # new viewer: wait for the next clean frame
                q.waiting_for_keyframe = False
                data = chunk[start:]
            if q.backlog + len(data) > self.max_backlog:
                # The TV can't take the video as fast as we make it (Wi-Fi too slow).
                # Rather than let a delay build up here, skip ahead and restart
                # cleanly at the next full frame.
                with q.mutex:
                    q.queue.clear()
                q.backlog = 0
                q.waiting_for_keyframe = True
                self.drops += 1
                continue
            q.backlog += len(data)
            q.put_nowait(data)

    def close(self):
        self.running = False
        with self.lock:
            clients = list(self.clients)
        for q in clients:
            try:
                q.put_nowait(None)
            except queue.Full:
                pass

    def pump(self, stream):
        """Copy ffmpeg's output, only in whole 188-byte MPEG-TS packets."""
        buf = b""
        fd = stream.fileno()
        while self.running:
            data = os.read(fd, TS_PACKET * 128)
            if not data:
                break
            buf += data
            usable = len(buf) - (len(buf) % TS_PACKET)
            if usable:
                self.publish(buf[:usable])
                buf = buf[usable:]

    def disconnect_all(self):
        """Hang up on every viewer (they reconnect fresh, with no backlog)."""
        with self.lock:
            clients = list(self.clients)
            self.clients.clear()
        for q in clients:
            with q.mutex:
                q.queue.clear()
            try:
                q.put_nowait(None)
            except queue.Full:
                pass


BROADCASTER = Broadcaster()


def log(msg):
    """Print a message on its own line (clears the ticking clock line first)."""
    sys.stdout.write("\r\033[K" + msg + "\n")
    sys.stdout.flush()


class StreamHandler(http.server.BaseHTTPRequestHandler):
    """Serves the live video. Settings below are changed by command-line options."""
    server_version = "TVMirror/1.0"
    protocol_version = "HTTP/1.1"
    mode = "sony"         # "sony": pretend it's a huge file (old Sony TVs need this)
                          # "live": endless stream marked as a live broadcast (DLNA
                          #         "sender paced"), so the TV may keep a smaller buffer
                          # "stream": plain endless stream
    debug = False
    dlna_pn = ""
    delivered = 0         # bytes sent to TVs so far (to see if a TV is really playing)
    FAKE_LENGTH = 100 * 1024 ** 3   # 100 GB, i.e. "a very long video"

    def _features(self):
        pn = f"DLNA.ORG_PN={self.dlna_pn};" if self.dlna_pn else ""
        if self.mode == "live":
            # sender-paced + start/end keep moving + streaming transfer + DLNA 1.5
            return pn + "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=8D100000000000000000000000000000"
        op = "DLNA.ORG_OP=01;" if self.mode == "sony" else "DLNA.ORG_OP=00;"
        return pn + op + "DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    def _log_request(self):
        if self.debug:
            hdrs = "; ".join(f"{k}: {v}" for k, v in self.headers.items())
            print(f"  [debug] {self.command} {self.path} | {hdrs}")

    def _send_headers(self):
        """Send headers. Returns (ok, byte limit or None, chunked?)."""
        rng = self.headers.get("Range", "")
        m = re.match(r"bytes=(\d*)-(\d*)", rng)
        length, chunked = None, False
        if self.mode == "sony":
            start = int(m.group(1)) if m and m.group(1) else 0
            start = min(start, self.FAKE_LENGTH - 1)
            last = self.FAKE_LENGTH - 1
            if m and m.group(2):
                last = min(int(m.group(2)), last)
            length = last - start + 1
            if m:
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{last}/{self.FAKE_LENGTH}")
            else:
                self.send_response(200)
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
        elif self.mode == "live":
            if m and m.group(1) and int(m.group(1)) > 0:
                # A live broadcast can't jump around
                self.send_response(416)
                self.send_header("Content-Range", "bytes */*")
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                return False, None, False
            self.send_response(200)
            self.send_header("realTimeInfo.dlna.org", "DLNA.ORG_TLAG=*")
            if self.request_version == "HTTP/1.1":
                self.send_header("Transfer-Encoding", "chunked")
                chunked = True
        else:
            self.send_response(200)
        self.send_header("Content-Type", MIME)
        self.send_header("transferMode.dlna.org", "Streaming")
        self.send_header("contentFeatures.dlna.org", self._features())
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        return True, length, chunked

    def _valid_path(self):
        return urllib.parse.urlparse(self.path).path == STREAM_PATH

    def do_HEAD(self):
        self._log_request()
        if not self._valid_path():
            self.send_error(404)
            return
        self._send_headers()

    def do_GET(self):
        self._log_request()
        if not self._valid_path():
            self.send_error(404)
            return
        ok, limit, chunked = self._send_headers()
        if not ok:
            return
        try:
            # Small send buffer, so video can't pile up unseen inside macOS
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 256 * 1024)
        except OSError:
            pass
        q = BROADCASTER.subscribe()
        log(f"  -> {self.client_address[0]} connected to the stream")
        sent, began, reason = 0, time.time(), "TV closed the connection"
        try:
            while True:
                chunk = q.get(timeout=15)
                if chunk is None:
                    reason = "stream ended"
                    break
                q.backlog = max(0, q.backlog - len(chunk))
                if limit is not None and sent + len(chunk) > limit:
                    chunk = chunk[:limit - sent]
                if chunked:
                    self.wfile.write(b"%X\r\n" % len(chunk) + chunk + b"\r\n")
                else:
                    self.wfile.write(chunk)
                sent += len(chunk)
                StreamHandler.delivered += len(chunk)
                if limit is not None and sent >= limit:
                    reason = "sent everything the TV asked for"
                    break
        except queue.Empty:
            reason = "no video from ffmpeg for 15 s"
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            BROADCASTER.unsubscribe(q)
            extra = ""
            if self.debug:
                extra = f" after {time.time() - began:.1f}s, {sent / 1024:.0f} KB sent ({reason})"
            log(f"  <- {self.client_address[0]} disconnected{extra}")

    def log_message(self, fmt, *args):
        pass  # keep the terminal quiet


class StreamServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# --------------------------------------------------------------------------- #
# Virtual screen (an extra invisible monitor macOS always draws)
# --------------------------------------------------------------------------- #

# Source of the small helper program; it's compiled on your Mac the first time.
# The same code is in vdisplay.m in the repository, with comments.
VDISPLAY_SOURCE = r'''// vdisplay - creates an invisible extra screen ("virtual display") on macOS.
//
// macOS only draws the desktop you're looking at, so a desktop you've swiped away
// from can't be recorded. A virtual display is a screen macOS *always* draws,
// even though no real monitor is attached. TV Mirror records it and sends it to the TV.
//
// It uses CGVirtualDisplay, a built-in but undocumented part of macOS's CoreGraphics
// (the same thing apps like DeskPad use). macOS only switches a virtual screen on for
// a real app connected to the window server, so this runs as a hidden background app
// (no Dock icon, no windows). The screen exists for as long as this
// program runs; when it quits, the screen disappears and its windows move back.
//
// Build:  clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreGraphics vdisplay.m -o vdisplay
// Run:    ./vdisplay 1920 1080        (prints the new screen's display ID)

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

// ---- Declarations for the undocumented CoreGraphics classes ----------------

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

// ---------------------------------------------------------------------------

static void quit(int sig) { (void)sig; exit(0); }

static CGVirtualDisplay *gDisplay;   // kept for as long as the program runs

static void reportAndFix(CGDirectDisplayID newID) {
    // macOS sometimes adds a new screen as a *mirror* of the main one.
    // A mirror isn't a separate screen, so switch that off.
    if (CGDisplayIsInMirrorSet(newID)) {
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayMirrorOfDisplay(config, newID, kCGNullDirectDisplay);
            CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        }
    }
    // Report how macOS sees the new screen (for troubleshooting).
    CGDirectDisplayID online[16], active[16];
    uint32_t nOnline = 0, nActive = 0;
    CGGetOnlineDisplayList(16, online, &nOnline);
    CGGetActiveDisplayList(16, active, &nActive);
    int isOnline = 0, isActive = 0;
    for (uint32_t i = 0; i < nOnline; i++) if (online[i] == newID) isOnline = 1;
    for (uint32_t i = 0; i < nActive; i++) if (active[i] == newID) isActive = 1;
    CGRect b = CGDisplayBounds(newID);
    fprintf(stderr,
            "[vdisplay] id=%u online=%d active=%d mirrored=%d asleep=%d size=%.0fx%.0f at %.0f,%.0f "
            "| online screens=%u active screens=%u\n",
            newID, isOnline, isActive, (int)CGDisplayIsInMirrorSet(newID),
            (int)CGDisplayIsAsleep(newID), b.size.width, b.size.height, b.origin.x, b.origin.y,
            nOnline, nActive);
    fflush(stderr);
}

static void createDisplay(unsigned int width, unsigned int height) {
    Class Descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class Display    = NSClassFromString(@"CGVirtualDisplay");
    Class Settings   = NSClassFromString(@"CGVirtualDisplaySettings");
    Class Mode       = NSClassFromString(@"CGVirtualDisplayMode");
    if (!Descriptor || !Display || !Settings || !Mode) {
        fprintf(stderr, "This version of macOS doesn't support virtual displays.\n");
        exit(2);
    }

    CGVirtualDisplayDescriptor *descriptor = [[Descriptor alloc] init];
    [descriptor setDispatchQueue:dispatch_get_main_queue()];
    descriptor.name = @"TV Mirror Display";
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(width * 0.37, height * 0.37);  // like a ~32" TV
    descriptor.vendorID = 0x7456;   // made-up IDs so macOS remembers this "monitor"
    descriptor.productID = 0x4D52;
    descriptor.serialNum = 0x0001;
    descriptor.terminationHandler = ^(id unused, CGVirtualDisplay *display) {
        fprintf(stderr, "The virtual screen was removed by macOS.\n");
        exit(1);
    };

    CGVirtualDisplay *display = [[Display alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == 0) {
        fprintf(stderr, "Couldn't create the virtual screen.\n");
        exit(3);
    }

    CGVirtualDisplaySettings *settings = [[Settings alloc] init];
    settings.hiDPI = 0;   // 1 screen pixel = 1 TV pixel
    settings.modes = @[ [[Mode alloc] initWithWidth:width height:height refreshRate:60] ];
    if (![display applySettings:settings]) {
        fprintf(stderr, "Couldn't set the virtual screen to %ux%u.\n", width, height);
        exit(4);
    }
    gDisplay = display;

    CGDirectDisplayID newID = display.displayID;
    printf("%u\n", newID);
    fflush(stdout);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        reportAndFix(newID);
    });
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned int width  = argc > 1 ? (unsigned int)atoi(argv[1]) : 1920;
        unsigned int height = argc > 2 ? (unsigned int)atoi(argv[2]) : 1080;
        if (width < 640 || height < 480) { width = 1920; height = 1080; }

        signal(SIGTERM, quit);
        signal(SIGINT, quit);

        // Become a hidden background app so macOS connects us to the window server.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        // Create the screen once the app is up and running.
        dispatch_async(dispatch_get_main_queue(), ^{
            createDisplay(width, height);
        });

        // Keep running (and keep the screen alive) until TV Mirror stops us.
        [NSApp run];
    }
    return 0;
}
'''


MEMORY_FILE = os.path.join(os.path.expanduser("~"), ".tv-mirror-build", "tvs.json")


def remembered_format(tv_name):
    try:
        with open(MEMORY_FILE) as f:
            entry = json.load(f).get(tv_name) or {}
        return entry.get("encoder"), entry.get("audio")
    except Exception:
        return None, None


def remember_format(tv_name, encoder, audio):
    try:
        os.makedirs(os.path.dirname(MEMORY_FILE), exist_ok=True)
        data = {}
        if os.path.exists(MEMORY_FILE):
            with open(MEMORY_FILE) as f:
                data = json.load(f)
        data[tv_name] = {"encoder": encoder, "audio": audio}
        with open(MEMORY_FILE, "w") as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


def build_vdisplay():
    """Compile the virtual-screen helper once and return its path (or None)."""
    build_dir = os.path.join(os.path.expanduser("~"), ".tv-mirror-build")
    digest = hashlib.sha1(VDISPLAY_SOURCE.encode()).hexdigest()[:10]
    exe = os.path.join(build_dir, f"vdisplay-{digest}")
    if os.path.exists(exe):
        return exe
    clang = shutil.which("clang")
    if not clang:
        print("Building the virtual screen needs Apple's developer tools. Run:\n"
              "  xcode-select --install\nthen try again.")
        return None
    os.makedirs(build_dir, exist_ok=True)
    src = os.path.join(build_dir, "vdisplay.m")
    with open(src, "w") as f:
        f.write(VDISPLAY_SOURCE)
    print("Building the virtual screen helper (first time only)...")
    result = subprocess.run(
        [clang, "-fobjc-arc", "-framework", "AppKit", "-framework", "Foundation",
         "-framework", "CoreGraphics",
         src, "-o", exe],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print("Couldn't build the virtual screen helper:\n" + result.stderr)
        return None
    return exe


def start_virtual_display(size):
    """Create the invisible screen. Returns (process, ffmpeg screen name) or (None, None)."""
    if sys.platform != "darwin":
        print("The virtual screen only works on a Mac.")
        return None, None
    try:
        width, height = (int(n) for n in size.lower().split("x"))
    except ValueError:
        width, height = 1920, 1080
    exe = build_vdisplay()
    if not exe:
        return None, None

    before = set(list_devices()[0])
    proc = subprocess.Popen([exe, str(width), str(height)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready, _, _ = select.select([proc.stdout], [], [], 10)
    display_id = proc.stdout.readline().strip() if ready else ""
    if not display_id.isdigit():
        if proc.poll() is None:
            proc.terminate()
        err = proc.stderr.read().strip()
        print("Couldn't create the virtual screen." + (f"\n{err}" if err else ""))
        return None, None

    # Wait for ffmpeg to see the new screen
    after = []
    for _ in range(30):
        if proc.poll() is not None:
            break
        after = list_devices()[0]
        new = [x for x in after if x not in before]
        if new:
            return proc, new[-1]
        time.sleep(0.5)

    # It didn't show up: print a report so we can see why
    report = ""
    alive = proc.poll() is None
    if alive:
        ready, _, _ = select.select([proc.stderr], [], [], 3)
        if ready:
            report = os.read(proc.stderr.fileno(), 4096).decode(errors="ignore").strip()
        proc.terminate()
    else:
        report = proc.stderr.read().strip()
    displays = subprocess.run("system_profiler SPDisplaysDataType | grep -E '^ {8}[^ ].*:$'",
                              shell=True, capture_output=True, text=True).stdout.strip()
    print("The virtual screen was created, but screen recording can't see it.\n"
          "Please send this report:\n"
          f"  helper still running: {'yes' if alive else 'no'}\n"
          f"  helper says: {report or '(nothing)'}\n"
          f"  screens ffmpeg sees before: {sorted(before)}\n"
          f"  screens ffmpeg sees after:  {after}\n"
          f"  displays macOS lists:\n{displays or '    (none)'}")
    return None, None


# --------------------------------------------------------------------------- #
# Main program
# --------------------------------------------------------------------------- #

def local_ip_for(host):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((host, 9))
        return s.getsockname()[0]
    finally:
        s.close()


def choose_tv(args):
    print("Looking for TVs on your Wi-Fi...")
    tvs = discover(args.search_time)
    if args.tv:
        key = args.tv.lower()
        tvs = [t for t in tvs if key in t["name"].lower() or key == t["host"]]
    if not tvs:
        print("\nNo TV found. Check that:\n"
              "  - the TV is switched on and on the same Wi-Fi as this Mac\n"
              "  - on the TV: Settings > Network > Home Network (or 'Remote device\n"
              "    settings') > 'Renderer' / 'Allow remote devices' is turned ON\n"
              "  - your router isn't blocking device-to-device traffic (guest Wi-Fi often does)")
        sys.exit(1)
    if len(tvs) == 1:
        return tvs[0]
    print("\nFound these devices:")
    for i, t in enumerate(tvs, 1):
        print(f"  {i}. {t['name']}  ({t['host']})")
    while True:
        choice = input("Which one? Type the number: ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(tvs):
            return tvs[int(choice) - 1]


def screen_size(screen):
    """Grab one frame of a screen to find its resolution (helps tell screens apart)."""
    try:
        proc = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostdin", "-f", "avfoundation", "-framerate", "30",
             "-i", f"{screen}:none", "-frames:v", "1", "-f", "null", "-"],
            capture_output=True, text=True, timeout=8,
        )
        m = re.search(r"Video: .*?(\d{3,5})x(\d{3,5})", proc.stderr)
        return f"{m.group(1)}x{m.group(2)}" if m else ""
    except Exception:
        return ""


def choose_screen(wanted):
    """Pick which screen to mirror: from --screen, or by asking when there's more than one."""
    screens, _ = list_devices()
    if not screens:
        return wanted or "Capture screen 0"
    if wanted:
        if wanted.isdigit():   # --screen 2  means the 2nd screen in the list
            n = int(wanted)
            if 1 <= n <= len(screens):
                return screens[n - 1]
            print(f"There's no screen {n}; you have {len(screens)}. Using screen 1.")
            return screens[0]
        return wanted
    if len(screens) == 1:
        return screens[0]
    print("Which screen do you want to mirror?")
    for i, s in enumerate(screens, 1):
        size = screen_size(s)
        label = " (main screen, the one with the menu bar)" if i == 1 else ""
        print(f"  {i}. Screen {i}{f'  {size}' if size else ''}{label}")
    while True:
        choice = input("Type the number: ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(screens):
            return screens[int(choice) - 1]


def self_update():
    """Replace this file with the newest tvmirror.py from GitHub."""
    me = os.path.abspath(__file__)
    def fetch(url):
        return subprocess.run(["curl", "-fsSL", url], capture_output=True, timeout=60).stdout

    new = b""
    try:
        # Ask GitHub for the newest version's ID first: the plain download link can
        # serve an old copy for a few minutes after an update.
        sha = json.loads(fetch(f"https://api.github.com/repos/{REPO}/commits/main"))["sha"]
        new = fetch(f"https://raw.githubusercontent.com/{REPO}/{sha}/tvmirror.py")
    except Exception:
        pass
    if b"def main()" not in new:
        try:
            new = fetch(f"https://raw.githubusercontent.com/{REPO}/main/tvmirror.py")
        except Exception as e:
            print(f"Couldn't download the update ({e}). Check your internet connection.")
            return 1
    if b"def main()" not in new:
        print("The download didn't look right, so nothing was changed.")
        return 1
    with open(me, "rb") as f:
        if f.read() == new:
            print(f"You already have the newest version ({VERSION}).")
            return 0
    tmp = me + ".new"
    with open(tmp, "wb") as f:
        f.write(new)
    os.replace(tmp, me)
    m = re.search(rb'VERSION = "([^"]+)"', new)
    print(f"Updated TV Mirror {VERSION} -> {m.group(1).decode() if m else 'newest'}.")
    return 0


def main():
    p = argparse.ArgumentParser(description="Mirror your Mac's screen to a smart TV.")
    p.add_argument("--tv", help="TV name (or part of it) or IP address")
    p.add_argument("--screen", help="which screen to mirror: 1, 2, ... (default: asks if you have more than one)")
    p.add_argument("--rate", type=float, default=8,
                   help="stream size in Mbit/s, kept constant so the TV starts quickly. "
                        "Higher = less delay but needs better Wi-Fi (default 8). "
                        "Change it live with + and -")
    p.add_argument("--boost", default="0",
                   help="extra: also pad the whole stream to this rate, e.g. 20M (default off)")
    p.add_argument("--virtual-display", action="store_true",
                   help="add an invisible extra screen and mirror that, so you can keep "
                        "working on your other desktops")
    p.add_argument("--virtual-size", default="1920x1080",
                   help="size of the virtual screen (default 1920x1080)")
    p.add_argument("--show-clock", action="store_true",
                   help="show a clock on the TV picture so you can measure the delay")
    p.add_argument("--auto-reset", type=float, default=0, metavar="MINUTES",
                   help="reset the delay automatically every N minutes (like pressing R)")
    p.add_argument("--audio-device", help='audio input to send, e.g. "BlackHole 2ch" (default: silent)')
    p.add_argument("--fps", type=int, default=30, help="frames per second (default 30)")
    p.add_argument("--height", type=int, default=1080, help="video height, e.g. 720 or 1080 (default 1080)")
    p.add_argument("--audio-codec", choices=["mp2", "ac3", "aac"], default=None,
                   help="sound format (default mp2; tries others if the TV refuses)")
    p.add_argument("--encoder", choices=["software", "intra", "hardware"], default=None,
                   help="software (default: constant size, least delay) or hardware "
                        "(less CPU, but still screens lag more). Tries others if the TV refuses")
    p.add_argument("--port", type=int, default=8090, help="port for the stream (default 8090)")
    p.add_argument("--mode", choices=["sony", "live", "stream"], default="sony",
                   help="how the video is served: sony (default, looks like a long video file), "
                        "live (marked as a live broadcast) or stream. Switch live with M")
    p.add_argument("--dlna-profile", default="",
                   help="DLNA profile name to announce, e.g. AVC_TS_HD_EU_ISO (default: none)")
    p.add_argument("--debug", action="store_true", help="print what the TV asks for")
    p.add_argument("--search-time", type=float, default=4.0, help="seconds to search for TVs")
    p.add_argument("--update", action="store_true", help="download the newest version from GitHub")
    p.add_argument("--version", action="version", version=f"TV Mirror {VERSION}")
    p.add_argument("--list-devices", action="store_true", help="list screens and audio devices, then exit")
    p.add_argument("--serve-only", action="store_true", help="don't control a TV; just serve the stream")
    p.add_argument("--test-pattern", action="store_true", help="send a test picture instead of your screen")
    args = p.parse_args()

    if args.update:
        sys.exit(self_update())
    print(f"TV Mirror {VERSION}")

    StreamHandler.mode = args.mode
    StreamHandler.debug = args.debug
    StreamHandler.dlna_pn = args.dlna_profile

    if not shutil.which("ffmpeg"):
        print("ffmpeg is not installed. Install it with:  brew install ffmpeg")
        sys.exit(1)

    global HAS_DRAWTEXT, HAS_X264
    filters = subprocess.run(["ffmpeg", "-hide_banner", "-filters"],
                             capture_output=True, text=True).stdout
    HAS_DRAWTEXT = re.search(r"\sdrawtext\s", filters) is not None
    if args.encoder != "hardware":
        encoders = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"],
                                  capture_output=True, text=True).stdout
        HAS_X264 = "libx264" in encoders
        if not HAS_X264:
            print("Note: this ffmpeg has no libx264, so using the Mac's video chip.\n"
                  "Still screens will have more delay. Fix: brew reinstall ffmpeg")
    terminal_clock = args.show_clock and not HAS_DRAWTEXT

    if args.list_devices:
        screens, audio = list_devices()
        print("Screens:", *(screens or ["(none found - check Screen Recording permission)"]), sep="\n  ")
        print("Audio devices:", *(audio or ["(none)"]), sep="\n  ")
        return

    vd_screen = None
    if args.virtual_display and not args.test_pattern:
        vd_proc, vd_screen = start_virtual_display(args.virtual_size)
        if not vd_proc:
            sys.exit(1)
        atexit.register(lambda: vd_proc.poll() is None and vd_proc.terminate())
        args.screen = vd_screen
        print("\nAdded an invisible screen called 'TV Mirror Display'. Whatever is on it\n"
              "goes to the TV, while you keep working on your normal screen and desktops.\n"
              "To put a window on the TV: hover over its green button and choose\n"
              "'Move to TV Mirror Display' (or drag it off the right edge of your screen).\n"
              "When TV Mirror quits, the screen disappears and its windows come back.\n")

    if not args.test_pattern:
        args.screen = choose_screen(args.screen)

    tv = None if args.serve_only else choose_tv(args)
    my_ip = local_ip_for(tv["host"] if tv else "8.8.8.8")
    url = f"http://{my_ip}:{args.port}{STREAM_PATH}"

    try:
        args.boost = int(float(str(args.boost).upper().rstrip("M") or 0))
    except ValueError:
        args.boost = 0
    args.rate = max(1.0, min(args.rate, 40.0))
    screens = [] if args.test_pattern else list_devices()[0]

    # Start the little web server the TV will read from
    server = StreamServer(("0.0.0.0", args.port), StreamHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    capture = {"proc": None}

    # Formats to try: what was asked for, else what worked on this TV last time,
    # else the order in PROFILES (least delay first).
    available = [p for p in PROFILES if p[0] != "software" or HAS_X264]
    if args.encoder or args.audio_codec:
        want = (args.encoder or available[0][0], args.audio_codec or "mp2")
        first = [p for p in available if (p[0], p[1]) == want] or \
                [(want[0], want[1], f"{want[0]} video + {want[1].upper()} sound")]
    else:
        last_time = remembered_format(tv["name"]) if tv else (None, None)
        first = [p for p in available if (p[0], p[1]) == last_time]
        if first:
            print(f"Using the format that worked on this TV last time: {first[0][2]}")
    profiles = first + [p for p in available if p not in first]
    args.encoder, args.audio_codec = profiles[0][0], profiles[0][1]

    def start_capture():
        # Let a TV fall at most ~0.75 s behind before skipping ahead
        rate = max(args.rate, args.boost or 0) + 0.5
        BROADCASTER.max_backlog = int(max(rate * 1e6 / 8 * 0.75, 256 * 1024))
        proc = subprocess.Popen(ffmpeg_command(args), stdout=subprocess.PIPE,
                                stdin=subprocess.DEVNULL)
        threading.Thread(target=BROADCASTER.pump, args=(proc.stdout,), daemon=True).start()
        capture["proc"] = proc
        time.sleep(1.5)
        return proc.poll() is None

    def stop_capture():
        proc = capture["proc"]
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()

    def play_on_tv():
        if tv:
            tv_play(tv, url)

    def reset_lag(restart_video=False):
        """Make the TV start over from 'now', which throws away its built-up delay."""
        if restart_video:
            stop_capture()
        BROADCASTER.disconnect_all()
        if restart_video and not start_capture():
            return False
        try:
            play_on_tv()
        except Exception as e:
            print(f"  TV didn't respond: {e}")
        return True

    def status():
        what = "test pattern" if args.test_pattern else args.screen.replace("Capture screen ", "screen ")
        if not args.test_pattern and args.screen.startswith("Capture screen "):
            what = f"screen {int(args.screen.split()[-1]) + 1}"
        if vd_screen and args.screen == vd_screen:
            what += " (TV Mirror Display)"
        label = next((p[2] for p in PROFILES if (p[0], p[1]) == (args.encoder, args.audio_codec)),
                     f"{args.encoder} video + {args.audio_codec.upper()} sound")
        log(f"  Now showing: {what}  |  {args.rate:g} Mbit/s  |  {label}  |  mode: {StreamHandler.mode}")

    if not start_capture():
        print("\nScreen capture failed to start. If you see a permission error above:\n"
              "  System Settings > Privacy & Security > Screen Recording > turn ON Terminal\n"
              "  (then quit and reopen Terminal). If the error mentions libx264,\n"
              "  try again with:  --encoder hardware")
        server.shutdown()
        sys.exit(1)

    print(f"\nStreaming at {url}")
    if tv:
        print(f"Sending to: {tv['name']} ({tv['host']})")
        for i, (encoder, audio_codec, label) in enumerate(profiles):
            if i > 0:
                print(f"The TV couldn't play that. Trying: {label}...")
                args.encoder, args.audio_codec = encoder, audio_codec
                stop_capture()
                BROADCASTER.disconnect_all()
                if not start_capture():
                    continue
            try:
                play_on_tv()
            except Exception as e:
                print(f"  The TV refused: {e}")
                continue
            if i == len(profiles) - 1:
                break                     # last option: nothing else to fall back to
            print(f"Checking the TV can play it ({label})...")
            if tv_check(tv, debug=args.debug) == "playing":
                print("The TV is playing it.")
                remember_format(tv["name"], encoder, audio_codec)
                break
        print("Mirroring! It can take a few seconds to appear.")
    else:
        print("Serve-only mode: open the URL above in VLC (File > Open Network).")

    if terminal_clock:
        print("\nThe clock below is also on the TV (it's part of your screen). Make sure this\n"
              "window is visible on the screen you're mirroring. The difference between the\n"
              "two clocks is your delay.")
    print("\nControls (press a key in this window):")
    if len(screens) > 1:
        print(f"  1-{min(len(screens), 9)}  switch to that screen")
    print("  R    reset the delay (TV restarts from 'now'; do this if it falls behind)\n"
          "  +/-  bigger / smaller stream (bigger = less delay, needs better Wi-Fi)\n"
          "  F    try the next video format (if the TV shows an error)\n"
          "  M    switch how the TV is told about the video (sony / live), to compare\n"
          "  Q    quit")
    status()

    keys = KeyReader()
    last_reset = time.time()
    warned_drops, last_warning = 0, 0.0
    try:
        with keys:
            while True:
                if capture["proc"].poll() is not None:
                    log("\nScreen capture stopped unexpectedly.")
                    break
                key = keys.read(0.25)
                if BROADCASTER.drops > warned_drops and time.time() - last_warning > 10:
                    warned_drops, last_warning = BROADCASTER.drops, time.time()
                    log(f"  ! The TV can't keep up with {args.rate:g} Mbit/s over your Wi-Fi, "
                        "so some video was skipped. Press - for a smaller stream.")
                if terminal_clock:
                    sys.stdout.write("\r\033[K  Mac clock: " + time.strftime("%H:%M:%S") +
                                     "   <- compare with the same clock on the TV")
                    sys.stdout.flush()
                if args.auto_reset and time.time() - last_reset > args.auto_reset * 60:
                    key, auto = "r", True
                else:
                    auto = False
                if not key:
                    continue
                key = key.lower()
                if key == "q":
                    break
                elif key == "r":
                    log("  Resetting the delay..." if not auto else "  Auto-reset of the delay...")
                    reset_lag()
                    last_reset = time.time()
                    warned_drops = BROADCASTER.drops   # forget older warnings
                elif key in "+=-_":
                    old = args.rate
                    if key in "+=":
                        args.rate = next((r for r in RATE_STEPS if r > old), old)
                    else:
                        args.rate = next((r for r in reversed(RATE_STEPS) if r < old), old)
                    if args.rate == old:
                        log(f"  Already at the {'highest' if key in '+=' else 'lowest'} setting.")
                        continue
                    log(f"  Changing the stream to {args.rate:g} Mbit/s...")
                    if not reset_lag(restart_video=True):
                        log("  That setting didn't work; going back.")
                        args.rate = old
                        reset_lag(restart_video=True)
                    last_reset = time.time()
                    warned_drops = BROADCASTER.drops   # forget older warnings
                    status()
                elif key == "f":
                    keys_ = [(p[0], p[1]) for p in profiles]
                    i = keys_.index((args.encoder, args.audio_codec)) if (args.encoder, args.audio_codec) in keys_ else -1
                    for step in range(1, len(profiles) + 1):
                        args.encoder, args.audio_codec, label = profiles[(i + step) % len(profiles)]
                        log(f"  Switching format to: {label}...")
                        if reset_lag(restart_video=True):
                            break
                        log("  That format didn't start on this Mac; trying the next one.")
                    last_reset = time.time()
                    warned_drops = BROADCASTER.drops
                    status()
                elif key == "m":
                    order = ["sony", "live"]
                    cur = StreamHandler.mode
                    StreamHandler.mode = order[(order.index(cur) + 1) % 2] if cur in order else "sony"
                    log(f"  Switching to {StreamHandler.mode} mode...")
                    reset_lag()
                    last_reset = time.time()
                    warned_drops = BROADCASTER.drops   # forget older warnings
                    status()
                elif key.isdigit() and screens:
                    n = int(key)
                    if not 1 <= n <= len(screens):
                        log(f"  There's no screen {n}; you have {len(screens)}.")
                        continue
                    if screens[n - 1] == args.screen:
                        continue
                    old = args.screen
                    args.screen = screens[n - 1]
                    log(f"  Switching to screen {n}...")
                    if not reset_lag(restart_video=True):
                        log("  Couldn't capture that screen; going back.")
                        args.screen = old
                        reset_lag(restart_video=True)
                    last_reset = time.time()
                    warned_drops = BROADCASTER.drops   # forget older warnings
                    status()
    except KeyboardInterrupt:
        pass
    finally:
        log("\nStopping...")
        if tv:
            tv_stop(tv)
        BROADCASTER.close()
        stop_capture()
        server.shutdown()
        log("Stopped.")


class KeyReader:
    """Reads single key presses from the Terminal without needing Enter."""

    def __init__(self):
        self.fd = sys.stdin.fileno() if sys.stdin.isatty() else None
        self.saved = None

    def __enter__(self):
        if self.fd is not None:
            self.saved = termios.tcgetattr(self.fd)
            tty.setcbreak(self.fd)
        return self

    def __exit__(self, *exc):
        if self.saved is not None:
            termios.tcsetattr(self.fd, termios.TCSADRAIN, self.saved)

    def read(self, timeout):
        if self.fd is None:
            time.sleep(timeout)
            return ""
        ready, _, _ = select.select([self.fd], [], [], timeout)
        return os.read(self.fd, 1).decode(errors="ignore") if ready else ""

if __name__ == "__main__":
    main()
